#!/usr/bin/env bash
# One-screen health check of the server, Coolify, apps, certificates and backups.
# Run from anywhere on YOUR machine: ./status.sh
# Exit code: 0 all OK, 1 something needs attention (WARN or FAIL), 2 server or Coolify API unreachable.
# Read-only: it never changes anything and never prints tokens or deploy logs.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh

# Test seams (defaults are the real thing).
STATUS_SSH=${STATUS_SSH:-rssh}
STATUS_OPENSSL=${STATUS_OPENSSL:-openssl}
STATUS_LATEST_URL=${STATUS_LATEST_URL:-https://api.github.com/repos/coollabsio/coolify/releases/latest}
# `timeout` (Linux) or `gtimeout` (macOS with coreutils); "none" skips certificate checks.
STATUS_TIMEOUT=${STATUS_TIMEOUT:-$(command -v timeout || command -v gtimeout || echo none)}
export CAPI_MAX_TIME=15   # per Coolify API call, read by capi in lib.sh

DISK_WARN=85 DISK_FAIL=95 CERT_WARN=14 CERT_FAIL=3 BACKUP_WARN_H=26

attention=0 unreachable=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m' C_END=$'\033[0m'
else
  C_OK='' C_WARN='' C_FAIL='' C_END=''
fi

# line MARK label detail  (MARK: OK, WARN, FAIL). API-provided text is stripped of control chars.
line() {
  local c
  case $1 in OK) c=$C_OK ;; WARN) c=$C_WARN; attention=1 ;; *) c=$C_FAIL; attention=1 ;; esac
  printf '%s%-5s%s %-28s %s\n' "$c" "$1" "$C_END" "$(tr -d '[:cntrl:]' <<<"$2")" "$(tr -d '[:cntrl:]' <<<"$3")"
}
section() { printf '\n%s\n' "$1"; }
# worst MARK MARK -> the more serious of the two
worst() { case "$1 $2" in *FAIL*) echo FAIL ;; *WARN*) echo WARN ;; *) echo OK ;; esac; }

# API calls in this script are quiet: error bodies are not shown.
api() { capi GET "$1" 2>/dev/null; }

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

now=$(date +%s)

# offsite NAME S3_SCHEDULE_IDS EXECUTIONS_JSON -> the "off-site" line of one database.
# A run reached S3 when it succeeded and s3_uploaded is true. If the API does not return
# s3_uploaded (4.3.23 was not seen returning it), the message decides instead: Coolify keeps the
# status "success" when only the upload failed and writes "S3 upload failed" into the message.
# The line then says that the upload was not reported. No schedule at all is the backup line's FAIL.
offsite() {
  local r h rep newest d m=OK
  if [ -z "$2" ]; then line WARN "off-site $1" "local only (no backup schedule copies to S3)"; return; fi
  if ! r=$(jq -er --argjson now "$now" "$JQ_EPOCH"'
      map(select(.status == "success")
        | . + {t: ((.finished_at // .created_at) | epoch), rep: has("s3_uploaded"),
               up: (if has("s3_uploaded") then .s3_uploaded == true
                    else ((.message // "") | test("S3 upload failed") | not) end)})
      | sort_by(.t) as $a | ($a | map(select(.up)) | last) as $c
      | (if ($a | last) == null or ($a | last).up then "ok" else "failed" end) as $n
      | if $c == null then "none \($n)"
        else "\((($now - $c.t) / 3600) | floor) \($n) \(if $c.rep then "reported" else "message" end)" end' <<<"$3" 2>/dev/null); then
    line WARN "off-site $1" "n/a (could not read)"; return
  fi
  read -r h newest rep <<<"$r"
  if [ "$h" = none ]; then
    line FAIL "off-site $1" "no backup has reached S3$([ "$newest" = failed ] && echo "; newest upload failed")"; return
  fi
  d="last S3 copy ${h}h ago"
  [ "$newest" = failed ] && { d="$d; newest upload failed"; m=WARN; }
  [ "$rep" = message ] && d="$d (upload not reported by API, from message)"
  [ "$h" -gt "$BACKUP_WARN_H" ] && m=WARN
  line "$m" "off-site $1" "$d"
}

# --- Server: one ssh round-trip ---
section "Server"
srv=$("$STATUS_SSH" 'sh -s' 2>/dev/null <<'EOF'
df -P / | awk 'NR==2 {print "disk", $5+0}'
free -m | awk '/^Mem:/ {print "mem", $3, $2}'
if [ -f /var/run/reboot-required ]; then echo "reboot yes"; else echo "reboot no"; fi
EOF
); rc=$?
if [ "$rc" -ne 0 ] || [ -z "$srv" ]; then
  unreachable=1
  line FAIL "ssh" "server unreachable (exit $rc)"
else
  line OK "ssh" "reachable"
  disk=$(awk '$1=="disk" {print $2}' <<<"$srv")
  if [ -z "$disk" ]; then line WARN "disk /" "n/a"
  elif [ "$disk" -gt "$DISK_FAIL" ]; then line FAIL "disk /" "${disk}% used"
  elif [ "$disk" -gt "$DISK_WARN" ]; then line WARN "disk /" "${disk}% used"
  else line OK "disk /" "${disk}% used"; fi
  mem=$(awk '$1=="mem" {print $2 " / " $3 " MB used"}' <<<"$srv")
  line OK "memory" "${mem:-n/a}"
  case $(awk '$1=="reboot" {print $2}' <<<"$srv") in
    no) line OK "reboot" "not required" ;;
    yes) line WARN "reboot" "required (kernel or library update)" ;;
    *) line WARN "reboot" "n/a" ;;
  esac
fi

# --- Coolify ---
section "Coolify"
# capi prints the body on success and only an error message on failure (never the token).
out=$(capi GET /version 2>&1); rc=$?
version=$(tr -d '"' <<<"$out")
if [ "$rc" -ne 0 ] || [ -z "$version" ]; then
  unreachable=1
  case $out in
    "Coolify config missing"*) line FAIL "api" "Coolify config missing ($COOLIFY_CONFIG)" ;;
    "HTTP 401"*|"HTTP 403"*) line FAIL "api" "API token rejected (HTTP ${out:5:3})" ;;
    "HTTP "*) line FAIL "api" "API error (HTTP ${out:5:3})" ;;
    *) line FAIL "api" "Coolify API unreachable (timeout or connection refused)" ;;
  esac
else
  latest=$(curl -fsS --max-time 5 "$STATUS_LATEST_URL" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  latest=${latest#v}
  read -r i1 i2 _ <<<"$(semver "$version")"; read -r l1 l2 _ <<<"$(semver "$latest")"
  if [ -z "$latest" ]; then line OK "version" "$version (latest unknown)"
  elif [ "$latest" = "$version" ]; then line OK "version" "$version (latest)"
  elif [ -n "${i2:-}" ] && [ -n "${l2:-}" ] && { [ "$l1" -gt "$i1" ] || { [ "$l1" -eq "$i1" ] && [ "$l2" -gt "$i2" ]; }; }; then
    line WARN "version" "$version, latest release $latest (minor or major update behind)"
  else line OK "version" "$version (latest release $latest)"; fi

  # --- Apps ---
  section "Apps"
  certs_skipped=0
  if ! apps=$(api /applications | jq -c '.[] | {uuid, name, status: (.status // "unknown"), fqdn: (.fqdn // "")}' 2>/dev/null); then
    line WARN "apps" "n/a (could not read applications)"
  elif [ -z "$apps" ]; then
    line OK "apps" "none"
  else
    while IFS= read -r app; do
      uuid=$(jq -r .uuid <<<"$app"); name=$(jq -r .name <<<"$app"); st=$(jq -r .status <<<"$app")
      case $st in
        running:unhealthy) mark=WARN ;;
        running*) mark=OK ;;
        *) mark=FAIL ;;
      esac
      # Newest deployment comes first ({count, deployments:[...]}); logs are never read out.
      dep=$(api "/deployments/applications/$uuid" |
        jq -er '(if type == "array" then . else .deployments end) | arrays | .[0]
          | if . == null then "none" else "\(.status // "unknown") \((.created_at // "")[0:10])" end' 2>/dev/null)
      case ${dep:-} in
        none|finished\ *|in_progress\ *|queued\ *) ;;
        cancelled*) mark=$(worst "$mark" WARN) ;;
        failed\ *|error\ *) mark=FAIL ;;
        '') dep="n/a (could not read)"; mark=$(worst "$mark" WARN) ;;
        *) mark=$(worst "$mark" WARN) ;;
      esac
      line "$mark" "app $name" "$st, last deploy: $dep"

      while IFS= read -r url; do
        case $url in https://*) ;; *) continue ;; esac
        host=${url#https://}; host=${host%%/*}
        case $host in
          \[*) line OK "cert $host" "n/a (IPv6 address)"; continue ;;
          *) host=${host%%:*} ;;
        esac
        [ -n "$host" ] || continue
        if [ "$STATUS_TIMEOUT" = none ]; then
          [ "$certs_skipped" = 1 ] || line WARN "cert checks" "skipped: no timeout command (brew install coreutils)"
          certs_skipped=1; continue
        fi
        end=$("$STATUS_TIMEOUT" 10 "$STATUS_OPENSSL" s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
          "$STATUS_OPENSSL" x509 -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        if [ -z "$end" ] || ! e=$(epoch_of "$end"); then
          line FAIL "cert $host" "unreachable or no certificate"; continue
        fi
        days=$(( (e - now) / 86400 ))
        if [ "$days" -lt "$CERT_FAIL" ]; then line FAIL "cert $host" "expires in $days days"
        elif [ "$days" -lt "$CERT_WARN" ]; then line WARN "cert $host" "expires in $days days"
        else line OK "cert $host" "$days days left"; fi
      done < <(jq -r '.fqdn | split(",") | .[] | gsub("^\\s+|\\s+$"; "") | select(. != "")' <<<"$app")
    done <<<"$apps"
  fi

  # --- Backups ---
  section "Backups"
  if ! dbs=$(api /databases | jq -c '.[] | {uuid, name}' 2>/dev/null); then
    line WARN "databases" "n/a (could not read databases)"
  elif [ -z "$dbs" ]; then
    line OK "databases" "none"
  else
    while IFS= read -r db; do
      uuid=$(jq -r .uuid <<<"$db"); name=$(jq -r .name <<<"$db")
      # Schedules: an array of {uuid, enabled, frequency, executions:[...]}.
      if ! scheds=$(api "/databases/$uuid/backups") ||
         ! ids=$(jq -er 'arrays | map(.uuid | strings) | join(" ")' <<<"$scheds" 2>/dev/null); then
        line WARN "backup $name" "n/a (could not read)"; continue
      fi
      if [ -z "$ids" ]; then line FAIL "backup $name" "none (no backup schedule)"; continue; fi
      # Schedules that also copy to S3 (save_s3), for the off-site line.
      s3ids=$(jq -r 'map(select(.save_s3 == true) | .uuid | strings) | join(" ")' <<<"$scheds")
      # Executions per schedule ({executions:[...]}); the copy embedded in the schedule as fallback.
      all='[]' s3all='[]' readfail=0
      for id in $ids; do
        if ! ex=$(api "/databases/$uuid/backups/$id/executions" | jq -ce '.executions | arrays' 2>/dev/null) &&
           ! ex=$(jq -ce --arg id "$id" '.[] | select(.uuid == $id) | .executions | arrays' <<<"$scheds" 2>/dev/null); then
          readfail=1; break
        fi
        all=$(jq -c --argjson a "$ex" '. + $a' <<<"$all")
        case " $s3ids " in *" $id "*) s3all=$(jq -c --argjson a "$ex" '. + $a' <<<"$s3all") ;; esac
      done
      # finished_at is null on real executions, so created_at is the time of the run.
      if [ "$readfail" = 1 ] || ! last=$(jq -er --argjson now "$now" "$JQ_EPOCH"'
          map(select(.status != "running")) | map(. + {t: ((.finished_at // .created_at) | epoch)})
          | sort_by(.t) | last
          | if . == null then "none" else "\(.status) \((($now - .t) / 3600) | floor)" end' <<<"$all" 2>/dev/null); then
        line WARN "backup $name" "n/a (could not read)"; continue
      fi
      case $last in
        none) line FAIL "backup $name" "none (no backup has run)" ;;
        success\ *)
          h=${last#success }
          if [ "$h" -gt "$BACKUP_WARN_H" ]; then line WARN "backup $name" "last success ${h}h ago"
          else line OK "backup $name" "last success ${h}h ago"; fi ;;
        *) line FAIL "backup $name" "last backup ${last% *} (${last##* }h ago)" ;;
      esac
      offsite "$name" "$s3ids" "$s3all"
    done <<<"$dbs"
  fi
fi

echo
if [ "$unreachable" = 1 ]; then echo "RESULT: cannot reach the server or the Coolify API"; exit 2; fi
if [ "$attention" = 1 ]; then echo "RESULT: needs attention"; exit 1; fi
echo "RESULT: all OK"
