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

# db_dump DB_UUID -> pg_dump (custom format) of a Coolify Postgres into
# DUMP_DIR/<DB_UUID>/<UTC time>.dump on the server (mode 600); prints "<path> <bytes>".
# Before dumping: prunes to DUMP_KEEP-1 (default 10) older dumps and refuses when the filesystem
# has less than 2 x database size + 1 GiB free. Coolify 4.3 has no API call that runs a database
# backup on demand (only scheduled ones), so this goes through rssh.
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
db_restore() {
  local user db app status wipe=no
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
