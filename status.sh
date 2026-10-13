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

# API calls in this script are quiet: error bodies are not shown.
api() { capi GET "$1" 2>/dev/null; }

# Bounded command (macOS has no `timeout` unless coreutils is installed).
bounded() { if command -v timeout >/dev/null; then timeout 10 "$@"; else "$@"; fi; }

# Epoch seconds of an openssl date ("Jan  1 00:00:00 2027 GMT"): GNU date, then BSD date.
epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f "%b %d %T %Y %Z" "$1" +%s 2>/dev/null; }

# jq: Coolify timestamps ("2026-10-13T02:00:05.000000Z" or "2026-10-13 02:00:05") to epoch.
JQ_EPOCH='def epoch: sub("\\.[0-9]+"; "") | sub(" "; "T") | (if endswith("Z") then . else . + "Z" end) | fromdateiso8601;'

now=$(date +%s)

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
if ! version=$(api /version | tr -d '"') || [ -z "$version" ]; then
  unreachable=1
  line FAIL "api" "Coolify API unreachable or token rejected"
else
  latest=$(curl -fsS --max-time 5 "$STATUS_LATEST_URL" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  latest=${latest#v}
  if [ -z "$latest" ]; then line OK "version" "$version (latest unknown)"
  elif [ "$latest" = "$version" ]; then line OK "version" "$version (latest)"
  else line OK "version" "$version (latest release $latest)"; fi

  # --- Apps ---
  section "Apps"
  if ! apps=$(api /applications | jq -c '.[] | {uuid, name, status: (.status // "unknown"), fqdn: (.fqdn // "")}' 2>/dev/null); then
    line WARN "apps" "n/a (could not list applications)"
  elif [ -z "$apps" ]; then
    line OK "apps" "none"
  else
    while IFS= read -r app; do
      uuid=$(jq -r .uuid <<<"$app"); name=$(jq -r .name <<<"$app"); st=$(jq -r .status <<<"$app")
      # Last deployment: list endpoint may return {deployments:[...]} or a plain array. Logs are never read out.
      dep=$(api "/deployments/applications/$uuid" | jq -r --argjson x 0 "$JQ_EPOCH"'
        (if type == "array" then . else (.deployments // []) end)
        | map(select(.created_at != null)) | sort_by(.created_at | epoch) | last
        | if . == null then "none" else "\(.status // "unknown") \(.created_at[0:10])" end' 2>/dev/null)
      dep=${dep:-n/a}
      mark=OK
      case $st in running*) ;; *) mark=FAIL ;; esac
      case $dep in failed*) mark=FAIL ;; esac
      line "$mark" "app $name" "$st, last deploy: $dep"

      while IFS= read -r url; do
        case $url in https://*) ;; *) continue ;; esac
        host=${url#https://}; host=${host%%/*}; host=${host%%:*}
        [ -n "$host" ] || continue
        end=$(bounded "$STATUS_OPENSSL" s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
          "$STATUS_OPENSSL" x509 -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        if [ -z "$end" ] || ! e=$(epoch_of "$end"); then
          line FAIL "cert $host" "unreachable or no certificate"; continue
        fi
        days=$(( (e - now) / 86400 ))
        if [ "$days" -lt "$CERT_FAIL" ]; then line FAIL "cert $host" "expires in $days days"
        elif [ "$days" -lt "$CERT_WARN" ]; then line WARN "cert $host" "expires in $days days"
        else line OK "cert $host" "$days days left"; fi
      done < <(jq -r .fqdn <<<"$app" | tr ',' '\n')
    done <<<"$apps"
  fi

  # --- Backups ---
  section "Backups"
  if ! dbs=$(api /databases | jq -c '.[] | {uuid, name}' 2>/dev/null); then
    line WARN "databases" "n/a (could not list databases)"
  elif [ -z "$dbs" ]; then
    line OK "databases" "none"
  else
    while IFS= read -r db; do
      uuid=$(jq -r .uuid <<<"$db"); name=$(jq -r .name <<<"$db")
      if ! scheds=$(api "/databases/$uuid/backups"); then
        line WARN "backup $name" "n/a (backup API not available)"; continue
      fi
      ids=$(jq -r '(if type == "array" then . else (.backups // []) end) | .[].uuid // empty' <<<"$scheds" 2>/dev/null)
      if [ -z "$ids" ]; then line FAIL "backup $name" "no backup schedule"; continue; fi
      # Executions of every schedule; fall back to executions embedded in the schedule list.
      execs=$(for id in $ids; do
        api "/databases/$uuid/backups/$id/executions" |
          jq -c '(if type == "array" then . else (.executions // []) end) | .[]' 2>/dev/null
      done)
      [ -n "$execs" ] || execs=$(jq -c '(if type == "array" then . else (.backups // []) end) | .[].executions // [] | .[]' <<<"$scheds" 2>/dev/null)
      last=$(jq -rs --argjson now "$now" "$JQ_EPOCH"'
        map(select(.status != "running" and (.created_at // .updated_at) != null))
        | map(. + {t: ((.finished_at // .created_at // .updated_at) | epoch)}) | sort_by(.t) | last
        | if . == null then "none" else "\(.status) \((($now - .t) / 3600) | floor)" end' <<<"$execs" 2>/dev/null)
      case ${last:-none} in
        none) line FAIL "backup $name" "no backup has run" ;;
        success\ *)
          h=${last#success }
          if [ "$h" -gt "$BACKUP_WARN_H" ]; then line WARN "backup $name" "last success ${h}h ago"
          else line OK "backup $name" "last success ${h}h ago"; fi ;;
        *) line FAIL "backup $name" "last backup ${last% *} (${last##* }h ago)" ;;
      esac
    done <<<"$dbs"
  fi
fi

echo
if [ "$unreachable" = 1 ]; then echo "RESULT: cannot reach the server or the Coolify API"; exit 2; fi
if [ "$attention" = 1 ]; then echo "RESULT: needs attention"; exit 1; fi
echo "RESULT: all OK"
