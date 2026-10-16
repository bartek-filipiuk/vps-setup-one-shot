# Shared helpers for verify.sh and the phase files. Source it: `. ./lib.sh`
# Agent shells lose functions and variables between calls (the working directory may
# persist), so phase commands start with `. ./lib.sh;` and never `cd` outside a subshell.

# VPS_STATE can be pointed at another file (PREPARE-APP uses the app's .coolify.env);
# the server itself is always looked up in the global setup state.
VPS_SETUP_STATE="$HOME/.config/vps-setup/state"
VPS_STATE="${VPS_STATE:-$VPS_SETUP_STATE}"
COOLIFY_CONFIG="$HOME/.config/coolify/config"

# --- state: KEY=VALUE lines, only things that cannot be derived from reality ---

state_get() { [ -f "$VPS_STATE" ] && grep -m1 "^$1=" "$VPS_STATE" | cut -d= -f2-; }

state_set() {
  mkdir -p "$(dirname "$VPS_STATE")"
  ( umask 077; touch "$VPS_STATE"
    { grep -v "^$1=" "$VPS_STATE" || true; printf '%s=%s\n' "$1" "$2"; } > "$VPS_STATE.tmp" ) &&
  mv "$VPS_STATE.tmp" "$VPS_STATE"
}

# --- remote shell on the VPS (never run server commands without this) ---

rssh() {
  local ip; ip=$(grep -m1 '^VPS_IP=' "$VPS_SETUP_STATE" 2>/dev/null | cut -d= -f2-)
  [ -n "$ip" ] || { echo "VPS_IP not set in $VPS_SETUP_STATE" >&2; return 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$ip" "$@"
}

# --- Coolify API ---

# Config values are read with grep, not sourced: tokens contain '|'.
coolify_get() { [ -f "$COOLIFY_CONFIG" ] && grep -m1 "^$1=" "$COOLIFY_CONFIG" | cut -d= -f2-; }

# Server uuid: from the config when phase 04 wrote it, otherwise the first server from the API
# (configs written by other tools often lack it).
coolify_server() {
  local s; s=$(coolify_get COOLIFY_SERVER_UUID)
  [ -n "$s" ] && echo "$s" || capi GET /servers | jq -r '.[0].uuid // empty'
}

# capi METHOD /path [json-body] -> prints body; returns 1 and prints body to stderr on HTTP >= 400.
# Each call gives up after CAPI_MAX_TIME seconds (default 30).
capi() {
  local url token out code
  url=$(coolify_get COOLIFY_URL); token=$(coolify_get COOLIFY_TOKEN)
  [ -n "$url" ] && [ -n "$token" ] || { echo "Coolify config missing in $COOLIFY_CONFIG" >&2; return 1; }
  # The body goes through stdin, not argv, so keys and passwords never show up in `ps`.
  out=$(printf '%s' "${3:-}" | curl -sS --max-time "${CAPI_MAX_TIME:-30}" -w '\n%{http_code}' -X "$1" "$url/api/v1$2" \
    -H "Authorization: Bearer $token" -H "Accept: application/json" \
    -H "Content-Type: application/json" ${3:+--data-binary @-}) || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then echo "HTTP $code $1 $2: $out" >&2; return 1; fi
  printf '%s\n' "$out"
}

# --- one-line reports (status.sh, checkup.sh) ---

# report_colors -> sets C_OK, C_WARN, C_FAIL, C_END: ANSI colors on a terminal, empty when piped
# or with NO_COLOR set.
report_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m' C_END=$'\033[0m'
  else
    C_OK='' C_WARN='' C_FAIL='' C_END=''
  fi
}

# line MARK label detail  (MARK: OK, WARN, FAIL). API-provided text is stripped of control chars.
# WARN and FAIL set the caller's `attention` to 1.
line() {
  local c
  # shellcheck disable=SC2034 # attention is read by status.sh and checkup.sh
  case $1 in OK) c=${C_OK:-} ;; WARN) c=${C_WARN:-}; attention=1 ;; *) c=${C_FAIL:-}; attention=1 ;; esac
  printf '%s%-5s%s %-28s %s\n' "$c" "$1" "${C_END:-}" "$(tr -d '[:cntrl:]' <<<"$2")" "$(tr -d '[:cntrl:]' <<<"$3")"
}
section() { printf '\n%s\n' "$1"; }
# worst MARK MARK -> the more serious of the two
worst() { case "$1 $2" in *FAIL*) echo FAIL ;; *WARN*) echo WARN ;; *) echo OK ;; esac; }

# Epoch seconds of an openssl date ("Jan  1 00:00:00 2027 GMT"): GNU date, then BSD date.
epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f "%b %d %T %Y %Z" "$1" +%s 2>/dev/null; }

# jq: Coolify timestamps to epoch. Seen: "2026-10-13T12:08:21.000000Z" (deployments) and
# "2026-10-13T12:08:10+00:00" (backup executions); a space instead of T is accepted too.
# Anything else is an error, so a format change shows as "could not read", never as "none".
# shellcheck disable=SC2016 # $s is a jq variable
JQ_EPOCH='def epoch:
  . as $s
  | [capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")]
  | if length == 0 then error("unknown date format: \($s)") else .[0] end
  | ((.d + "T" + .t + "Z") | fromdateiso8601)
    - (if (.z // "Z") == "Z" then 0
       else ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) * (if .z[0:1] == "-" then -1 else 1 end) end);'

# X.Y.Z -> "X Y Z" (pre-release suffix dropped); empty when not numeric.
semver() { local v=${1#v}; v=${v%%-*}; case $v in *[!0-9.]*|'') ;; *) tr '.' ' ' <<<"$v" ;; esac; }

# --- safe deploys: rollback point and database dump before every deploy (ROLLBACK.md) ---

# Dumps live on the server under DUMP_DIR/<DB_UUID>/ (default /root/db-dumps; tests point it elsewhere).
DUMP_DIR=${DUMP_DIR:-/root/db-dumps}

# rollback_point APP_UUID -> commit of the last finished production deployment (the version
# running now), empty when the app was never deployed. Pull-request previews are skipped.
# Not `git_commit_sha` of the app: that is "HEAD".
rollback_point() {
  local r; r=$(capi GET "/deployments/applications/$1") || return 1
  jq -r '[.deployments[]? | select(.status == "finished" and ((.pull_request_id // 0) == 0))][0].commit // empty' <<<"$r"
}

# rollback_image_present APP_UUID COMMIT -> 0 when the image for COMMIT is still on the server
# (GET /applications/{uuid}/rollback-images), 1 otherwise (pruned, or the server is unreachable).
rollback_image_present() {
  capi GET "/applications/$1/rollback-images" 2>/dev/null |
    jq -e --arg c "$2" 'any(.images[]?; .tag == $c)' >/dev/null
}

# db_pg_params DB_UUID -> "user\ndb" of a Coolify standalone Postgres; fails for other types.
db_pg_params() {
  local info type
  info=$(capi GET "/databases/$1") || return 1
  type=$(jq -r '.database_type // empty' <<<"$info")
  [ "$type" = standalone-postgresql ] || { echo "$1 is ${type:-unknown}; only standalone-postgresql is supported" >&2; return 1; }
  jq -r '(.postgres_user // "postgres"), (.postgres_db // .postgres_user // "postgres")' <<<"$info"
}

# --- Postgres major versions (R14, UPGRADE.md), read-only ---

# pg_image_major IMAGE -> the Postgres major version in an image's tag ("postgres:17-alpine",
# "postgres:16.4", "registry:5000/postgres:18" -> 17, 16, 18). Fails when the tag has no number
# in front (no tag, "latest", a digest): then the major cannot be told from the image.
pg_image_major() {
  local img=${1:-} tag m
  tag=${img##*/}; tag=${tag%%@*}
  case $tag in *:*) tag=${tag#*:} ;; *) tag= ;; esac
  m=${tag%%[!0-9]*}
  [ -n "$m" ] && [ "${#m}" -le 3 ] || { echo "no Postgres major version in the image tag: '$img'" >&2; return 1; }
  echo "$((10#$m))"
}

# db_major DB_UUID -> the major version of a Coolify standalone Postgres, from its image
# (GET /databases/{uuid}). Fails for other database types and for images like postgres:latest.
db_major() {
  local info type
  service_valid_uuid "${1:-}" || return 1
  info=$(capi GET "/databases/$1") || return 1
  type=$(jq -r '.database_type // empty' <<<"$info")
  [ "$type" = standalone-postgresql ] || { echo "$1 is ${type:-unknown}; only standalone-postgresql is supported" >&2; return 1; }
  pg_image_major "$(jq -r '.image // empty' <<<"$info")"
}

# pg_major_upgrade_plan DB_UUID TARGET -> prints the plan for a major upgrade of that database
# to Postgres TARGET (UPGRADE.md, Postgres): the old database, the new one to create next to it,
# the app whose DATABASE_URL moves, and the commands, with the real uuids. Read-only. Exit 1
# when TARGET is not a number, is not above the current major, or the database cannot be read.
pg_major_upgrade_plan() {
  local db=${1:-} target=${2:-} info cur name user dbname project server app
  [ -n "$db" ] && [ -n "$target" ] || { echo "usage: pg_major_upgrade_plan DB_UUID TARGET  (TARGET: a major version like 18)" >&2; return 1; }
  case $target in *[!0-9]*|0*) target=x ;; esac
  [ "$target" != x ] && [ "${#target}" -le 3 ] || { echo "TARGET must be a major version like 18, got '${2:-}'" >&2; return 1; }
  service_valid_uuid "$db" || return 1
  cur=$(db_major "$db") || return 1
  [ "$target" -gt "$cur" ] || { echo "database $db already runs Postgres $cur; $target is not an upgrade (a downgrade needs a dump into a new database by hand)" >&2; return 1; }
  info=$(capi GET "/databases/$db") || return 1
  name=$(jq -r '.name // "db"' <<<"$info")
  user=$(jq -r '.postgres_user // "postgres"' <<<"$info"); dbname=$(jq -r '.postgres_db // .postgres_user // "postgres"' <<<"$info")
  project=$(state_get PROJECT_UUID); app=$(state_get APP_UUID)
  server=$(coolify_server 2>/dev/null)
  echo "Postgres major upgrade plan (nothing has changed; UPGRADE.md, Postgres)"
  echo "old:     $db  $name  $(jq -r '.image // "?"' <<<"$info")  user $user, database $dbname  (Postgres $cur)"
  echo "new:     $name-pg$target  postgres:$target-alpine  user $user, database $dbname, new password"
  echo "         project ${project:-<no PROJECT_UUID in $VPS_STATE>}, environment production, server ${server:-<unknown>}"
  echo "app:     ${app:-<no APP_UUID in $VPS_STATE>}  (its DATABASE_URL moves from old to new)"
  [ "$(state_get DB_UUID)" = "$db" ] || echo "note:    $db is not DB_UUID in $VPS_STATE ($(state_get DB_UUID)); make sure this is the app's database"
  echo "steps:   1 user's yes  2 create new, wait running:healthy  3 stop the app  4 db_dump $db"
  echo "         5 RESTORE_FROM_DB=$db db_restore <NEW_UUID> <dump>  6 DATABASE_URL -> new, deploy"
  echo "         7 check data and health  8 state_set DB_UUID <NEW_UUID>; old stays stopped for rollback"
  [ "$target" -ge 18 ] && echo "warning: Postgres 18+ on Coolify's volume layout may refuse to start (references/coolify-api.md, Known quirks); then stop, it needs a human"
  return 0
}

# db_dump DB_UUID -> pg_dump (custom format) of a Coolify Postgres into
# DUMP_DIR/<DB_UUID>/<UTC time>.dump on the server (mode 600); prints "<path> <bytes>".
# Before dumping: prunes to DUMP_KEEP-1 (default 10) older dumps and refuses when the filesystem
# has less than 2 x database size + 1 GiB free. Goes through rssh, not Coolify's backup_now
# (db_backup_now below): a deploy needs a dump that is finished, on this server and at a known
# path before it starts.
db_dump() {
  local user db keep=${DUMP_KEEP:-10}
  case "$keep" in ''|*[!0-9]*|0) echo "DUMP_KEEP must be an integer >= 1, got '$keep'" >&2; return 1 ;; esac
  { read -r user; read -r db; } < <(db_pg_params "$1") || return 1
  [ -n "$user" ] || return 1
  rssh "sh -s -- $(printf %q "$1") $(printf %q "$user") $(printf %q "$db") $keep $(printf %q "$DUMP_DIR")" <<'EOF'
set -eu; umask 077
c=$(docker ps -q -f "name=^/?$1\$"); [ -n "$c" ] || { echo "no running container for database $1" >&2; exit 1; }
[ "$(printf '%s\n' "$c" | wc -l)" = 1 ] || { echo "more than one container matches database $1" >&2; exit 1; }
dir=$5/$1; mkdir -p "$dir"; chmod 700 "$5" "$dir"
ls -1t "$dir"/*.dump 2>/dev/null | tail -n +"$4" | xargs -r rm -f
size=$(docker exec "$c" psql -U "$2" -d "$3" -tAqc 'select pg_database_size(current_database())')
free=$(( $(df -Pk "$dir" | awk 'NR == 2 { print $4 }') * 1024 ))
need=$(( size * 2 + 1073741824 ))
[ "$free" -ge "$need" ] || { echo "not enough disk for a dump of $3: database $size bytes, free $free bytes, need $need (2 x size + 1 GiB)" >&2; exit 1; }
f=$dir/$(date -u +%Y%m%dT%H%M%SZ).dump
if docker exec "$c" pg_dump -U "$2" -d "$3" -Fc > "$f" && [ -s "$f" ]; then
  echo "$f $(stat -c %s "$f")"
else
  rm -f "$f"; echo "pg_dump failed for database $1" >&2; exit 1
fi
EOF
}

# db_restore DB_UUID DUMP_DIR/<DB_UUID>/<time>.dump -> pg_restore into the live database,
# all or nothing (--single-transaction --clean --if-exists). Rows written after the dump are
# lost. `--clean` drops only what the dump recreates: tables created by a later migration
# survive and the migration table goes back to the dump's state (so a redeploy of the newer
# code would run those migrations again). RESTORE_WIPE=yes drops and recreates the `public`
# schema first (everything gone, then the dump; if pg_restore then fails the database is
# empty until the next attempt). Refuses while the app (APP_UUID in the state) is running,
# unless RESTORE_WITH_APP_RUNNING=1.
# The target is always the first argument. A dump from DUMP_DIR/<uuid>/ goes back only into that
# database, unless RESTORE_FROM_DB=<uuid> says it comes from another one on purpose (a Postgres
# major upgrade, UPGRADE.md); RESTORE_FROM_DB equal to the target is refused, so the old database
# is never the target of an upgrade restore by mistake.
db_restore() {
  local user db app status wipe=no src="" from=${RESTORE_FROM_DB:-}
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: db_restore DB_UUID DUMP_PATH" >&2; return 1; }
  case $2 in "$DUMP_DIR"/*/*) src=${2#"$DUMP_DIR"/}; src=${src%%/*} ;; esac
  if [ -n "$from" ]; then
    [ "$from" != "$1" ] || { echo "db_restore: RESTORE_FROM_DB is the target $1 itself; the target of an upgrade restore is the NEW database" >&2; return 1; }
    [ -z "$src" ] || [ "$src" = "$from" ] || { echo "db_restore: dump $2 belongs to database $src, not RESTORE_FROM_DB=$from" >&2; return 1; }
  elif [ -n "$src" ] && [ "$src" != "$1" ]; then
    echo "db_restore: dump $2 belongs to database $src, not $1; to restore it into another database on purpose (UPGRADE.md) set RESTORE_FROM_DB=$src" >&2; return 1
  fi
  app=$(state_get APP_UUID)
  if [ "${RESTORE_WITH_APP_RUNNING:-0}" != 1 ]; then
    [ -n "$app" ] || { echo "db_restore: no APP_UUID in $VPS_STATE; stop the app yourself and set RESTORE_WITH_APP_RUNNING=1" >&2; return 1; }
    status=$(capi GET "/applications/$app" | jq -r '.status // "unknown"')
    case "$status" in running*) echo "db_restore: app $app is $status; stop it first (ROLLBACK.md step 4) or set RESTORE_WITH_APP_RUNNING=1" >&2; return 1 ;; esac
  fi
  [ "${RESTORE_WIPE:-no}" = yes ] && wipe=yes
  { read -r user; read -r db; } < <(db_pg_params "$1") || return 1
  [ -n "$user" ] || return 1
  rssh "sh -s -- $(printf %q "$1") $(printf %q "$user") $(printf %q "$db") $(printf %q "$2") $wipe" <<'EOF'
set -eu
c=$(docker ps -q -f "name=^/?$1\$"); [ -n "$c" ] || { echo "no running container for database $1" >&2; exit 1; }
[ "$(printf '%s\n' "$c" | wc -l)" = 1 ] || { echo "more than one container matches database $1" >&2; exit 1; }
[ -s "$4" ] || { echo "dump not found or empty: $4" >&2; exit 1; }
if [ "$5" = yes ]; then
  docker exec "$c" psql -U "$2" -d "$3" -v ON_ERROR_STOP=1 -qc 'drop schema public cascade; create schema public;'
  echo "schema public wiped in $3"
fi
docker exec -i "$c" pg_restore -U "$2" -d "$3" --single-transaction --clean --if-exists --no-owner --no-privileges < "$4"
echo "restored $4 into $3"
EOF
}

# wait_deployment DEPLOYMENT_UUID -> polls ~15 min, prints log tail on failure.
wait_deployment() {
  local status i poll=${DEPLOY_POLL_SECONDS:-10}
  for i in $(seq 1 90); do
    sleep "$poll"
    status=$(capi GET "/deployments/$1" | jq -r '.status // "unknown"')
    echo "[$((i * poll))s] $status"
    case "$status" in
      finished) return 0 ;;
      failed|cancelled*) deploy_logs "$1"; return 1 ;;
    esac
  done
  echo "Timed out after 15 min; deployment $1 still $status" >&2
  return 1
}

# deploy_and_wait APP_UUID -> prints the rollback point, dumps the app's database (DB_UUID from
# the state file; DEPLOY_SKIP_DUMP=1 skips it), then triggers a deploy and waits for it.
# A failed dump aborts before anything is deployed. Prints the rollback commands at the end.
# Records ROLLBACK_COMMIT and LAST_DUMP in the state file for ROLLBACK.md.
# ROLLBACK_MODE=1 (the rebuild fallback in ROLLBACK.md): no dump, and ROLLBACK_COMMIT is left
# as it is, so the rollback point stays the last good version, not the bad one being replaced.
deploy_and_wait() {
  local res dep prev db="" dump="" rc
  if [ "${ROLLBACK_MODE:-0}" = 1 ]; then
    prev=$(state_get ROLLBACK_COMMIT)
    echo "rollback point: kept at ${prev:-none} (ROLLBACK_MODE=1)"
    echo "database dump: skipped (ROLLBACK_MODE=1; the dump from before the bad deploy is the one to keep)"
  else
    prev=$(rollback_point "$1") || return 1
    if [ -n "$prev" ]; then
      if rollback_image_present "$1" "$prev"; then
        echo "rollback point: commit $prev (image on the server)"
      else
        echo "rollback point: commit $prev (image not on the server; a rollback rebuilds it)"
      fi
      state_set ROLLBACK_COMMIT "$prev"
    else
      echo "rollback point: none (no finished deployment yet)"
    fi
    db=$(state_get DB_UUID)
    if [ "${DEPLOY_SKIP_DUMP:-0}" = 1 ]; then
      echo "database dump: skipped (DEPLOY_SKIP_DUMP=1)"
    elif [ -z "$db" ]; then
      echo "database dump: none (no DB_UUID in $VPS_STATE)"
    else
      dump=$(db_dump "$db") || { echo "database dump failed; nothing was deployed. Fix the cause, or DEPLOY_SKIP_DUMP=1 to deploy without a dump." >&2; return 1; }
      dump=${dump%% *}
      echo "database dump: $dump"
      state_set LAST_DUMP "$dump"
    fi
  fi
  res=$(capi POST "/deploy?uuid=$1") || return 1  # GET returns 405 since Coolify 4.3
  dep=$(jq -r '.deployments[0].deployment_uuid // .deployment_uuid // empty' <<<"$res")
  [ -n "$dep" ] || { echo "No deployment uuid in: $res" >&2; return 1; }
  echo "deployment $dep queued"
  wait_deployment "$dep"; rc=$?
  if [ -n "$prev" ]; then
    if [ "$rc" = 0 ]; then echo "If this version turns out wrong, roll back with (ROLLBACK.md):"
    else echo "Deployment $dep failed. Back to the previous version (ROLLBACK.md):"; fi
    echo "  . ./lib.sh; rollback_and_wait $1 $prev"
    [ -n "$dump" ] && echo "  only if a migration broke the data: db_restore $db $dump"
  elif [ "$rc" != 0 ]; then
    echo "Deployment $dep failed; no earlier version to roll back to. Fix the cause and deploy again."
  fi
  return "$rc"
}

# rollback_and_wait APP_UUID COMMIT -> redeploys the image Coolify built for COMMIT
# (POST /applications/{uuid}/rollback, no rebuild) and waits for it.
rollback_and_wait() {
  local res dep
  res=$(capi POST "/applications/$1/rollback" "$(jq -n --arg c "$2" '{commit:$c}')") || return 1
  dep=$(jq -r '.deployment_uuid // .deployments[0].deployment_uuid // empty' <<<"$res")
  [ -n "$dep" ] || { echo "No deployment uuid in: $res" >&2; return 1; }
  echo "rollback deployment $dep queued (to commit $2)"
  wait_deployment "$dep"
}

# deploy_logs DEPLOYMENT_UUID -> last 60 visible build log lines.
deploy_logs() {
  capi GET "/deployments/$1" |
    jq -r '(.logs // "[]") | (fromjson? // []) | .[] | select(.hidden != true) | .output' |
    tail -60
}

# app_logs APP_UUID [N] -> the last N (default 100, at most 10000) lines of the app's runtime
# logs (GET /applications/{uuid}/logs?lines=N, read-only; DOCTOR.md). Coolify answers 400
# "Application is not running." when no container runs: that is said plainly, return 1.
app_logs() {
  local n=${2:-100} r
  [ -n "${1:-}" ] || { echo "usage: app_logs APP_UUID [N]" >&2; return 1; }
  case "$n" in ''|*[!0-9]*|0*) n=x ;; esac
  [ "$n" != x ] && [ "${#n}" -le 5 ] && [ "$n" -le 10000 ] ||
    { echo "app_logs: N must be an integer from 1 to 10000, got '${2:-}'" >&2; return 1; }
  # capi writes only the body to stdout on success and only its error line on failure.
  if ! r=$(capi GET "/applications/$1/logs?lines=$n" 2>&1); then
    case "$r" in
      "HTTP 400 "*"not running"*)
        echo "app_logs: app $1 is not running, so there are no runtime logs; check the container: rssh \"docker ps -a --filter name=$1\"" >&2 ;;
      *) echo "$r" >&2 ;;
    esac
    return 1
  fi
  jq -r '.logs // empty' <<<"$r"
}

# --- handover: who can get in (HANDOVER.md), read-only ---

# team_members -> members of the token's team (GET /team/members) as TSV: name, email, email
# verified (yes/no), 2FA (on/off). The API has no role field; that is said on stderr.
team_members() {
  local r
  r=$(capi GET /team/members) || return 1
  printf 'name\temail\tverified\t2fa\n'
  jq -r '.[]? | [(.name // ""), (.email // ""), (if .email_verified_at then "yes" else "no" end),
    (if .two_factor_confirmed_at then "on" else "off" end)] | @tsv' <<<"$r"
  echo "team_members: role is not in the API; see Team -> Members in the Coolify UI" >&2
}

# ssh_keys_list -> private keys stored in Coolify for the token's team (GET /security/keys) as
# TSV: uuid, name, fingerprint, git-related (yes/no). A root token gets the private key in the
# answer: only these four fields are ever printed, never public_key or private_key.
ssh_keys_list() {
  local r
  r=$(capi GET /security/keys) || return 1
  printf 'uuid\tname\tfingerprint\tgit_related\n'
  jq -r '.[]? | [(.uuid // ""), (.name // ""), (.fingerprint // ""), (if .is_git_related then "yes" else "no" end)] | @tsv' <<<"$r"
}

# --- self-hosted tools: Coolify one-click services (R10, SERVICES.md) ---

# The one-click templates this guide supports on Coolify 4.3.23. In each of them the compose
# service that serves the web UI has the template's name, so that is the default for the
# domain [verify]. A new type is one more word here, after a run on a server.
SERVICE_TYPES="umami n8n uptime-kuma forgejo"

# service_valid_uuid UUID -> 0 for a Coolify-style uuid (letters, digits, - and _), so it is safe
# in an API path.
service_valid_uuid() {
  case ${1:-} in ''|*[!A-Za-z0-9_-]*) echo "not a Coolify uuid: '${1:-}'" >&2; return 1 ;; esac
}

# service_create TYPE NAME DOMAIN [COMPOSE_SERVICE] -> creates the one-click service TYPE named
# NAME in the setup's project (PROJECT_UUID), environment production, with https://DOMAIN on
# COMPOSE_SERVICE (default: TYPE), and starts it (instant_deploy). Records
# SERVICE_<NAME>_UUID (upper case, - as _). On a domain conflict (409) or a validation error
# (422) Coolify deletes the new service again [verify]; the reason is printed, nothing to clean up.
service_create() {
  local type=${1:-} name=${2:-} domain svc=${4:-${1:-}} project server body res code msg key uuid
  domain=$(tr '[:upper:]' '[:lower:]' <<<"${3:-}")
  [ -n "$type" ] && [ -n "$name" ] && [ -n "$domain" ] ||
    { echo "usage: service_create TYPE NAME DOMAIN [COMPOSE_SERVICE]  (TYPE: $SERVICE_TYPES)" >&2; return 1; }
  case " $SERVICE_TYPES " in
    *" $type "*) ;;
    *) echo "service type '$type' is not supported; one of: $SERVICE_TYPES (SERVICES.md)" >&2; return 1 ;;
  esac
  case $name in
    ''|-*|*[!a-z0-9-]*) echo "service name must be lower-case letters, digits and dashes, got '$name'" >&2; return 1 ;;
  esac
  case $domain in
    *[!a-z0-9.-]*|.*|*.|*..*|-*|*.-*|*-.*|*-) domain=x ;;
    *.*) [ "${#domain}" -le 253 ] || domain=x ;;
    *) domain=x ;;
  esac
  [ "$domain" != x ] ||
    { echo "not a domain name: '${3:-}' (the host only, like stats.example.com, no https://)" >&2; return 1; }
  case $svc in ''|*[!a-z0-9_-]*) echo "not a compose service name: '$svc'" >&2; return 1 ;; esac
  key=SERVICE_$(tr 'a-z-' 'A-Z_' <<<"$name")_UUID
  if [ -n "$(state_get "$key")" ]; then
    echo "service $name already recorded as $key=$(state_get "$key"); pick another name, or service_delete it first. Nothing was created." >&2; return 1
  fi
  project=$(state_get PROJECT_UUID)
  [ -n "$project" ] || { echo "service_create: no PROJECT_UUID in $VPS_STATE (phase 05)" >&2; return 1; }
  server=$(coolify_server) && [ -n "$server" ] || { echo "service_create: no Coolify server found (phase 04 step 4)" >&2; return 1; }
  body=$(jq -n --arg t "$type" --arg n "$name" --arg p "$project" --arg s "$server" --arg c "$svc" --arg u "https://$domain" \
    '{type:$t, name:$n, project_uuid:$p, server_uuid:$s, environment_name:"production",
      instant_deploy:true, urls:[{name:$c, url:$u}]}') || return 1
  if ! res=$(capi POST /services "$body" 2>&1); then
    # capi's error is "HTTP <code> POST /services: <body>"
    code=$(sed -n '1s/^HTTP \([0-9]*\) .*/\1/p' <<<"$res")
    msg=$(sed '1s/^HTTP [0-9]* [A-Z]* [^ ]*: //' <<<"$res")
    case $code in
      409)
        msg=$(jq -r '[.conflicts[]? | "\(.resource_name // .resource_uuid // "another resource")\(if .resource_type then " (\(.resource_type))" else "" end)"]
          | unique | join(", ")' <<<"$msg" 2>/dev/null)
        echo "domain $domain is already used by ${msg:-another resource in Coolify}; pick another domain or free this one first. Nothing was created." >&2 ;;
      422)
        msg=$(jq -r '[.message // empty] + [(.errors // {}) | to_entries[]
          | "\(.key): \(.value | if type == "array" then join(" ") else tostring end)"] | join("; ")' <<<"$msg" 2>/dev/null)
        echo "Coolify refused the service (HTTP 422): ${msg:-no message}. Nothing was created." >&2 ;;
      *) echo "$res" >&2 ;;
    esac
    return 1
  fi
  uuid=$(jq -r '.uuid // empty' <<<"$res")
  [ -n "$uuid" ] || { echo "no uuid in the response to POST /services" >&2; return 1; }
  state_set "$key" "$uuid"
  echo "service $name ($type) created: $uuid, recorded as $key"
  echo "domain: $(jq -r '[.domains[]? | if type == "string" then . else (.url // .domain // tostring) end] | join(", ")
    | if . == "" then "none in the answer" else . end' <<<"$res")"
  echo "Coolify is pulling the images and starting it; next: the HTTPS wait (SERVICES.md step 4)."
}

# service_status [UUID] -> every service (or one) as TSV, read-only: kind (service, app, db),
# service, name, status, fqdn, restart_limit (yes/no). The rows of a service follow its own row.
service_status() {
  local r
  if [ -n "${1:-}" ]; then
    service_valid_uuid "$1" || return 1
    r=$(capi GET "/services/$1") || return 1
  else
    r=$(capi GET /services) || return 1
  fi
  printf 'kind\tservice\tname\tstatus\tfqdn\trestart_limit\n'
  jq -r '(if type == "array" then .[] else . end) | (.name // "") as $s
    | ["service", $s, $s, (.status // "unknown"), "", ""],
      (.applications[]? | ["app", $s, (.name // ""), (.status // "unknown"), (.fqdn // ""),
        (if .restart_limit_reached == true then "yes" else "no" end)]),
      (.databases[]? | ["db", $s, (.name // ""), (.status // "unknown"), "", ""])
    | @tsv' <<<"$r"
}

# service_delete UUID --yes -> deletes the service with its volumes (DELETE
# /services/{uuid}?delete_volumes=true): its database and every file it stored are gone. Without
# --yes it refuses and sends nothing; pass --yes only after the user said yes to exactly this.
service_delete() {
  local uuid=${1:-} r name
  [ -n "$uuid" ] || { echo "usage: service_delete UUID --yes" >&2; return 1; }
  service_valid_uuid "$uuid" || return 1
  if [ "${2:-}" != --yes ]; then
    echo "service_delete: refusing without --yes. This deletes service $uuid with its volumes: its database and files are gone for good. Ask the user, then: service_delete $uuid --yes" >&2
    return 1
  fi
  r=$(capi GET "/services/$uuid") || return 1
  name=$(jq -r '.name // "?"' <<<"$r")
  capi DELETE "/services/$uuid?delete_volumes=true" >/dev/null || return 1
  echo "service $name ($uuid) deleted with its volumes; Coolify removes the containers in the background"
}

# --- off-site backups: Coolify scheduled backups copied to S3-compatible storage (RESTORE.md) ---

# S3 credentials: S3_KEY= and S3_SECRET= lines in S3_ENV (default ~/.config/vps-setup/s3.env,
# mode 600), typed in by the user (phase 06 step 1). Kept after setup: db_fetch_from_s3 needs them
# for a restore. Read with grep, never sourced, and never put on a command line: jq gets them
# through its environment, Coolify through capi's stdin, the server through the ssh stdin.
s3_env_file() { echo "${S3_ENV:-$HOME/.config/vps-setup/s3.env}"; }
s3_cred() { grep -m1 "^$1=" "$(s3_env_file)" 2>/dev/null | cut -d= -f2-; }

# s3_env_check -> 0 when the credentials file exists, is private and has both lines.
s3_env_check() {
  local f mode; f=$(s3_env_file)
  [ -f "$f" ] || { echo "no S3 credentials: $f is missing (phase 06 step 1)" >&2; return 1; }
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
  case "$mode" in 600|400) ;; *) echo "refusing $f: mode $mode, must be 600 (chmod 600 $f)" >&2; return 1 ;; esac
  [ -n "$(s3_cred S3_KEY)" ] && [ -n "$(s3_cred S3_SECRET)" ] ||
    { echo "$f needs a S3_KEY= and a S3_SECRET= line" >&2; return 1; }
}

# s3_storage_find NAME -> uuid of the Coolify S3 storage with that name, empty when there is none.
s3_storage_find() {
  local r; r=$(capi GET /s3-storages) || return 1
  jq -r --arg n "$1" '[.[]? | select(.name == $n)][0].uuid // empty' <<<"$r"
}

# s3_storage_create NAME ENDPOINT BUCKET REGION -> creates the S3 storage in Coolify (or, when
# NAME exists, updates it with the current credentials), validates it (Coolify lists the bucket)
# and records S3_STORAGE_UUID. Fails, with Coolify's message, when validation fails.
s3_storage_create() {
  local name=${1:-} endpoint=${2:-} bucket=${3:-} region=${4:-} uuid body res
  [ -n "$name" ] && [ -n "$endpoint" ] && [ -n "$bucket" ] && [ -n "$region" ] ||
    { echo "usage: s3_storage_create NAME ENDPOINT BUCKET REGION" >&2; return 1; }
  s3_env_check || return 1
  uuid=$(s3_storage_find "$name") || return 1
  body=$(S3_K=$(s3_cred S3_KEY) S3_S=$(s3_cred S3_SECRET) jq -n --arg n "$name" --arg e "$endpoint" \
    --arg b "$bucket" --arg r "$region" \
    '{name:$n, description:"off-site database backups (vps-setup)", endpoint:$e, bucket:$b, region:$r,
      key:env.S3_K, secret:env.S3_S, is_usable:true}') || return 1
  if [ -n "$uuid" ]; then
    capi PATCH "/s3-storages/$uuid" "$body" >/dev/null || return 1
    echo "S3 storage $name exists ($uuid); endpoint, bucket and credentials updated"
  else
    res=$(capi POST /s3-storages "$body") || return 1
    uuid=$(jq -r '.uuid // empty' <<<"$res")
    [ -n "$uuid" ] || { echo "no uuid in the response to POST /s3-storages" >&2; return 1; }
    echo "S3 storage $name created ($uuid)"
  fi
  body=
  res=$(capi POST "/s3-storages/$uuid/validate") || return 1
  if [ "$(jq -r '.valid' <<<"$res")" != true ]; then
    echo "S3 storage $uuid failed validation: $(jq -r '.message // "no message"' <<<"$res")" >&2
    echo "Check endpoint, bucket, region and the key pair. Fix it in Coolify (Settings -> S3 Storages) or correct $(s3_env_file) and run this again." >&2
    return 1
  fi
  state_set S3_STORAGE_UUID "$uuid"
  echo "S3 storage $uuid valid: $(jq -r '.message // ""' <<<"$res")"
  echo "Keep $(s3_env_file): a restore (RESTORE.md) reads it to download a backup."
}

# db_backup_attach_s3 DB_UUID S3_UUID [FREQ] -> the database's first scheduled backup also goes
# to S3 (30 copies kept there); without a schedule, creates one (FREQ, default "0 2 * * *",
# 7 kept on the server, 30 in S3). Records BACKUP_UUID.
db_backup_attach_s3() {
  local db=${1:-} s3=${2:-} freq=${3:-"0 2 * * *"} r id res
  [ -n "$db" ] && [ -n "$s3" ] || { echo "usage: db_backup_attach_s3 DB_UUID S3_UUID [FREQ]" >&2; return 1; }
  r=$(capi GET "/databases/$db/backups") || return 1
  id=$(jq -r 'if type == "array" then (.[0].uuid // empty) else empty end' <<<"$r")
  if [ -n "$id" ]; then
    capi PATCH "/databases/$db/backups/$id" "$(jq -n --arg s "$s3" \
      '{save_s3:true, s3_storage_uuid:$s, database_backup_retention_amount_s3:30}')" >/dev/null || return 1
    echo "backup schedule $id of $db ($(jq -r '.[0].frequency // "?"' <<<"$r")): copies now also go to S3 storage $s3, 30 kept there"
    [ "$(jq -r '.[0].enabled' <<<"$r")" = false ] && echo "note: schedule $id is disabled; enable it in Coolify (database -> Backups) or nothing runs"
  else
    res=$(capi POST "/databases/$db/backups" "$(jq -n --arg f "$freq" --arg s "$s3" \
      '{frequency:$f, enabled:true, save_s3:true, s3_storage_uuid:$s,
        database_backup_retention_amount_locally:7, database_backup_retention_amount_s3:30}')") || return 1
    id=$(jq -r '.uuid // empty' <<<"$res")
    [ -n "$id" ] || { echo "no uuid in the response to POST /databases/$db/backups" >&2; return 1; }
    echo "backup schedule $id created for $db: '$freq', 7 kept on the server, 30 in S3 storage $s3"
  fi
  state_set BACKUP_UUID "$id"
}

# db_backup_executions DB_UUID BACKUP_UUID -> JSON array of the schedule's executions.
db_backup_executions() {
  local r; r=$(capi GET "/databases/$1/backups/$2/executions") || return 1
  jq -c 'if type == "array" then . else (.executions // []) end' <<<"$r"
}

# jq: the S3 state of one execution of a schedule that saves to S3. Coolify keeps the status
# "success" when only the upload failed and puts "Warning: S3 upload failed: ..." in the message;
# the model has s3_uploaded, but the 4.3.23 API was not seen returning it [verify].
# shellcheck disable=SC2016 # jq program, not shell
JQ_S3_STATE='def s3state:
  if .status != "success" then "-"
  elif has("s3_uploaded") then (if .s3_uploaded == true then "uploaded" else "not-uploaded" end)
  elif ((.message // "") | test("S3 upload failed")) then "upload-failed"
  else "unreported" end;'

# db_backup_now DB_UUID BACKUP_UUID -> runs the scheduled backup now (PATCH backup_now:true),
# waits for the new execution (BACKUP_POLL_SECONDS x BACKUP_POLL_TRIES, default 10 x 90) and
# prints its status, file and S3 result. Non-zero when the backup or the S3 upload failed.
db_backup_now() {
  local db=${1:-} bk=${2:-} before all new st s3 i poll=${BACKUP_POLL_SECONDS:-10} tries=${BACKUP_POLL_TRIES:-90}
  [ -n "$db" ] && [ -n "$bk" ] || { echo "usage: db_backup_now DB_UUID BACKUP_UUID" >&2; return 1; }
  all=$(db_backup_executions "$db" "$bk") || return 1
  before=$(jq -c 'map(.uuid)' <<<"$all")
  capi PATCH "/databases/$db/backups/$bk" '{"backup_now":true}' >/dev/null || return 1
  echo "backup of $db started (schedule $bk)"
  for i in $(seq 1 "$tries"); do
    sleep "$poll"
    all=$(db_backup_executions "$db" "$bk") || continue
    new=$(jq -c --argjson b "$before" \
      'map(select(.uuid as $u | $b | any(. == $u) | not)) | sort_by(.created_at // "") | last // empty' <<<"$all")
    [ -n "$new" ] || { echo "[$((i * poll))s] waiting for the run to appear"; continue; }
    st=$(jq -r '.status // "unknown"' <<<"$new")
    echo "[$((i * poll))s] $st"
    [ "$st" = running ] && continue
    jq -r '"execution \(.uuid): \(.status), file \(.filename // "?"), \(.size // "?") bytes"' <<<"$new"
    if [ "$st" != success ]; then
      echo "backup failed: $(jq -r '.message // "no message"' <<<"$new")" >&2; return 1
    fi
    s3=$(jq -r "$JQ_S3_STATE"' s3state' <<<"$new")
    case "$s3" in
      uploaded) echo "S3: uploaded" ;;
      unreported) echo "S3: no upload error in the message (this Coolify does not report s3_uploaded)" ;;
      *) echo "S3: upload FAILED: $(jq -r '.message // "s3_uploaded is false"' <<<"$new")" >&2; return 1 ;;
    esac
    return 0
  done
  echo "Timed out after $((tries * poll))s; no finished backup run of schedule $bk" >&2
  return 1
}

# db_backup_list DB_UUID -> every execution of every backup schedule of the database, newest
# first: schedule, execution, created_at, status, size, S3 state, filename (the argument for
# db_fetch_from_s3). S3 state: uploaded, not-uploaded, upload-failed, unreported (the API gives no
# s3_uploaded and the message has no upload error), local (schedule without S3), - (not a success).
db_backup_list() {
  local r ids id s3 ex
  r=$(capi GET "/databases/${1:?usage: db_backup_list DB_UUID}/backups") || return 1
  ids=$(jq -r 'if type == "array" then .[].uuid else empty end' <<<"$r")
  [ -n "$ids" ] || { echo "no backup schedule for $1" >&2; return 1; }
  printf 'schedule\texecution\tcreated_at\tstatus\tsize\ts3\tfilename\n'
  for id in $ids; do
    s3=$(jq -r --arg id "$id" '.[] | select(.uuid == $id) | .save_s3 == true' <<<"$r")
    ex=$(db_backup_executions "$1" "$id") || return 1
    jq -r --arg id "$id" --argjson s3 "$s3" "$JQ_S3_STATE"'
      sort_by(.created_at // "") | reverse | .[]
      | [$id, .uuid, .created_at, .status, (.size // "" | tostring),
         (if $s3 then s3state else "local" end), (.filename // "")] | @tsv' <<<"$ex"
  done
}

# Image used on the server to run mc. Empty = the newest coolify-helper image already on the
# server (Coolify uploads backups with the mc inside it; minio/mc is no longer on Docker Hub).
MC_IMAGE=${MC_IMAGE:-}

# Where Coolify puts database backups, in the bucket as on the server: <bucket>/data/coolify/
# backups/databases/<team slug>-<team id>/<database name slug>-<database uuid>/<file> [verify].
S3_BACKUP_PREFIX=data/coolify/backups/databases/

# s3_mc_prepare CALLER -> sets the caller's `bucket` and `mchost` (declare both local first) from
# the S3 storage in S3_STORAGE_UUID (the app's state, else the setup state: phase 06 records it
# there) and s3.env. Refuses, before any ssh, without the uuid or a private s3.env.
s3_mc_prepare() {
  local s3 info endpoint
  s3=$(state_get S3_STORAGE_UUID); [ -n "$s3" ] || s3=$(VPS_STATE=$VPS_SETUP_STATE state_get S3_STORAGE_UUID)
  [ -n "$s3" ] || { echo "$1: no S3_STORAGE_UUID in $VPS_STATE or $VPS_SETUP_STATE (phase 06 step 1b)" >&2; return 1; }
  s3_env_check || return 1
  info=$(capi GET "/s3-storages/$s3") || return 1
  endpoint=$(jq -r '.endpoint // empty' <<<"$info"); bucket=$(jq -r '.bucket // empty' <<<"$info")
  [ -n "$endpoint" ] && [ -n "$bucket" ] || { echo "S3 storage $s3 has no endpoint or bucket" >&2; return 1; }
  # MC_HOST_<alias>=https://KEY:SECRET@host; key and secret percent-encoded [verify].
  mchost=$(S3_K=$(s3_cred S3_KEY) S3_S=$(s3_cred S3_SECRET) jq -nr --arg e "$endpoint" \
    '($e | capture("^(?<s>https?://)?(?<h>.*?)/*$")) as $m
     | "\($m.s // "https://")\(env.S3_K | @uri):\(env.S3_S | @uri)@\($m.h)"')
}

# s3_mc_head MCHOST -> the start of a server script that runs mc: the credentials in an env file
# (mode 600, deleted on exit; the script text travels over the ssh stdin, never a command line)
# and mc_image [IMAGE] (IMAGE, or the newest coolify-helper on the server).
s3_mc_head() {
  cat <<'EOF'
set -eu; umask 077
envf=$(mktemp); trap 'rm -f "$envf"' EXIT
cat > "$envf" <<'CREDS'
EOF
  printf 'MC_HOST_s3=%s\nCREDS\n' "$1"
  cat <<'EOF'
mc_image() {
  [ -z "${1:-}" ] || { echo "$1"; return 0; }
  i=$(docker images --format '{{.Repository}}:{{.Tag}}' ghcr.io/coollabsio/coolify-helper | grep -E ':[0-9]' | sort -V | tail -n 1)
  [ -n "$i" ] || { echo "no coolify-helper image on the server; set MC_IMAGE" >&2; return 1; }
  echo "$i"
}
EOF
}

# db_fetch_from_s3 DB_UUID EXEC_FILENAME -> downloads one backup (the execution's filename, as
# db_backup_list prints it, or a key from s3_backup_list) from the S3 storage in S3_STORAGE_UUID
# onto the server, into DUMP_DIR/<DB_UUID>/s3-<basename> (mode 600); prints "<path> <bytes>".
# Then: db_restore with that path. Runs mc in a throwaway container; the credentials go over the
# ssh stdin into an env file (mode 600, deleted on exit), never on a command line.
db_fetch_from_s3() {
  local db=${1:-} file=${2:-} bucket mchost obj base
  [ -n "$db" ] && [ -n "$file" ] || { echo "usage: db_fetch_from_s3 DB_UUID EXEC_FILENAME" >&2; return 1; }
  s3_mc_prepare db_fetch_from_s3 || return 1
  # Coolify uploads to <bucket>/<filename without the leading slash>.
  obj=${file#/}; base=${obj##*/}
  case "$base" in ''|.|..) echo "not a backup file name: $file" >&2; return 1 ;; esac
  {
    s3_mc_head "$mchost"
    cat <<'EOF'
dir=$4/$1; mkdir -p "$dir"; chmod 700 "$4" "$dir"
f=$dir/s3-$3
img=$(mc_image "${5:-}")
if docker run --rm --env-file "$envf" -v "$dir:/out" --entrypoint mc "$img" --quiet cp "s3/$2" "/out/s3-$3" >/dev/null && [ -s "$f" ]; then
  chmod 600 "$f"; echo "$f $(stat -c %s "$f")"
else
  rm -f "$f"; echo "download of s3/$2 failed" >&2; exit 1
fi
EOF
  } | rssh "sh -s -- $(printf %q "$db") $(printf %q "$bucket/$obj") $(printf %q "$base") $(printf %q "$DUMP_DIR") $(printf %q "${MC_IMAGE:-}")"
}

# s3_backup_list [DB_UUID] -> the database backups in the bucket itself (not Coolify's execution
# list: a new Coolify knows none of the old server's runs), for REBUILD.md. TSV with a header:
# db_uuid, last_modified, size, key; newest first; only DB_UUID's when given. The key is the
# argument for db_fetch_from_s3. Runs `mc ls` on the server like db_fetch_from_s3 (credentials over
# the ssh stdin into an env file, mode 600, deleted on exit). Read only.
s3_backup_list() {
  local want=${1:-} bucket mchost res rc found rows
  case "$want" in *[!A-Za-z0-9]*) echo "s3_backup_list: not a database uuid: '$want'" >&2; return 1 ;; esac
  s3_mc_prepare s3_backup_list || return 1
  res=$({
    s3_mc_head "$mchost"
    cat <<'EOF'
img=$(mc_image "${2:-}")
docker run --rm --env-file "$envf" --entrypoint mc "$img" --json ls --recursive "s3/$1" || exit 3
EOF
  } | rssh "sh -s -- $(printf %q "$bucket/$S3_BACKUP_PREFIX") $(printf %q "${MC_IMAGE:-}")"); rc=$?
  if [ "$rc" = 3 ]; then
    # mc --json reports errors on stdout: {"status":"error","error":{"message", "cause":{"message"}}} [verify]
    res=$(jq -Rr 'fromjson? | objects | select(.status == "error") | (.error.cause.message // .error.message // empty)' <<<"$res" | head -n 1)
    # A bucket without the prefix answers "Object does not exist": nothing backed up yet, not bad keys.
    case "$res" in *[Oo]bject\ does\ not\ exist*) echo "no backups in s3/$bucket/$S3_BACKUP_PREFIX ($res)" >&2; return 1 ;; esac
    echo "listing of s3/$bucket/$S3_BACKUP_PREFIX failed${res:+: $res} (wrong key pair or bucket: phase 06 step 1a and 1b)" >&2
    return 1
  fi
  [ "$rc" = 0 ] || return 1
  # One JSON object per file: {status, type, lastModified, size, key}; the key is relative to
  # the listed prefix [verify], a full key is accepted too. Sorted by time, offsets honoured.
  rows=$(jq -Rnr --arg p "$S3_BACKUP_PREFIX" '
    def epoch: try (capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>.*)$")
      | (.b + "Z" | fromdateiso8601) - (.z | if test("^[+-][0-9]{2}:[0-9]{2}$")
          then (if .[0:1] == "-" then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[4:6] | tonumber) * 60)
          else 0 end)) catch 0;
    [inputs | fromjson? | objects | select(.status == "success" and .type == "file")
      | (.key | ltrimstr($p)) as $rel | ($rel | split("/")) as $parts | select(($parts | length) >= 3)
      | {db: ($parts[-2] | split("-") | last), t: .lastModified, e: (.lastModified | epoch), size: .size, key: ($p + $rel)}]
    | sort_by(.e) | reverse | .[] | [.db, .t, (.size | tostring), .key] | @tsv' <<<"$res")
  [ -n "$rows" ] || { echo "no backups in s3/$bucket/$S3_BACKUP_PREFIX" >&2; return 1; }
  if [ -n "$want" ]; then
    found=$(cut -f1 <<<"$rows" | sort -u | paste -sd ' ' -)
    rows=$(awk -F '\t' -v w="$want" '$1 == w' <<<"$rows")
    [ -n "$rows" ] || { echo "no backups for database $want in s3/$bucket/$S3_BACKUP_PREFIX (backups there are of: $found)" >&2; return 1; }
  fi
  printf 'db_uuid\tlast_modified\tsize\tkey\n%s\n' "$rows"
}

# --- alerts: Coolify notifications to Discord (R06a, phase 06 step 2) ---

# Events that page a person. status_change is the "app stopped" alert: in the 4.3.23 source
# Coolify sends StatusChanged ("<resource> has been stopped") and ContainerRestarted through it,
# and nothing else reports an app that went down. The *_success events stay off: they fire on
# every routine deploy and backup. status.sh reads this list too. Coolify names each setting
# <event>_<channel>_notifications.
NOTIFY_EVENTS="status_change deployment_failure backup_failure server_unreachable server_reachable server_disk_usage restart_limit_reached"
# Every channel Coolify has (GET/PATCH /notifications/<channel>); notify_setup drives discord only.
# shellcheck disable=SC2034 # read by status.sh
NOTIFY_CHANNELS="email discord slack telegram pushover webhook"

# The webhook URL: a DISCORD_WEBHOOK_URL= line in NOTIFY_ENV (default
# ~/.config/vps-setup/notify.env, mode 600), typed in by the user (phase 06 step 2). Anyone with
# the URL can post into the channel, so it is handled like the S3 keys: read with grep, never
# sourced, never on a command line (jq gets it through its environment, Coolify through capi's
# stdin), and no Coolify response to a PATCH is ever printed (it may echo the URL).
notify_env_file() { echo "${NOTIFY_ENV:-$HOME/.config/vps-setup/notify.env}"; }
notify_cred() { grep -m1 "^$1=" "$(notify_env_file)" 2>/dev/null | cut -d= -f2-; }

# notify_secret_key CHANNEL -> the notify.env key holding that channel's webhook URL; the
# Coolify field is the same name in lower case. A second channel is one more line here.
notify_secret_key() {
  case ${1:-} in
    discord) echo DISCORD_WEBHOOK_URL ;;
    *) echo "notification channel '${1:-}' is not supported; Discord is the one way (phase 06 step 2)" >&2; return 1 ;;
  esac
}

notify_label() { case $1 in discord) echo Discord ;; *) echo "$1" ;; esac; }

# notify_env_check [CHANNEL] -> 0 when notify.env exists, is private and has the channel's URL.
notify_env_check() {
  local f mode key; f=$(notify_env_file); key=$(notify_secret_key "${1:-discord}") || return 1
  [ -f "$f" ] || { echo "no notification webhook: $f is missing (phase 06 step 2)" >&2; return 1; }
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
  case "$mode" in 600|400) ;; *) echo "refusing $f: mode $mode, must be 600 (chmod 600 $f)" >&2; return 1 ;; esac
  [ -n "$(notify_cred "$key")" ] || { echo "$f needs a $key= line" >&2; return 1; }
}

# notify_summary CHANNEL < GET-json -> "<channel>: enabled|disabled, N/M alert events on[ (off: ...)]".
# Returns 1 when the channel is off or an event is missing.
notify_summary() {
  local s state all off list
  s=$(jq -er --arg ch "$1" --arg ev "$NOTIFY_EVENTS" '
    objects | . as $o | ($ev | split(" ")) as $all
    | [$all[] | select($o["\(.)_\($ch)_notifications"] != true)] as $off
    | "\(if .["\($ch)_enabled"] == true then "enabled" else "disabled" end) \($all | length) \($off | length) \($off | join(" "))"
  ' 2>/dev/null) || { echo "$1: could not read the notification settings" >&2; return 1; }
  read -r state all off list <<<"$s"
  echo "$1: $state, $((all - off))/$all alert events on${list:+ (off: $list)}"
  [ "$state" = enabled ] && [ "$off" = 0 ]
}

# notify_status [CHANNEL] -> the channel's state from Coolify (default discord); 1 unless it is
# enabled with every NOTIFY_EVENTS event on.
notify_status() {
  local ch=${1:-discord} r
  r=$(capi GET "/notifications/$ch") || return 1
  notify_summary "$ch" <<<"$r"
}

# notify_setup [CHANNEL] -> turns the channel on in Coolify (the token's team) with the webhook URL
# from notify.env, every NOTIFY_EVENTS event on (Discord: with @here pings), then reads the
# settings back. Records ALERTS=<channel>. Re-running it sets the same values again.
notify_setup() {
  local ch=${1:-discord} key body err code msg url
  key=$(notify_secret_key "$ch") || return 1
  notify_env_check "$ch" || return 1
  body=$(N_URL=$(notify_cred "$key") jq -n --arg ch "$ch" --arg f "$(tr '[:upper:]' '[:lower:]' <<<"$key")" --arg ev "$NOTIFY_EVENTS" '
    {"\($ch)_enabled": true, ($f): env.N_URL}
    + (if $ch == "discord" then {discord_ping_enabled: true} else {} end)
    + ([$ev | split(" ")[] | {key: "\(.)_\($ch)_notifications", value: true}] | from_entries)') || return 1
  # The response is never printed: with a read:sensitive token it echoes the URL.
  if ! err=$(capi PATCH "/notifications/$ch" "$body" 2>&1 >/dev/null); then
    body=
    # capi's error is "HTTP <code> PATCH /path: <body>"; show Coolify's message and the field
    # errors, never the raw body, and blank out the URL should Coolify quote it.
    code=$(sed -n '1s/^HTTP \([0-9]*\) .*/\1/p' <<<"$err")
    msg=$(sed '1s/^HTTP [0-9]* [A-Z]* [^ ]*: //' <<<"$err" | jq -r '
      [.message // empty] + [(.errors // {}) | to_entries[] | "\(.key): \(.value | if type == "array" then join(" ") else tostring end)"]
      | join("; ")' 2>/dev/null)
    url=$(notify_cred "$key")
    [ -n "$url" ] && msg=${msg//"$url"/<webhook URL>}
    # Coolify may quote the URL normalised (case, trailing slash): blank any webhook URL left.
    msg=$(sed -E 's#https?://[^ ;"]*webhooks[^ ;"]*#<webhook URL>#g' <<<"$msg")
    if [ -n "$code" ]; then
      echo "Coolify refused the $ch settings (HTTP $code): ${msg:-no message}" >&2
    else
      echo "$err" >&2   # no HTTP answer: curl's or capi's own message, no body
    fi
    [ "$code" = 422 ] && echo "Check the webhook URL in $(notify_env_file) (phase 06 step 2) and run this again." >&2
    return 1
  fi
  body=
  notify_status "$ch" || { echo "Coolify did not keep the $ch settings; check Coolify -> Notifications -> $(notify_label "$ch")" >&2; return 1; }
  state_set ALERTS "$ch"
  echo "Next: Coolify -> Notifications -> $(notify_label "$ch") -> Send test notification (the API has no test call)."
}

# --- DNS through the Cloudflare API (R18, phases 00, 01, 04; references/cloudflare-api.md) ---

# The token: a CF_API_TOKEN= line in CF_ENV (default ~/.config/vps-setup/cloudflare.env, mode
# 600), typed in by the user (phase 00, question 6). An "Edit zone DNS" token for one zone. Read
# with grep, never sourced, and never on a command line: curl reads the Authorization header from
# a config on its stdin (-K -). CF_API is the base URL (tests point it at a fake API).
cf_env_file() { echo "${CF_ENV:-$HOME/.config/vps-setup/cloudflare.env}"; }
cf_cred() { grep -m1 "^$1=" "$(cf_env_file)" 2>/dev/null | cut -d= -f2-; }

# cf_env_check -> 0 when cloudflare.env exists, is private and has a token line that looks like
# a Cloudflare token (letters, digits, - and _ only, so it cannot break curl's config).
cf_env_check() {
  local f mode tok; f=$(cf_env_file)
  [ -f "$f" ] || { echo "no Cloudflare token: $f is missing (phase 00, question 6)" >&2; return 1; }
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
  case "$mode" in 600|400) ;; *) echo "refusing $f: mode $mode, must be 600 (chmod 600 $f)" >&2; return 1 ;; esac
  tok=$(cf_cred CF_API_TOKEN)
  [ -n "$tok" ] || { echo "$f needs a CF_API_TOKEN= line" >&2; return 1; }
  case $tok in *[!A-Za-z0-9_-]*) echo "CF_API_TOKEN in $f has characters a Cloudflare token does not have; write it again (phase 00, question 6)" >&2; return 1 ;; esac
}

# cfapi METHOD /path [json-body] -> prints the response when Cloudflare says success:true.
# Otherwise returns 1 and prints "code: message" for each error (never the raw body); HTTP 429
# (the rate limit) is said as such. The body goes through a 600 temp file (curl's stdin carries
# the token), deleted when the call ends. Each call gives up after CAPI_MAX_TIME seconds.
cfapi() (
  m=${1:-} p=${2:-} body=${3:-} tmp=
  trap 'rm -f "$tmp"' EXIT
  cf_env_check || exit 1
  if [ -n "$body" ]; then
    tmp=$(umask 077 && mktemp) || exit 1
    printf '%s' "$body" > "$tmp"
  fi
  data=(); [ -n "$tmp" ] && data=(--data-binary "@$tmp")
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$(cf_cred CF_API_TOKEN)" |
    curl -sS --max-time "${CAPI_MAX_TIME:-30}" -w '\n%{http_code}' -X "$m" -K - \
      -H "Accept: application/json" -H "Content-Type: application/json" \
      "${data[@]}" "${CF_API:-https://api.cloudflare.com/client/v4}$p") || exit 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" = 429 ]; then
    echo "Cloudflare rate limit (HTTP 429 on $m $p): at most 1200 requests per 5 minutes; wait 5 minutes, then run it again" >&2
    exit 1
  fi
  if ! jq -e 'type == "object" and has("success")' >/dev/null 2>&1 <<<"$out"; then
    echo "Cloudflare answered HTTP $code to $m $p without its JSON envelope" >&2; exit 1
  fi
  if [ "$(jq -r '.success' <<<"$out")" != true ]; then
    echo "Cloudflare refused $m $p (HTTP $code):" >&2
    jq -r '(.errors // [])[] | "  \(.code // "?"): \(.message // "no message")"' <<<"$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
)

# cf_valid_name NAME -> 0 for a lower-case host name with at least two labels.
cf_valid_name() {
  local n=${1:-}
  [ "${#n}" -le 253 ] && [[ $n =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    { echo "not a host name: '$n' (lower case, like app.example.com)" >&2; return 1; }
}

# cf_valid_ipv4 IP -> 0 for a dotted IPv4 address.
cf_valid_ipv4() {
  local ip=${1:-} o
  if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do
      case $o in 0?*) echo "not an IPv4 address (leading zero): '$ip'" >&2; return 1 ;; esac
      [ "$((10#$o))" -le 255 ] || { echo "not an IPv4 address: '$ip'" >&2; return 1; }
    done
    case ${BASH_REMATCH[1]} in 0|127) echo "not a public IPv4 address: '$ip'" >&2; return 1 ;; esac
    return 0
  fi
  echo "not an IPv4 address: '$ip'" >&2; return 1
}

# The zone lives in the global setup state, also when VPS_STATE points at an app's .coolify.env
# (PREPARE-APP): one domain, one zone, one token per server.

# cf_check -> the token is active and can see the zone of DOMAIN (the longest suffix of DOMAIN
# that is a zone in the account); records CF_ZONE_ID and CF_ZONE and prints both. A zone that
# is not "active" (name servers not moved to Cloudflare yet) is a warning: its records do not
# resolve until it is.
cf_check() {
  local VPS_STATE=$VPS_SETUP_STATE domain cand r st zone id zst
  domain=$(state_get DOMAIN)
  [ -n "$domain" ] || { echo "no DOMAIN in $VPS_STATE (phase 00, question 2)" >&2; return 1; }
  cf_valid_name "$domain" || return 1
  cf_env_check || return 1
  r=$(cfapi GET /user/tokens/verify) || { echo "The Cloudflare token does not work; create a new one (phase 00, question 6)" >&2; return 1; }
  st=$(jq -r '.result.status // "unknown"' <<<"$r")
  [ "$st" = active ] || { echo "Cloudflare token is $st, not active; create a new one (phase 00, question 6)" >&2; return 1; }
  cand=$domain
  while :; do
    r=$(cfapi GET "/zones?name=$cand") || return 1
    id=$(jq -r --arg c "$cand" '[.result[]? | select(.name == $c)][0].id // empty' <<<"$r")
    [ -n "$id" ] && break
    case $cand in *.*.*) cand=${cand#*.} ;; *) cand= ; break ;; esac
  done
  [ -n "$cand" ] || { echo "no Cloudflare zone for $domain that this token can read; create an \"Edit zone DNS\" token for that zone (phase 00, question 6)" >&2; return 1; }
  [[ $id =~ ^[0-9a-f]{32}$ ]] || { echo "unexpected zone id from Cloudflare: '$id'" >&2; return 1; }
  zone=$cand; zst=$(jq -r --arg c "$cand" '[.result[]? | select(.name == $c)][0].status // "unknown"' <<<"$r")
  state_set CF_ZONE_ID "$id"; state_set CF_ZONE "$zone"
  echo "Cloudflare token active; zone $zone ($id), status $zst"
  [ "$zst" = active ] || echo "warning: zone $zone is $zst, not active: its records do not resolve until the domain's name servers are Cloudflare's"
  return 0
}

# cf_zone_of NAME -> the recorded zone id when NAME is the zone or inside it.
cf_zone_of() {
  local VPS_STATE=$VPS_SETUP_STATE z id; z=$(state_get CF_ZONE); id=$(state_get CF_ZONE_ID)
  [ -n "$z" ] && [[ $id =~ ^[0-9a-f]{32}$ ]] || { echo "no Cloudflare zone recorded; run cf_check first (phase 00, question 6)" >&2; return 1; }
  case $1 in "$z"|*."$z") echo "$id" ;; *) echo "$1 is not in the Cloudflare zone $z" >&2; return 1 ;; esac
}

# dns_list NAME -> every record of exactly NAME: type, content, proxied, ttl (1 = automatic).
# Read-only.
dns_list() {
  local name=${1:-} z r
  [ -n "$name" ] || { echo "usage: dns_list NAME" >&2; return 1; }
  cf_valid_name "$name" || return 1
  z=$(cf_zone_of "$name") || return 1
  r=$(cfapi GET "/zones/$z/dns_records?name=$name&per_page=100") || return 1
  if [ "$(jq '.result | length' <<<"$r")" = 0 ]; then echo "no records for $name"; return 0; fi
  printf 'type\tcontent\tproxied\tttl\n'
  jq -r '.result[] | [.type, .content, (.proxied // false | tostring), (.ttl | tostring)] | @tsv' <<<"$r"
}

# dns_set_a NAME IP -> makes NAME an A record to IP, DNS only (proxied false), TTL automatic:
# creates it, leaves it when it already is that, or updates the one A record that differs. Refuses
# (nothing sent) when NAME has a CNAME or several A records. Never deletes a record. Returns 2,
# after the A record is right, when NAME also has an AAAA record: phase 01 wants none, the user
# deletes it in Cloudflare.
dns_set_a() {
  local name=${1:-} ip=${2:-} z r n_a n_aaaa id old oldp res
  [ -n "$name" ] && [ -n "$ip" ] || { echo "usage: dns_set_a NAME IPV4" >&2; return 1; }
  cf_valid_name "$name" || return 1
  cf_valid_ipv4 "$ip" || return 1
  z=$(cf_zone_of "$name") || return 1
  r=$(cfapi GET "/zones/$z/dns_records?name=$name&per_page=100") || return 1
  if [ "$(jq '[.result[] | select(.type == "CNAME")] | length' <<<"$r")" != 0 ]; then
    echo "$name is a CNAME to $(jq -r '[.result[] | select(.type == "CNAME")][0].content' <<<"$r"); an A record cannot sit next to it. Nothing changed. If the CNAME is not needed, the user deletes it in Cloudflare (DNS -> Records), then run this again." >&2
    return 1
  fi
  n_a=$(jq '[.result[] | select(.type == "A")] | length' <<<"$r")
  n_aaaa=$(jq '[.result[] | select(.type == "AAAA")] | length' <<<"$r")
  if [ "$n_a" -gt 1 ]; then
    echo "$name has $n_a A records; nothing changed. The user keeps one (or deletes all) in Cloudflare (DNS -> Records), then run this again:" >&2
    jq -r '.result[] | select(.type == "A") | "  A \(.content) proxied \(.proxied // false)"' <<<"$r" >&2
    return 1
  fi
  if [ "$n_a" = 0 ]; then
    res=$(cfapi POST "/zones/$z/dns_records" "$(jq -n --arg n "$name" --arg ip "$ip" \
      '{type:"A", name:$n, content:$ip, ttl:1, proxied:false, comment:"vps-setup"}')") || return 1
    [ -n "$(jq -r '.result.id // empty' <<<"$res")" ] || { echo "no record id in Cloudflare's answer to the create" >&2; return 1; }
    echo "$name: A created -> $ip (DNS only, TTL auto)"
  else
    id=$(jq -r '[.result[] | select(.type == "A")][0].id' <<<"$r")
    old=$(jq -r '[.result[] | select(.type == "A")][0].content' <<<"$r")
    oldp=$(jq -r '[.result[] | select(.type == "A")][0].proxied // false' <<<"$r")
    if [ "$old" = "$ip" ] && [ "$oldp" = false ]; then
      echo "$name: A unchanged ($ip, DNS only)"
    else
      [[ $id =~ ^[0-9a-f]{32}$ ]] || { echo "unexpected record id from Cloudflare: '$id'" >&2; return 1; }
      cfapi PATCH "/zones/$z/dns_records/$id" "$(jq -n --arg ip "$ip" '{content:$ip, proxied:false}')" >/dev/null || return 1
      echo "$name: A updated $old -> $ip (DNS only$([ "$oldp" = true ] && echo ", proxy was on"))"
    fi
  fi
  if [ "$n_aaaa" != 0 ]; then
    echo "warning: $name also has an AAAA record ($(jq -r '[.result[] | select(.type == "AAAA") | .content] | join(", ")' <<<"$r")); IPv6 visitors and the certificate go there. The user deletes it in Cloudflare (DNS -> Records); this script never deletes records." >&2
    return 2
  fi
  return 0
}

# --- rebuild from nothing (R15, REBUILD.md) ---

# State keys that belong to one server and its Coolify: on a new server they point at nothing,
# and verify.sh and phase 05 would skip steps while they are set (ADMIN_REGISTERED, APP_UUID,
# WEBHOOK, HOOK_ID, HANDOVER_DONE). SERVICE_<NAME>_UUID keys count too. Everything else survives.
REBUILD_CLEAR="VPS_IP SERVER_NAME ADMIN_REGISTERED COOLIFY_VERSION PROJECT_UUID DB_UUID APP_UUID KEY_UUID HOOK_ID WEBHOOK S3_STORAGE_UUID BACKUP_UUID ALERTS HANDOVER_DONE ROLLBACK_COMMIT LAST_DUMP PG_UPGRADE_OLD PG_UPGRADE_NEW PG_UPGRADE_DUMP COOLIFY_PROJECT_UUID COOLIFY_APP_UUID"

rebuild_clears() {
  case " $REBUILD_CLEAR " in *" $1 "*) return 0 ;; esac
  case $1 in SERVICE_?*_UUID) return 0 ;; esac
  return 1
}

# rebuild_inventory -> read only: which keys of VPS_STATE survive a lost server and which belong
# to it, the old DB_UUID (its backups in the bucket are named after it) and the exact commands
# that keep a copy and clear the old keys. Writes nothing; the commands run after the user's yes.
rebuild_inventory() {
  local f=$VPS_STATE day line k v keep="" clear="" cmds="" db
  [ -s "$f" ] || { echo "rebuild_inventory: no state in $f" >&2; return 1; }
  day=$(date -u +%Y%m%d)
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in [A-Za-z_]*=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    if rebuild_clears "$k"; then
      [ -n "$v" ] || continue
      clear+="  $k=$v"$'\n'; cmds+="  state_set $k ''"$'\n'
    else
      keep+="  $k=$v"$'\n'
    fi
  done < "$f"
  db=$(state_get DB_UUID)
  echo "state: $f"
  printf 'survives (kept as is):\n%s' "${keep:-  (nothing)$'\n'}"
  printf 'belongs to the old server (cleared before phase 01):\n%s' "${clear:-  (nothing)$'\n'}"
  if [ -n "$db" ]; then
    echo "old database: $db; its backups: s3_backup_list $db (the copy below keeps the uuid)"
  else
    echo "old database: none in this state"
  fi
  echo "commands, after the user's yes (rebuild_inventory changed nothing):"
  [ "$f" = "$VPS_SETUP_STATE" ] || echo "  VPS_STATE=$(printf %q "$f")"
  echo "  cp -p $(printf %q "$f") $(printf %q "$f.before-rebuild-$day")"
  if [ "$f" = "$VPS_SETUP_STATE" ] && [ -f "${VPS_SETUP_STATE%/*}/SERVER.md" ]; then
    echo "  cp -p $(printf %q "${VPS_SETUP_STATE%/*}/SERVER.md") $(printf %q "${VPS_SETUP_STATE%/*}/SERVER.md.before-rebuild-$day")"
  fi
  printf '%s' "$cmds"
  if [ "$f" = "$VPS_SETUP_STATE" ] && [ -f "$COOLIFY_CONFIG" ]; then
    echo "  mv $(printf %q "$COOLIFY_CONFIG") $(printf %q "$COOLIFY_CONFIG.before-rebuild-$day")"
  fi
}

# --- monthly checkup (R16, CHECKUP.md), read-only ---

# Coolify's own containers that mount the Docker socket on 4.3.23 (docker-compose.prod.yml and
# the proxy and sentinel it starts) [verify]; checkup.sh flags any other container with it.
# shellcheck disable=SC2034 # read by checkup.sh
DOCKER_SOCK_OK="coolify coolify-realtime coolify-proxy coolify-sentinel"
# Short-lived deploy helpers, by image prefix: Coolify builds in them with the socket [verify].
# shellcheck disable=SC2034 # read by checkup.sh
DOCKER_SOCK_OK_IMAGES="ghcr.io/coollabsio/coolify-helper"
# `sshd -T` keys and the values phase 02 step 3 leaves (the last three are Ubuntu 24.04
# defaults) [verify]. sshd prints prohibit-password as without-password.
# shellcheck disable=SC2034 # read by checkup.sh
SSHD_EXPECT="passwordauthentication=no permitrootlogin=without-password pubkeyauthentication=yes permitemptypasswords=no kbdinteractiveauthentication=no"
# The cloud firewall of phase 01 step 2 and its inbound rules. A port opened on purpose later
# (SERVICES.md: Forgejo's 22222) goes into the state key CHECKUP_PORTS_OK, like "tcp/22222".
FIREWALL_NAME=${FIREWALL_NAME:-vps-setup-fw}
# shellcheck disable=SC2034 # read by checkup.sh
FIREWALL_EXPECT="tcp/22 tcp/80 tcp/443 icmp"
# Published security advisories of the Coolify repo (GitHub REST API, no token: 60 calls an hour).
ADVISORIES_URL=${ADVISORIES_URL:-https://api.github.com/repos/coollabsio/coolify/security-advisories?state=published&per_page=100}

# hcloud_json RESOURCE list|describe [NAME...] -> the hcloud CLI's JSON answer (-o json). Refuses
# every other action, and any flag, so a checkup can never change anything at Hetzner. The token
# is the hcloud context of phase 01 step 1; it is never read here.
hcloud_json() {
  local sub=${1:-} action=${2:-} a out errf rc
  case $action in
    list|describe) ;;
    *) echo "hcloud_json: only list and describe are allowed (read-only), got '$sub $action'" >&2; return 1 ;;
  esac
  case $sub in ''|-*|*[!a-z-]*) echo "hcloud_json: not an hcloud resource: '$sub'" >&2; return 1 ;; esac
  shift 2
  for a in "$@"; do case $a in -*) echo "hcloud_json: no flags allowed, got '$a'" >&2; return 1 ;; esac; done
  command -v hcloud >/dev/null 2>&1 || { echo "hcloud not installed or not logged in (phase 01 step 1)" >&2; return 1; }
  errf=$(mktemp) || return 1
  out=$(hcloud "$sub" "$action" "$@" -o json 2>"$errf"); rc=$?
  if [ "$rc" != 0 ]; then
    echo "hcloud $sub $action failed: $(head -n 1 "$errf") (not installed or not logged in? phase 01 step 1)" >&2
    rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  jq -e . >/dev/null 2>&1 <<<"$out" || { echo "hcloud $sub $action: no JSON in the answer" >&2; return 1; }
  printf '%s\n' "$out"
}

# firewall_rules [NAME] -> the rules of the Hetzner cloud firewall (default FIREWALL_NAME) as TSV:
# direction, proto, port (- for icmp), sources (comma-separated). Read-only.
firewall_rules() {
  local r; r=$(hcloud_json firewall describe "${1:-$FIREWALL_NAME}") || return 1
  printf 'direction\tproto\tport\tsources\n'
  jq -r '.rules[]? | [(.direction // "?"), (.protocol // "?"), (.port // "-"), ((.source_ips // []) | join(","))] | @tsv' <<<"$r"
}

# firewall_applied NAME SERVER_NAME -> 0 when the firewall is applied to that server, directly or
# through a label selector [verify field names]. Read-only.
firewall_applied() {
  local fw srv id
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: firewall_applied NAME SERVER_NAME" >&2; return 1; }
  fw=$(hcloud_json firewall describe "$1") || return 1
  srv=$(hcloud_json server describe "$2") || return 1
  id=$(jq -r '.id // empty' <<<"$srv")
  [ -n "$id" ] || { echo "no id for server $2 in hcloud's answer" >&2; return 1; }
  jq -e --argjson id "$id" '[.applied_to[]? | (select(.type == "server") | .server.id),
    (.applied_to_resources[]? | select(.type == "server") | .server.id)] | any(. == $id)' >/dev/null <<<"$fw"
}

# checkup_server_facts -> what the checkup needs from the server, in one ssh round trip, as
# tagged lines. Read-only: ss, sshd -T, ssh-keygen -l, ps, docker inspect, df, du. Key comments
# (they may carry email addresses) are not printed. CHECKUP_SSH replaces rssh in tests.
#   listen tcp|udp <local address:port> <process>
#   sshd <key> <value>
#   authkey <bits> <fingerprint> <(type)>
#   dockerd_tcp <tcp://...>            dockerd_hosts <"hosts" from /etc/docker/daemon.json>
#   cont <name> <image> <privileged true|false> [sock:rw|sock:ro]
#   df <used kB> <total kB>   du <path> <kB>   ddf <type>\t<size>\t<reclaimable>
checkup_server_facts() {
  "${CHECKUP_SSH:-rssh}" 'sh -s' <<'EOF'
ss -tlnpH 2>/dev/null | awk '{p=$6; sub(/^users:\(\("/, "", p); sub(/".*/, "", p); print "listen tcp", $4, (p == "" ? "?" : p)}'
ss -ulnpH 2>/dev/null | awk '{p=$6; sub(/^users:\(\("/, "", p); sub(/".*/, "", p); print "listen udp", $4, (p == "" ? "?" : p)}'
sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication|permitemptypasswords|kbdinteractiveauthentication|port) ' | sed 's/^/sshd /'
ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | awk '{print "authkey", $1, $2, $NF}'
ps -o args= -C dockerd 2>/dev/null | grep -oE 'tcp://[^ ]+' | sed 's/^/dockerd_tcp /'
grep -o '"hosts"[^]]*]' /etc/docker/daemon.json 2>/dev/null | sed 's/^/dockerd_hosts /'
docker ps -aq 2>/dev/null | xargs -r docker inspect -f '{{.Name}} {{.Config.Image}} {{.HostConfig.Privileged}}{{range .Mounts}}{{if or (eq .Source "/var/run/docker.sock") (eq .Source "/run/docker.sock")}} sock:{{if .RW}}rw{{else}}ro{{end}}{{end}}{{end}}' | sed 's#^/#cont #'
df -Pk / | awk 'NR == 2 {print "df", $3, $2}'
du -sk /data/coolify/backups /root/db-dumps 2>/dev/null | awk '{print "du", $2, $1}'
docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null | sed 's/^/ddf /'
echo "facts done"
EOF
}

# jq: version strings as comparable arrays. "4.3.23" -> [4,3,23,1,0], "4.0.0-beta.420" ->
# [4,0,0,0,420]: a pre-release sorts before its release. range_match($v) on a GitHub
# vulnerable_version_range ("< 4.3.21", ">= 4.0.0, <= 4.3.23", "= 4.1.0"): true, false, or null
# when the range is missing or cannot be read.
# shellcheck disable=SC2016 # jq program, not shell
JQ_VERSION='def ver:
  ltrimstr("v") | (split("-")[0]) as $b | (split("-")[1:] | join("-")) as $p
  | (($b | split(".") | map(tonumber? // 0)) + [0, 0, 0])[0:3]
    + (if $p == "" then [1, 0, 0, 0] else ([0] + (($p | split(".") | map(tonumber? // 0)) + [0, 0, 0])[1:4]) end);
def range_match($v):
  if type != "string" or (gsub("\\s"; "") == "") then null
  else [split(",")[] | gsub("^\\s+|\\s+$"; "") | capture("^(?<op><=|>=|==|<|>|=)?\\s*(?<w>v?[0-9][0-9A-Za-z.-]*)$")] as $c
    | if ($c | length) != (split(",") | length) then null
      else all($c[]; (.w | ver) as $w | ($v | ver) as $x | (.op // "=") as $o
        | if $o == "<" then $x < $w elif $o == "<=" then $x <= $w elif $o == ">" then $x > $w
          elif $o == ">=" then $x >= $w else $x == $w end) end end;'

# coolify_advisories VERSION -> the published security advisories of Coolify (ADVISORIES_URL) as
# TSV: ghsa_id, severity, published (date), vulnerable range, patched, affected (yes, no, unknown)
# for VERSION; an empty field is -. Return 2 when GitHub does not answer (offline, rate limit: 60 calls an hour without
# a token); the answer's shape is [verify].
coolify_advisories() {
  local v=${1:-} out code
  case $v in v[0-9]*|[0-9]*) ;; *) echo "usage: coolify_advisories VERSION (like 4.3.23)" >&2; return 1 ;; esac
  out=$(curl -sS --max-time 10 -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$ADVISORIES_URL" 2>/dev/null) || { echo "GitHub did not answer (offline?)" >&2; return 2; }
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case $code in
    200) ;;
    403|429) echo "GitHub rate limit (HTTP $code; 60 calls an hour without a token)" >&2; return 2 ;;
    *) echo "GitHub answered HTTP $code to the advisories call" >&2; return 2 ;;
  esac
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || { echo "the advisories answer is not a list" >&2; return 2; }
  printf 'ghsa_id\tseverity\tpublished\tvulnerable\tpatched\taffected\n'
  jq -r --arg v "$v" "$JQ_VERSION"'
    .[] | [(.vulnerabilities // [])[] | {r: .vulnerable_version_range, p: .patched_versions}] as $vs
    | ($vs | map(.r | range_match($v))) as $m
    | [(.ghsa_id // "?"), (.severity // "unknown"), ((.published_at // "-")[0:10]),
       ($vs | map(.r // "?") | join("; ") | if . == "" then "-" else . end),
       ($vs | map(.p // "?") | join("; ") | if . == "" then "-" else . end),
       (if any($m[]; . == true) then "yes" elif ($m | length) == 0 or any($m[]; . == null) then "unknown" else "no" end)]
    | @tsv' <<<"$out"
}

# backup_success_rate DB_UUID [DAYS] -> per backup schedule of the database, the runs of the
# last DAYS days (default 30) as TSV: schedule, frequency, runs, success, failed, s3 (yes/no),
# s3_uploaded, s3_failed, s3_unreported, newest_failure (date or -). Running backups are not
# counted. Coolify deletes old execution rows with its local retention [verify], so a short
# history is not a failure. S3 columns use JQ_S3_STATE; they are 0 for a schedule without S3.
backup_success_rate() {
  local db=${1:-} days=${2:-30} r id ex now
  [ -n "$db" ] || { echo "usage: backup_success_rate DB_UUID [DAYS]" >&2; return 1; }
  service_valid_uuid "$db" || return 1
  case $days in ''|*[!0-9]*|0*) echo "backup_success_rate: DAYS must be a whole number above 0, got '$days'" >&2; return 1 ;; esac
  r=$(capi GET "/databases/$db/backups") || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$r" || { echo "backup schedules of $db: not a list" >&2; return 1; }
  now=$(date +%s)
  printf 'schedule\tfrequency\truns\tsuccess\tfailed\ts3\ts3_uploaded\ts3_failed\ts3_unreported\tnewest_failure\n'
  for id in $(jq -r '.[].uuid | strings' <<<"$r"); do
    service_valid_uuid "$id" || return 1
    ex=$(db_backup_executions "$db" "$id") || return 1
    jq -er --argjson s "$(jq -c --arg id "$id" '.[] | select(.uuid == $id)' <<<"$r")" --argjson now "$now" \
      --argjson days "$days" "$JQ_EPOCH$JQ_S3_STATE"'
      [.[] | select(.status != "running") | . + {t: ((.created_at // .finished_at) | epoch)}
        | select(.t >= $now - $days * 86400)] as $w
      | ($w | map(select(.status == "success"))) as $ok
      | ($w | map(select(.status != "success"))) as $bad
      | (if $s.save_s3 == true then $ok | map(. + {st: s3state}) else [] end) as $s3
      | ($s3 | map(select(.st == "not-uploaded" or .st == "upload-failed"))) as $s3bad
      | [$s.uuid, ($s.frequency // "?"), ($w | length), ($ok | length), ($bad | length),
         (if $s.save_s3 == true then "yes" else "no" end),
         ($s3 | map(select(.st == "uploaded")) | length), ($s3bad | length),
         ($s3 | map(select(.st == "unreported")) | length),
         (($bad + $s3bad) | sort_by(.t) | last | if . == null then "-" else .t | todate[0:10] end)]
      | @tsv' <<<"$ex" 2>/dev/null || { echo "backup runs of schedule $id: could not read" >&2; return 1; }
  done
}

# The checkup log on this machine: one line per checkup with the disk numbers and the cost, for
# the month-over-month growth. Mode 600, no secrets in it.
checkup_log_file() { echo "${CHECKUP_LOG:-$HOME/.config/vps-setup/checkup.log}"; }

# checkup_sample_append EPOCH SERVER USED_KB TOTAL_KB BACKUPS_KB DUMPS_KB COST -> one TSV line
# (date, epoch, server, used, total, backups, dumps, cost in EUR or -) in the checkup log.
# CHECKUP_RECORD=0 writes nothing.
checkup_sample_append() {
  local f d n
  [ "${CHECKUP_RECORD:-1}" = 0 ] && return 0
  [ "$#" = 7 ] || { echo "usage: checkup_sample_append EPOCH SERVER USED_KB TOTAL_KB BACKUPS_KB DUMPS_KB COST" >&2; return 1; }
  for n in "$1" "$3" "$4" "$5" "$6"; do
    case $n in ''|*[!0-9]*) echo "checkup_sample_append: not a whole number: '$n'" >&2; return 1 ;; esac
  done
  case $2 in ''|*[!A-Za-z0-9.:_-]*) echo "checkup_sample_append: not a server name or address: '$2'" >&2; return 1 ;; esac
  case $7 in -) ;; ''|*[!0-9.]*|*.*.*|.*) echo "checkup_sample_append: not a cost: '$7'" >&2; return 1 ;; esac
  f=$(checkup_log_file)
  d=$(date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F)
  mkdir -p "$(dirname "$f")" || return 1
  ( umask 077; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$@" >> "$f" ) && chmod 600 "$f"
}

# checkup_sample_prev SERVER NOW [MIN_DAYS] -> the newest line of SERVER in the checkup log that is
# at least MIN_DAYS (default 20) days older than NOW (epoch), else its oldest line; 1 when there is
# none.
checkup_sample_prev() {
  local f; f=$(checkup_log_file)
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: checkup_sample_prev SERVER NOW [MIN_DAYS]" >&2; return 1; }
  [ -f "$f" ] || return 1
  awk -F '\t' -v s="$1" -v cut="$(( $2 - ${3:-20} * 86400 ))" '
    $3 == s && $2 ~ /^[0-9]+$/ {
      if ($2 <= cut && (best == "" || $2 + 0 > bt)) { best = $0; bt = $2 + 0 }
      if (old == "" || $2 + 0 < ot) { old = $0; ot = $2 + 0 }
    }
    END { if (best != "") print best; else if (old != "") print old; else exit 1 }' "$f"
}

# server_cost -> what the Hetzner project costs a month, from hcloud (read-only) as TSV: kind,
# name, type, location, monthly gross EUR (servers only; the server type's list price there),
# backups (on/off, +20% when on). Primary IPs and volumes are listed without a price: hcloud has
# none for them. Object Storage and traffic are not in hcloud at all [verify field names].
server_cost() {
  local s ip vol
  s=$(hcloud_json server list) || return 1
  ip=$(hcloud_json primary-ip list) || return 1
  vol=$(hcloud_json volume list) || return 1
  printf 'kind\tname\ttype\tlocation\tmonthly_gross_eur\tbackups\n'
  jq -r '.[]? | (.datacenter.location.name // .location.name // "?") as $loc
    | ([.server_type.prices[]? | select(.location == $loc) | .price_monthly.gross | tonumber] | first) as $p
    | ["server", (.name // "?"), (.server_type.name // "?"), $loc,
       (if $p == null then "?" else ($p * 100 | round / 100 | tostring) end),
       (if .backup_window != null then "on" else "off" end)] | @tsv' <<<"$s"
  jq -r '.[]? | ["primary-ip", (.name // "?"), (.type // "?"), (.datacenter.location.name // .location.name // "?"), "-", "-"] | @tsv' <<<"$ip"
  jq -r '.[]? | ["volume", (.name // "?"), "\(.size // "?") GB", (.location.name // "?"), "-", "-"] | @tsv' <<<"$vol"
}
