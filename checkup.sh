#!/usr/bin/env bash
# Monthly checkup (CHECKUP.md): everything status.sh checks, plus what changes slowly: open ports
# against the cloud firewall, the SSH daemon, Docker exposure, Coolify security advisories, the
# backup success rate of the last 30 days, disk growth since the last checkup and the monthly
# cost. Ends with the actions, each with its runbook.
# Run from anywhere on YOUR machine: ./checkup.sh
# Exit code: 0 all OK, 1 something needs attention (WARN or FAIL), 2 server or Coolify API unreachable.
# Read-only on the server, in Coolify and at Hetzner (hcloud list and describe only). The one
# write is a line on this machine in the checkup log (~/.config/vps-setup/checkup.log, mode 600,
# no secrets; CHECKUP_RECORD=0 skips it). Never prints tokens.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh

# Test seams (defaults are the real thing): CHECKUP_SSH (in lib.sh), CHECKUP_LOG, CHECKUP_RECORD,
# ADVISORIES_URL, CHECKUP_PROBE_TIMEOUT; status.sh's STATUS_* pass through to it.
CHECKUP_PROBE_TIMEOUT=${CHECKUP_PROBE_TIMEOUT:-5}
export CAPI_MAX_TIME=15   # per Coolify API call, read by capi in lib.sh

DISK_TARGET=85 BACKUP_DAYS=30 BACKUP_FAIL_PCT=50 GROWTH_FAIL_M=1 GROWTH_WARN_M=3

attention=0 unreachable=0 acts=()
report_colors
now=$(date +%s)
# The checkup is about the server: always the global setup state, also with VPS_STATE set.
sget() { VPS_STATE=$VPS_SETUP_STATE state_get "$1"; }
ip=$(sget VPS_IP); provider=$(sget PROVIDER); server_name=$(sget SERVER_NAME)
ports_ok=$(sget CHECKUP_PORTS_OK); seen_ok=$(sget CHECKUP_ADVISORIES_SEEN)

# cline MARK LABEL DETAIL -> line, and WARN/FAIL kept for the Actions list.
cline() {
  line "$@"
  [ "$1" = OK ] || acts+=("$(printf '%-5s %-28s %s' "$1" "$(tr -d '[:cntrl:]' <<<"$2")" "$(tr -d '[:cntrl:]' <<<"$3")")")
}

# action_for LINE -> the runbook for a WARN or FAIL line (status.sh's or this script's).
action_for() {
  local _m w1 w2
  read -r _m w1 w2 _ <<<"$1"
  case $w1 in
    ssh|api|server) echo "DOCTOR.md E" ;;
    disk) [ "$w2" = growth ] && echo "CHECKUP.md 3f" || echo "DOCTOR.md C" ;;
    reboot|updates) echo "UPGRADE.md B" ;;
    version) echo "UPGRADE.md A" ;;
    app|apps) echo "DOCTOR.md" ;;
    cert) echo "DOCTOR.md D" ;;
    service|services) echo "SERVICES.md" ;;
    backup) [ "$w2" = rate ] && echo "CHECKUP.md 3e" || echo "phases/06-handover.md step 1" ;;
    off-site|databases) echo "phases/06-handover.md step 1" ;;
    postgres) echo "UPGRADE.md C" ;;
    alerts) echo "phases/06-handover.md step 2" ;;
    firewall|listening) echo "CHECKUP.md 3a" ;;
    sshd|root) echo "CHECKUP.md 3b" ;;
    docker) echo "CHECKUP.md 3c" ;;
    advisory|advisories) echo "CHECKUP.md 3d" ;;
    cost) echo "CHECKUP.md 3g" ;;
    *) echo "CHECKUP.md 3" ;;
  esac
}

# kB -> "12.1 GB"
gb() { awk -v k="$1" 'BEGIN { printf "%.1f GB", k / 1048576 }'; }

# probe PORT -> open, closed or unknown, from this machine to the server's public IP. curl's
# time_connect is 0 unless the TCP connection was made, so a silent open port counts as open.
probe() {
  local t rc
  t=$(curl -s -o /dev/null --connect-timeout "$CHECKUP_PROBE_TIMEOUT" --max-time $((CHECKUP_PROBE_TIMEOUT + 3)) \
    -w '%{time_connect}' "http://$ip:$1/" 2>/dev/null); rc=$?
  [ "$rc" = 7 ] && { echo closed; return; }
  if [ "$(awk -v t="${t:-0}" 'BEGIN { print (t + 0 > 0) ? 1 : 0 }')" = 1 ]; then echo open; return; fi
  case $rc in 28) echo closed ;; 0) echo open ;; *) echo unknown ;; esac
}

# --- status.sh as it is, without its RESULT line ---
echo "Monthly checkup, $(date -u +%F): status.sh first, then the monthly checks"
st_out=$(./status.sh 2>&1); st_rc=$?
st_body=$(sed '/^RESULT: /d' <<<"$st_out"); printf '%s\n' "$st_body"
case $st_rc in 0) ;; 1) attention=1 ;; *) attention=1; unreachable=1 ;; esac
while IFS= read -r l; do acts+=("$l"); done < <(grep -E '^(WARN|FAIL) ' <<<"$st_out")

# --- Server facts: one ssh round trip ---
facts=$(checkup_server_facts 2>/dev/null)
have_facts=0; grep -qx 'facts done' <<<"$facts" && have_facts=1

# --- Ports and firewall ---
section "Ports and firewall"
if [ "$provider" != hetzner ]; then
  cline OK "firewall" "n/a (no cloud firewall API for this provider; it must let in only 22, 80 and 443: CHECKUP.md 3a)"
elif ! rules=$(firewall_rules "$FIREWALL_NAME" 2>&1); then
  cline WARN "firewall" "n/a ($(head -n 1 <<<"$rules"))"
else
  allowed=" $FIREWALL_EXPECT $ports_ok " seen=' ' extra='' missing=''
  while IFS=$'\t' read -r dir proto port src; do
    [ "$dir" = in ] || continue
    k=$proto; [ "$port" = - ] || k="$proto/$port"
    seen="$seen$k "
    case $allowed in *" $k "*) ;; *) extra="$extra${extra:+, }$k from $src" ;; esac
  done < <(tail -n +2 <<<"$rules")
  for k in $FIREWALL_EXPECT; do case $seen in *" $k "*) ;; *) missing="$missing${missing:+ }$k" ;; esac; done
  mark=OK d="$FIREWALL_NAME: in $FIREWALL_EXPECT${ports_ok:+ $ports_ok} only"
  if err=$(firewall_applied "$FIREWALL_NAME" "$server_name" 2>&1); then d="$d, applied to $server_name"
  elif [ -n "$err" ]; then mark=WARN; d="$d; applied to $server_name: n/a ($(head -n 1 <<<"$err"))"
  else mark=FAIL; d="$d; NOT applied to $server_name"; fi
  [ -n "$missing" ] && { mark=$(worst "$mark" WARN); d="$d; missing $missing"; }
  [ -n "$extra" ] && { mark=FAIL; d="$d; extra inbound rules: $extra"; }
  cline "$mark" "firewall" "$d"
fi

if [ "$have_facts" = 0 ]; then
  cline WARN "listening" "n/a (could not read the server; see ssh above)"
else
  # Public TCP listeners outside the firewall's ports; loopback and private addresses skipped.
  open='' closed='' unknown='' udp=''
  while read -r port proc; do
    case " $FIREWALL_EXPECT $ports_ok " in *" tcp/$port "*) continue ;; esac
    case $(probe "$port") in
      open) open="$open${open:+, }$port ($proc)" ;;
      closed) closed="$closed${closed:+, }$port ($proc)" ;;
      *) unknown="$unknown${unknown:+, }$port ($proc)" ;;
    esac
  done < <(awk '$1 == "listen" && $2 == "tcp" { a = $3; p = a; sub(/.*:/, "", p); h = substr(a, 1, length(a) - length(p) - 1)
      if (h ~ /^(127\.|\[::1\]|::1|\[fe80|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ || h ~ /%lo$/) next
      print p, $4 }' <<<"$facts" | sort -un -k1,1)
  while read -r port proc; do udp="$udp${udp:+, }$port ($proc)"; done < <(awk '$1 == "listen" && $2 == "udp" { a = $3; p = a; sub(/.*:/, "", p)
      h = substr(a, 1, length(a) - length(p) - 1)
      if (h ~ /^(127\.|\[::1\]|::1|\[fe80|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ || h ~ /%lo$/) next
      print p, $4 }' <<<"$facts" | sort -un -k1,1)
  u=${udp:+; UDP not probed: $udp}
  if [ -n "$open" ]; then cline FAIL "listening" "reachable from the internet: $open$u"
  elif [ -n "$unknown" ]; then cline WARN "listening" "could not probe $unknown from here (check your own network)$u"
  elif [ -n "$closed" ]; then cline OK "listening" "$closed on the server, closed from the internet$u"
  else cline OK "listening" "nothing public beyond the firewall's ports$u"; fi
fi

# --- SSH daemon (phase 02 step 3) ---
section "SSH daemon"
if [ "$have_facts" = 0 ]; then
  cline WARN "sshd" "n/a (could not read the server)"
elif ! grep -q '^sshd ' <<<"$facts"; then
  cline WARN "sshd" "n/a (sshd -T printed nothing)"
else
  bad=''
  for kv in $SSHD_EXPECT; do
    k=${kv%%=*} want=${kv#*=}
    got=$(awk -v k="$k" '$1 == "sshd" && $2 == k { print $3; exit }' <<<"$facts")
    [ "$got" = "$want" ] || bad="$bad${bad:+, }$k ${got:-not set} (want $want)"
  done
  if [ -n "$bad" ]; then cline FAIL "sshd" "$bad"
  else cline OK "sshd" "password login off, root by key only"; fi
  keys=$(awk '$1 == "authkey" { printf "%s%s %s", (n++ ? ", " : ""), $4, $3 }' <<<"$facts" | tr -d '()')
  n=$(grep -c '^authkey ' <<<"$facts")
  if [ "$n" = 0 ]; then cline WARN "root keys" "n/a (no key readable in /root/.ssh/authorized_keys)"
  else cline OK "root keys" "$n in /root/.ssh/authorized_keys: $keys (each one should be in SERVER.md)"; fi
fi

# --- Docker ---
section "Docker"
if [ "$have_facts" = 0 ]; then
  cline WARN "docker" "n/a (could not read the server)"
else
  tcp=$(awk '$1 == "dockerd_tcp" { print $2 }' <<<"$facts" | paste -sd ' ' -)
  hosts=$(awk '$1 == "dockerd_hosts" && /tcp:\/\// { $1 = ""; print }' <<<"$facts")
  lport=$(awk '$1 == "listen" && $2 == "tcp" && $3 ~ /:237[56]$/ { print $3 }' <<<"$facts" | paste -sd ' ' -)
  if [ -n "$tcp$hosts$lport" ]; then
    cline FAIL "docker api" "the Docker API is on TCP (${tcp:+dockerd $tcp}${hosts:+ daemon.json$hosts}${lport:+ listening $lport}): whoever reaches it is root"
  else cline OK "docker api" "unix socket only"; fi
  if ! grep -q '^cont ' <<<"$facts"; then
    cline WARN "docker socket" "n/a (no containers listed)"
  else
    foreign='' own='' priv=''
    while read -r _ name image privileged sock; do
      okc=0
      case " $DOCKER_SOCK_OK " in *" $name "*) okc=1 ;; esac
      for p in $DOCKER_SOCK_OK_IMAGES; do case $image in "$p"|"$p":*|"$p"@*) okc=1 ;; esac; done
      if [ -n "$sock" ]; then
        if [ "$okc" = 1 ]; then own="$own${own:+, }$name"
        else foreign="$foreign${foreign:+, }$name ($image, ${sock#sock:})"; fi
      fi
      [ "$privileged" = true ] && [ "$okc" = 0 ] && priv="$priv${priv:+, }$name ($image)"
    done < <(grep '^cont ' <<<"$facts")
    if [ -n "$foreign" ]; then cline FAIL "docker socket" "mounted by $foreign: each of them controls the server"
    else cline OK "docker socket" "only Coolify's own containers${own:+ ($own)}"; fi
    if [ -n "$priv" ]; then cline WARN "docker privileged" "$priv"
    else cline OK "docker privileged" "none outside Coolify"; fi
  fi
fi

# --- Coolify security advisories (GitHub) ---
section "Coolify advisories"
version=$(capi GET /version 2>/dev/null | tr -d '"')
if [ -z "$version" ]; then
  cline WARN "advisories" "n/a (Coolify API unreachable)"
else
  adv=$(coolify_advisories "$version" 2>&1); arc=$?
  if [ "$arc" != 0 ]; then
    cline WARN "advisories" "n/a ($(head -n 1 <<<"$adv"); run again in an hour)"
  else
    total=0 hit=0 seen=0
    while IFS=$'\t' read -r id sev _pub range patched affected; do
      total=$((total + 1))
      case $affected in
        yes) hit=1; cline FAIL "advisory $id" "$sev, affects $version ($range); fixed in $patched" ;;
        unknown)
          case " $seen_ok " in
            *" $id "*) seen=$((seen + 1)) ;;
            *) hit=1; cline WARN "advisory $id" "$sev, no version range to compare with $version; read it on GitHub" ;;
          esac ;;
      esac
    done < <(tail -n +2 <<<"$adv")
    [ "$hit" = 1 ] ||
      cline OK "advisories" "none of $total published advisories affects $version$([ "$seen" -gt 0 ] && echo " ($seen without a version range read and marked seen)")"
  fi
fi

# --- Backup success rate ---
section "Backups, last $BACKUP_DAYS days"
if ! dbs=$(capi GET /databases 2>/dev/null | jq -r '.[] | [.uuid, (.name // .uuid)] | @tsv' 2>/dev/null); then
  cline WARN "backup rate" "n/a (could not read databases)"
elif [ -z "$dbs" ]; then
  cline OK "backup rate" "no databases"
else
  while IFS=$'\t' read -r uuid name; do
    if ! r=$(backup_success_rate "$uuid" "$BACKUP_DAYS" 2>/dev/null); then
      cline WARN "backup rate $name" "n/a (could not read)"; continue
    fi
    # No schedule: status.sh's backup line already says FAIL for it.
    [ "$(wc -l <<<"$r")" -gt 1 ] || continue
    read -r runs ok failed s3 up s3f unrep newest <<<"$(tail -n +2 <<<"$r" | awk -F '\t' '
      { r += $3; o += $4; f += $5; if ($6 == "yes") s = 1; u += $7; sf += $8; un += $9; if ($10 != "-" && $10 > n) n = $10 }
      END { print r + 0, o + 0, f + 0, s + 0, u + 0, sf + 0, un + 0, (n == "" ? "-" : n) }')"
    if [ "$runs" = 0 ]; then cline FAIL "backup rate $name" "no backup run in the last $BACKUP_DAYS days"; continue; fi
    d="$ok/$runs runs succeeded"
    if [ "$s3" = 1 ]; then
      d="$d; S3: $up uploaded"
      [ "$s3f" -gt 0 ] && d="$d, $s3f upload failed"
      [ "$unrep" -gt 0 ] && d="$d, $unrep not reported by the API"
    else d="$d; local only"; fi
    [ "$newest" != - ] && d="$d; newest failure $newest"
    if [ $((ok * 100)) -lt $((runs * BACKUP_FAIL_PCT)) ]; then cline FAIL "backup rate $name" "$d"
    elif [ "$failed" -gt 0 ] || [ "$s3f" -gt 0 ]; then cline WARN "backup rate $name" "$d"
    else cline OK "backup rate $name" "$d"; fi
  done <<<"$dbs"
fi

# The sample of the last checkup to compare with: at least 20 days old if there is one.
prev=''; [ -n "$ip" ] && prev=$(checkup_sample_prev "$ip" "$now" 20 2>/dev/null)

# --- Cost (Hetzner list prices through hcloud) ---
cost=-
cost_section() {
  local c n names sum backups extra ips vols vgb pc
  section "Cost"
  if [ "$provider" != hetzner ]; then
    cline OK "cost" "n/a (not Hetzner; check your provider's invoice)"; return
  fi
  if ! c=$(server_cost 2>&1); then cline WARN "cost" "n/a ($(head -n 1 <<<"$c"))"; return; fi
  n=$(awk -F '\t' '$1 == "server"' <<<"$c" | wc -l | tr -d ' ')
  names=$(awk -F '\t' '$1 == "server" { print $2 }' <<<"$c" | paste -sd ',' - | sed 's/,/, /g')
  read -r sum backups <<<"$(awk -F '\t' '$1 == "server" && $5 != "?" { s += $5; if ($6 == "on") b += $5 * 0.2 }
    END { printf "%.2f %.2f\n", s + b, b }' <<<"$c")"
  [ "$(awk -F '\t' '$1 == "server" && $5 == "?"' <<<"$c")" = "" ] && cost=$sum
  ips=$(awk -F '\t' '$1 == "primary-ip"' <<<"$c" | wc -l | tr -d ' ')
  vols=$(awk -F '\t' '$1 == "volume"' <<<"$c" | wc -l | tr -d ' ')
  vgb=$(awk -F '\t' '$1 == "volume" { s += $3 + 0 } END { print s + 0 }' <<<"$c")
  extra="list price, gross; primary IPs $ips, volumes $vols ($vgb GB): their prices, Object Storage and traffic in the Hetzner Console -> Usage"
  pc=$(cut -f8 <<<"$prev")
  if [ "$cost" != - ] && [ -n "$prev" ] && [[ $pc =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    extra="$(awk -v a="$cost" -v b="$pc" 'BEGIN { printf "%+.2f EUR", a - b }') since $(cut -f1 <<<"$prev"); $extra"
  fi
  if [ "$n" = 0 ]; then cline WARN "cost" "no server in the hcloud project (another project's token?)"
  elif [ "$n" -gt 1 ]; then cline WARN "cost" "$n servers in the project ($names): $sum EUR a month; an old one left after REBUILD.md step 10?; $extra"
  else cline OK "cost" "$names: $sum EUR a month$([ "$backups" != 0.00 ] && echo " with backups (+$backups)"); $extra"; fi
}

# --- Disk growth since the last checkup ---
section "Disk growth"
used=$(awk '$1 == "df" { print $2 }' <<<"$facts"); total=$(awk '$1 == "df" { print $3 }' <<<"$facts")
bk=$(awk '$1 == "du" && $2 == "/data/coolify/backups" { print $3 }' <<<"$facts")
dm=$(awk '$1 == "du" && $2 == "/root/db-dumps" { print $3 }' <<<"$facts")
recl=$(awk -F '\t' '$1 ~ /^ddf (Images|Build Cache)$/ && $3 != "" { split($3, a, " "); printf "%s%s %s", (n++ ? ", " : ""), a[1], tolower(substr($1, 5)) }' <<<"$facts")
if [ "$have_facts" = 0 ] || [ -z "$used" ] || [ -z "$total" ] || [ "$total" = 0 ]; then
  cline WARN "disk growth" "n/a (could not read the server)"
else
  extra="backups $(gb "${bk:-0}"), dumps $(gb "${dm:-0}")${recl:+, docker reclaimable $recl}"
  now_d="$(gb "$used") of $(gb "$total")"
  if [ $((used * 100)) -ge $((total * DISK_TARGET)) ] && [ -z "$prev" ]; then
    cline WARN "disk growth" "$now_d; already above $DISK_TARGET%; first sample; $extra"
  elif [ -z "$prev" ]; then
    cline OK "disk growth" "$now_d; first sample, growth from the next checkup; $extra"
  else
    read -r mark d <<<"$(awk -F '\t' -v u="$used" -v t="$total" -v now="$now" -v tgt="$DISK_TARGET" \
      -v fm="$GROWTH_FAIL_M" -v wm="$GROWTH_WARN_M" '{
      days = (now - $2) / 86400; delta = u - $4; target = t * tgt / 100
      since = sprintf("%+.1f GB since %s", delta / 1048576, $1)
      if (u >= target) { print "WARN", since "; already above " tgt "%"; exit }
      if (days < 7) { print "OK", since " (too recent to project)"; exit }
      per = delta * 30 / days
      if (per <= 0) { print "OK", since " (no growth)"; exit }
      m = (target - u) / per
      eta = (m >= 24) ? sprintf("~%d years", m / 12) : sprintf("~%d months", m)
      if (m < 1) eta = "under a month"
      print (m < fm ? "FAIL" : (m < wm ? "WARN" : "OK")), since " (" eta " to " tgt "%)" }' <<<"$prev")"
    cline "$mark" "disk growth" "$now_d, $d; $extra"
  fi
fi

cost_section

# --- Actions ---
section "Actions"
if [ "${#acts[@]}" = 0 ]; then echo "  none"
else for l in "${acts[@]}"; do printf '  %s -> %s\n' "${l%"${l##*[! ]}"}" "$(action_for "$l")"; done; fi

if [ "$have_facts" = 1 ] && [ -n "$used" ] && [ -n "$ip" ]; then
  if [ "${CHECKUP_RECORD:-1}" = 0 ]; then echo "Not recorded (CHECKUP_RECORD=0)."
  elif checkup_sample_append "$now" "$ip" "$used" "$total" "${bk:-0}" "${dm:-0}" "$cost"; then
    echo "Recorded in $(checkup_log_file) for next month."
  else echo "Could not write $(checkup_log_file); disk growth needs it next month."; fi
fi

echo
if [ "$unreachable" = 1 ]; then echo "RESULT: cannot reach the server or the Coolify API"; exit 2; fi
if [ "$attention" = 1 ]; then echo "RESULT: needs attention"; exit 1; fi
echo "RESULT: all OK"
