#!/usr/bin/env bash
# One-screen health check of the server (updates, reboot), Coolify, apps and services (grouped
# by project and environment), certificates, uptime checks, backups, Postgres major versions and alerts.
# Run from anywhere on YOUR machine: ./status.sh
# Exit code: 0 all OK, 1 something needs attention (WARN or FAIL), 2 server or Coolify API unreachable.
# Read-only: it never changes anything and never prints tokens or deploy logs.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh

# Test seams (defaults are the real thing).
STATUS_SSH=${STATUS_SSH:-rssh}
STATUS_OPENSSL=${STATUS_OPENSSL:-openssl}
STATUS_LATEST_URL=${STATUS_LATEST_URL:-https://api.github.com/repos/coollabsio/coolify/releases/latest}
# Tests only: a base URL the client host of a status page is appended to (<base>/<host>/api/entry-page);
# empty is https://<host>/api/entry-page.
STATUS_ENTRY_URL=${STATUS_ENTRY_URL:-}
# `timeout` (Linux) or `gtimeout` (macOS with coreutils); "none" skips certificate checks.
STATUS_TIMEOUT=${STATUS_TIMEOUT:-$(command -v timeout || command -v gtimeout || echo none)}
export CAPI_MAX_TIME=15   # per Coolify API call, read by capi in lib.sh

DISK_WARN=85 DISK_FAIL=95 CERT_WARN=14 CERT_FAIL=3 BACKUP_WARN_H=26 REBOOT_WARN_D=7 PG_MIN_MAJOR=17

attention=0 unreachable=0
report_colors

# API calls in this script are quiet: error bodies are not shown.
api() { capi GET "$1" 2>/dev/null; }

now=$(date +%s)
certs_skipped=0   # set by certs once the "no timeout command" warning is shown

# offsite NAME S3_SCHEDULE_IDS EXECUTIONS_JSON -> the "off-site" line of one database.
# A run reached S3 when it succeeded and s3_uploaded is true. If the API does not return
# s3_uploaded (4.3.23 was not seen returning it), the message decides instead: Coolify keeps the
# status "success" when only the upload failed and writes "S3 upload failed" into the message.
# The line then says that the upload was not reported and is at most WARN. No schedule at all is
# the backup line's FAIL.
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
  [ "$h" -gt "$BACKUP_WARN_H" ] && m=WARN
  # Without s3_uploaded a run with no upload error is not proof of a copy (runs from before S3
  # was attached look the same), so this is never OK.
  [ "$rep" = message ] && { d="newest run with no upload error ${h}h ago; S3 upload not reported by API, RESTORE.md step 3 proves it"; m=WARN
    [ "$newest" = failed ] && d="$d; newest upload failed"; }
  line "$m" "off-site $1" "$d"
}

# certs FQDNS -> one "cert <host>" line per https:// URL in a comma-separated fqdn list (apps
# and services): days to expiry of the certificate the host serves on 443.
certs() {
  local url host end e days
  # shellcheck disable=SC2016 # $f in the jq filter below is a jq variable
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
  done < <(jq -rn --arg f "$1" '$f | split(",") | .[] | gsub("^\\s+|\\s+$"; "") | select(. != "")')
}

# entry_lines SLUG -> a "page SLUG" line per client domain of the status page (UPTIME_DOMAINS,
# UPTIME.md step 9): Kuma's public /api/entry-page on that host must name the page. Its
# certificate is a "cert" line of the Kuma service already (the host is in the service's fqdn).
entry_lines() {
  local pair host base e t
  for pair in $(state_get UPTIME_DOMAINS); do
    [ "${pair%%=*}" = "$1" ] || continue
    host=${pair#*=}
    cf_valid_name "$host" 2>/dev/null || { line WARN "page $1" "n/a (UPTIME_DOMAINS has '$host', not a host name)"; continue; }
    base=https://$host; [ -z "$STATUS_ENTRY_URL" ] || base=$STATUS_ENTRY_URL/$host
    e=$(curl -fsS --max-time 10 "$base/api/entry-page" 2>/dev/null)
    t=$(jq -r 'if type == "object" and (.type | type) == "string" then "\(.type) \(.statusPageSlug // "")" else empty end' <<<"$e" 2>/dev/null)
    case $t in
      '') line WARN "page $1" "n/a (https://$host does not answer: DNS, certificate or Kuma; UPTIME.md step 9)" ;;
      "statusPageMatchedDomain $1") line OK "page $1" "https://$host serves it" ;;
      "statusPageMatchedDomain "?*) line FAIL "page $1" "https://$host serves status page $(tr -cd 'a-z0-9-' <<<"${t#* }"), not $1 (UPTIME.md step 9)" ;;
      *) line FAIL "page $1" "https://$host answers with Kuma's own entry, not the page (kuma_domain_add $1 $host, UPTIME.md step 9)" ;;
    esac
  done
}

# --- Server: one ssh round-trip ---
section "Server"
srv=$("$STATUS_SSH" 'sh -s' 2>/dev/null <<'EOF'
df -P / | awk 'NR==2 {print "disk", $5+0}'
free -m | awk '/^Mem:/ {print "mem", $3, $2}'
if [ -f /var/run/reboot-required ]; then echo "reboot yes"; echo "reboot_since $(stat -c %Y /var/run/reboot-required)"; else echo "reboot no"; fi
# apt-check (update-notifier-common) prints "<updates>;<security updates>" on stderr.
if [ -x /usr/lib/update-notifier/apt-check ]; then
  /usr/lib/update-notifier/apt-check 2>&1 >/dev/null | awk -F';' 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print "updates", $1, $2}'
else echo "updates none-check"; fi
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
  # Days since /var/run/reboot-required appeared (its mtime), empty when unknown.
  since=$(awk '$1=="reboot_since" && $2 ~ /^[0-9]+$/ {print $2}' <<<"$srv")
  rdays=${since:+$(( (now - since) / 86400 ))}
  case $(awk '$1=="reboot" {print $2}' <<<"$srv") in
    no) line OK "reboot" "not required" ;;
    yes) line WARN "reboot" "required (kernel or library update)${rdays:+, pending $rdays days}" ;;
    *) line WARN "reboot" "n/a" ;;
  esac
  # Ubuntu package updates (UPGRADE.md, Ubuntu): security updates waiting, or a reboot pending
  # more than REBOOT_WARN_D days, is due. unattended-upgrades installs security updates daily.
  read -r _ upd sec <<<"$(awk '$1=="updates"' <<<"$srv")"
  if [ "${upd:-}" = none-check ]; then line OK "updates" "n/a (no apt-check on the server)"
  elif [ -z "${sec:-}" ]; then line WARN "updates" "n/a (could not read)"
  else
    mark=OK d="$upd pending, $sec security"
    [ "$upd" = 0 ] && d="none pending"
    [ "$sec" -gt 0 ] && { mark=WARN; d="$d (security updates not installed yet; UPGRADE.md, Ubuntu)"; }
    [ -n "$rdays" ] && [ "$rdays" -gt "$REBOOT_WARN_D" ] && { mark=WARN; d="$d; reboot pending $rdays days (UPGRADE.md, Ubuntu)"; }
    line "$mark" "updates" "$d"
  fi
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
    line WARN "version" "$version, latest release $latest (minor or major update behind; UPGRADE.md, Coolify)"
  else line OK "version" "$version (latest release $latest)"; fi

  # --- Projects (R09): environment id -> "project / environment", for the group lines of apps
  # and services. Unreadable: one WARN, and apps and services are listed without groups.
  projmap='{}' grouped=0
  if plist=$(api /projects) && jq -e 'arrays' <<<"$plist" >/dev/null 2>&1; then
    grouped=1
    while IFS= read -r pu; do
      [ -n "$pu" ] || continue
      if ! service_valid_uuid "$pu" 2>/dev/null || ! one=$(api "/projects/$pu") ||
         ! projmap=$(printf '%s\n' "$projmap" "$one" | jq -sce '.[0] + ([.[1] | (.name // "?") as $p | .environments[]
             | {key: (.id | tostring), value: "\($p) / \(.name // "?")"}] | from_entries)' 2>/dev/null); then
        grouped=0; projmap='{}'; break
      fi
    done < <(jq -r '.[].uuid // empty' <<<"$plist")
  fi
  [ "$grouped" = 1 ] || line WARN "projects" "n/a (could not read; apps and services listed without their project)"
  # group LABEL -> a group line when LABEL differs from the last one (empty when not grouped)
  last_group=''
  group() {
    [ "$grouped" = 1 ] && [ "$1" != "$last_group" ] || return 0
    last_group=$1
    if [ "$1" = "~" ]; then subsection "(no project)"; else subsection "project $1"; fi
  }
  # shellcheck disable=SC2016 # $m is a jq variable
  JQ_GROUP='(($m[(.environment_id // "none") | tostring]) // "~")'

  # --- Apps ---
  section "Apps"
  if ! apps=$(api /applications | jq -c --argjson m "$projmap" '[.[] | {uuid, name, status: (.status // "unknown"), fqdn: (.fqdn // ""),
      grp: '"$JQ_GROUP"'}] | sort_by((.grp == "~"), .grp, .name) | .[]' 2>/dev/null); then
    line WARN "apps" "n/a (could not read applications)"
  elif [ -z "$apps" ]; then
    line OK "apps" "none"
  else
    while IFS= read -r app; do
      uuid=$(jq -r .uuid <<<"$app"); name=$(jq -r .name <<<"$app"); st=$(jq -r .status <<<"$app")
      group "$(jq -r .grp <<<"$app")"
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

      certs "$(jq -r .fqdn <<<"$app")"
    done <<<"$apps"
  fi

  # --- Services: Coolify one-click services (SERVICES.md) ---
  section "Services"
  # Per service: status, the fqdns of its applications, the applications at the restart limit.
  if ! svcs=$(api /services | jq -c --argjson m "$projmap" 'if type == "array" then . else error("not a list") end
      | [.[] | {name: (.name // "?"), status: (.status // "unknown"),
         fqdn: ([.applications[]? | .fqdn // "" | select(. != "")] | join(",")),
         limit: ([.applications[]? | select(.restart_limit_reached == true) | .name // "?"] | join(", ")),
         grp: '"$JQ_GROUP"'}] | sort_by((.grp == "~"), .grp, .name) | .[]' 2>/dev/null); then
    line WARN "services" "n/a (could not read services)"
  elif [ -z "$svcs" ]; then
    line OK "services" "none"
  else
    last_group=''
    while IFS= read -r svc; do
      name=$(jq -r .name <<<"$svc"); st=$(jq -r .status <<<"$svc")
      group "$(jq -r .grp <<<"$svc")"
      fqdn=$(jq -r .fqdn <<<"$svc"); limit=$(jq -r .limit <<<"$svc")
      # running:unknown is a template without a health check, as for apps.
      case $st in
        running:unhealthy|degraded*) mark=WARN ;;
        running*) mark=OK ;;
        starting*|restarting*) mark=WARN ;;
        *) mark=FAIL ;;
      esac
      d=$st
      [ -n "$fqdn" ] && d="$d, ${fqdn//,/, }"
      [ -n "$limit" ] && { mark=FAIL; d="$d, restart limit reached: $limit"; }
      line "$mark" "service $name" "$d"
      certs "$fqdn"
    done <<<"$svcs"
  fi

  # --- Uptime: the Kuma status pages of UPTIME.md (UPTIME_PAGES), from their public JSON, no login ---
  section "Uptime"
  pages=$(state_get UPTIME_PAGES)
  if [ -z "$pages" ]; then
    line OK "uptime" "none (UPTIME.md)"
  else
    npages=$(wc -w <<<"$pages")
    for slug in $pages; do
      [ "$npages" -gt 1 ] && subsection "status page $slug"
      up=$(kuma_status "$slug" 2>/dev/null); urc=$?
      if [ "$urc" = 2 ] || [ -z "$up" ]; then
        line WARN "uptime $slug" "n/a (could not read $(state_get UPTIME_URL)/status/$slug)"; entry_lines "$slug"; continue
      fi
      if [ "$(wc -l <<<"$up")" -lt 2 ]; then
        line WARN "uptime $slug" "no monitors on the page (kuma_sync, UPTIME.md step 5)"; entry_lines "$slug"; continue
      fi
      # Kuma 2.5.6 sends no message in the public heartbeats ("-"); the reason is on the monitor's page in Kuma.
      while IFS=$'\t' read -r mon ust u24 since _ msg; do
        why=''; [ "$msg" = - ] || why=": $msg"
        case $ust in
          up) line OK "uptime $mon" "up, 24h $u24" ;;
          down) line FAIL "uptime $mon" "down since $since$why" ;;
          pending) line WARN "uptime $mon" "pending since $since$why" ;;
          maintenance) line OK "uptime $mon" "in maintenance, 24h $u24" ;;
          *) line WARN "uptime $mon" "no check yet" ;;
        esac
      done < <(tail -n +2 <<<"$up")
      entry_lines "$slug"
    done
  fi

  # --- Backups ---
  section "Backups"
  if ! dbs=$(api /databases | jq -c '.[] | {uuid, name, image: (.image // ""), type: (.database_type // "")}' 2>/dev/null); then
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

    # --- Postgres major versions (UPGRADE.md, Postgres); other databases are skipped ---
    section "Postgres"
    pgs=0
    while IFS= read -r db; do
      name=$(jq -r .name <<<"$db"); img=$(jq -r .image <<<"$db"); type=$(jq -r .type <<<"$db")
      case $type in
        standalone-postgresql) ;;
        '') case ${img##*/} in postgres:*|postgres) ;; *) continue ;; esac ;;
        *) continue ;;
      esac
      pgs=1
      if ! major=$(pg_image_major "$img" 2>/dev/null); then line WARN "postgres $name" "n/a (no major version in image '${img:-none}')"
      elif [ "$major" -lt "$PG_MIN_MAJOR" ]; then line WARN "postgres $name" "$major ($img), major upgrade due (UPGRADE.md, Postgres)"
      else line OK "postgres $name" "$major ($img)"; fi
    done <<<"$dbs"
    [ "$pgs" = 1 ] || line OK "postgres" "none"
  fi

  # --- Alerts: Coolify notification channels of the token's team (NOTIFY_EVENTS from lib.sh) ---
  section "Alerts"
  full='' partial='' readable=0
  for ch in $NOTIFY_CHANNELS; do
    # "on <events off>" or "off"; email has no email_enabled, its senders are smtp/resend [verify].
    r=$(api "/notifications/$ch" | jq -er --arg ch "$ch" --arg ev "$NOTIFY_EVENTS" '
      objects | . as $o
      | if ($o["\($ch)_enabled"] // ($ch == "email" and ($o.smtp_enabled == true or $o.resend_enabled == true))) == true
        then "on " + ([$ev | split(" ")[] | select($o["\(.)_\($ch)_notifications"] != true)] | join(" "))
        else "off" end' 2>/dev/null) || continue
    readable=1
    case $r in
      "on ") full="$full${full:+, }$ch" ;;
      on\ *) partial="$partial${partial:+; }$ch on but ${r#on } off" ;;
    esac
  done
  if [ -n "$full" ]; then line OK "alerts" "$full: on, alert events on (delivery not checked)"
  elif [ -n "$partial" ]; then line WARN "alerts" "$partial"
  elif [ "$readable" = 1 ]; then line WARN "alerts" "none (no notification channel enabled; phase 06 step 2)"
  else line WARN "alerts" "n/a (could not read)"; fi
fi

echo
if [ "$unreachable" = 1 ]; then echo "RESULT: cannot reach the server or the Coolify API"; exit 2; fi
if [ "$attention" = 1 ]; then echo "RESULT: needs attention"; exit 1; fi
echo "RESULT: all OK"
