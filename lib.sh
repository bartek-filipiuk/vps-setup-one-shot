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

# db_fetch_from_s3 DB_UUID EXEC_FILENAME -> downloads one backup (the execution's filename, as
# db_backup_list prints it) from the S3 storage in S3_STORAGE_UUID onto the server, into
# DUMP_DIR/<DB_UUID>/s3-<basename> (mode 600); prints "<path> <bytes>". Then: db_restore with
# that path. Runs mc in a throwaway container; the credentials go over the ssh stdin into an env
# file (mode 600, deleted on exit), never on a command line.
db_fetch_from_s3() {
  local db=${1:-} file=${2:-} s3 info endpoint bucket obj base mchost
  [ -n "$db" ] && [ -n "$file" ] || { echo "usage: db_fetch_from_s3 DB_UUID EXEC_FILENAME" >&2; return 1; }
  s3=$(state_get S3_STORAGE_UUID)
  [ -n "$s3" ] || { echo "db_fetch_from_s3: no S3_STORAGE_UUID in $VPS_STATE (phase 06 step 1)" >&2; return 1; }
  s3_env_check || return 1
  info=$(capi GET "/s3-storages/$s3") || return 1
  endpoint=$(jq -r '.endpoint // empty' <<<"$info"); bucket=$(jq -r '.bucket // empty' <<<"$info")
  [ -n "$endpoint" ] && [ -n "$bucket" ] || { echo "S3 storage $s3 has no endpoint or bucket" >&2; return 1; }
  # Coolify uploads to <bucket>/<filename without the leading slash>.
  obj=${file#/}; base=${obj##*/}
  case "$base" in ''|.|..) echo "not a backup file name: $file" >&2; return 1 ;; esac
  # MC_HOST_<alias>=https://KEY:SECRET@host; key and secret percent-encoded [verify].
  mchost=$(S3_K=$(s3_cred S3_KEY) S3_S=$(s3_cred S3_SECRET) jq -nr --arg e "$endpoint" \
    '($e | capture("^(?<s>https?://)?(?<h>.*?)/*$")) as $m
     | "\($m.s // "https://")\(env.S3_K | @uri):\(env.S3_S | @uri)@\($m.h)"') || return 1
  {
    cat <<'EOF'
set -eu; umask 077
envf=$(mktemp); trap 'rm -f "$envf"' EXIT
cat > "$envf" <<'CREDS'
EOF
    printf 'MC_HOST_s3=%s\nCREDS\n' "$mchost"
    cat <<'EOF'
dir=$4/$1; mkdir -p "$dir"; chmod 700 "$4" "$dir"
f=$dir/s3-$3
img=${5:-}
if [ -z "$img" ]; then
  img=$(docker images --format '{{.Repository}}:{{.Tag}}' ghcr.io/coollabsio/coolify-helper | grep -E ':[0-9]' | sort -V | tail -n 1)
  [ -n "$img" ] || { echo "no coolify-helper image on the server; set MC_IMAGE" >&2; exit 1; }
fi
if docker run --rm --env-file "$envf" -v "$dir:/out" --entrypoint mc "$img" --quiet cp "s3/$2" "/out/s3-$3" >/dev/null && [ -s "$f" ]; then
  chmod 600 "$f"; echo "$f $(stat -c %s "$f")"
else
  rm -f "$f"; echo "download of s3/$2 failed" >&2; exit 1
fi
EOF
  } | rssh "sh -s -- $(printf %q "$db") $(printf %q "$bucket/$obj") $(printf %q "$base") $(printf %q "$DUMP_DIR") $(printf %q "${MC_IMAGE:-}")"
}
