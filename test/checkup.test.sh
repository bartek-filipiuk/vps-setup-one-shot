#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters in single quotes use jq variables
# Self-check for checkup.sh against a fake Coolify API (also serving the GitHub advisories), fake
# ssh for status.sh and for the checkup's server facts, a fake openssl and a fake hcloud. No
# server, no network: the port probes go to 127.0.0.1. Run from the repo root: bash test/checkup.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
export HOME; HOME=$(mktemp -d)
PORT=$((20000 + RANDOM % 10000))
TOKEN='3|tok-SECRET-xyz'
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fails=$((fails + 1)); fi; }
# has NAME OUTPUT REGEX: OUTPUT has a line matching REGEX
has() { if grep -qE "$3" <<<"$2"; then echo "ok   $1"; else echo "FAIL $1: no line matching [$3] in:"; echo "     ${2//$'\n'/$'\n'     }"; fails=$((fails + 1)); fi; }
# hasnt NAME OUTPUT REGEX: no line of OUTPUT matches REGEX
hasnt() { if grep -qE "$3" <<<"$2"; then echo "FAIL $1: unexpected line matching [$3]:"; grep -E "$3" <<<"$2" | sed 's/^/     /'; fails=$((fails + 1)); else echo "ok   $1"; fi; }

# The fake API answers from $HOME/scenario.json, rewritten by each case.
python3 - "$PORT" "$HOME/scenario.json" "$TOKEN" <<'EOF' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, path, token = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        s = json.load(open(path))
        if self.path == "/latest":
            return self.send(200, s["latest"]) if s.get("latest") else self.send(503, {})
        if self.path.startswith("/gh/advisories"):
            if s.get("advisories_status"): return self.send(s["advisories_status"], {"message": "API rate limit exceeded"})
            return self.send(200, s["advisories"]) if "advisories" in s else self.send(503, {})
        if self.headers.get("Authorization") != "Bearer " + token:
            return self.send(401, {"message": "Unauthenticated."})
        p = self.path.removeprefix("/api/v1").split("?")[0].split("/")[1:]
        def pick(v): return self.send(200, v) if v is not None else self.send(404, {"message": "Not found."})
        if p == ["version"]: return pick(s.get("version"))
        if p == ["applications"]: return pick(s.get("apps"))
        if p[:2] == ["deployments", "applications"]: return pick(s.get("deploys", {}).get(p[2]))
        if p == ["services"]: return pick(s.get("services"))
        if p == ["databases"]: return pick(s.get("dbs"))
        if len(p) == 3 and p[0] == "databases" and p[2] == "backups": return pick(s.get("backups", {}).get(p[1]))
        if len(p) == 5 and p[4] == "executions": return pick(s.get("execs", {}).get(p[3]))
        if len(p) == 2 and p[0] == "notifications": return pick(s.get("notif", {}).get(p[1]))
        self.send(404, {"message": "Not found."})
HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$HOME"' EXIT

# Two ports nothing listens on (bound once by the OS, then released): "closed from the internet".
read -r CLOSED1 CLOSED2 <<<"$(python3 -c 'import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s)
print(*[s.getsockname()[1] for s in ps])')"
export CLOSED1 CLOSED2 PORT
LO=$(( CLOSED1 < CLOSED2 ? CLOSED1 : CLOSED2 )) HI=$(( CLOSED1 < CLOSED2 ? CLOSED2 : CLOSED1 ))

mkdir -p "$HOME/.config/coolify" "$HOME/.config/vps-setup" "$HOME/bin"
( umask 077; printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=%s\n' "$PORT" "$TOKEN" > "$HOME/.config/coolify/config" )
( umask 077; printf 'PROVIDER=hetzner\nSERVER_NAME=coolify-1\nVPS_IP=127.0.0.1\n' > "$HOME/.config/vps-setup/state" )
STATE="$HOME/.config/vps-setup/state" LOG="$HOME/.config/vps-setup/checkup.log"

# Fake ssh for status.sh: ignores the script on stdin, answers from FAKE_* variables.
cat > "$HOME/bin/fake-ssh" <<'STUB'
#!/bin/sh
cat >/dev/null
[ "${FAKE_SSH_RC:-0}" = 0 ] || exit "$FAKE_SSH_RC"
echo "disk ${FAKE_DISK:-40}"
echo "mem 1200 3800"
echo "reboot no"
echo "updates 0 0"
STUB
# Fake ssh for checkup_server_facts: a clean Coolify 4.3.23 server, changed by FAKE_* variables.
# Coolify's 8000 and the realtime port stand in as CLOSED1 and CLOSED2 (nothing answers on them).
cat > "$HOME/bin/fake-facts" <<'STUB'
#!/bin/sh
cat >/dev/null
[ "${FAKE_FACTS_FAIL:-0}" = 1 ] && exit 255
cat <<EOF
listen tcp 0.0.0.0:22 sshd
listen tcp [::]:22 sshd
listen tcp 0.0.0.0:80 docker-proxy
listen tcp 0.0.0.0:443 docker-proxy
listen tcp [::]:443 docker-proxy
listen tcp 0.0.0.0:$CLOSED1 docker-proxy
listen tcp [::]:$CLOSED1 docker-proxy
listen tcp 0.0.0.0:$CLOSED2 docker-proxy
listen tcp 127.0.0.1:5432 ?
listen tcp 127.0.0.53%lo:53 systemd-resolve
listen tcp 10.0.1.1:9000 ?
listen udp 127.0.0.53%lo:53 systemd-resolve
listen udp 0.0.0.0:443 docker-proxy
EOF
[ -n "${FAKE_LISTEN:-}" ] && printf '%s\n' "$FAKE_LISTEN"
printf '%s\n' "sshd port 22" "sshd passwordauthentication ${FAKE_PASSWORD:-no}" "sshd permitrootlogin ${FAKE_ROOT:-without-password}" \
  "sshd pubkeyauthentication yes" "sshd permitemptypasswords no" "sshd kbdinteractiveauthentication no"
echo "authkey 256 SHA256:fakeKeyUser (ED25519)"
echo "authkey 256 SHA256:fakeKeyCoolify (ED25519)"
[ -n "${FAKE_DOCKERD_TCP:-}" ] && echo "dockerd_tcp $FAKE_DOCKERD_TCP"
[ -n "${FAKE_DAEMON_HOSTS:-}" ] && echo "dockerd_hosts $FAKE_DAEMON_HOSTS"
cat <<'EOF'
cont coolify ghcr.io/coollabsio/coolify:4.3.23 false
cont coolify-db postgres:15-alpine false
cont coolify-redis redis:7-alpine false
cont coolify-realtime ghcr.io/coollabsio/coolify-realtime:1.0.10 false
cont coolify-proxy traefik:v3.6 false sock:ro
cont coolify-sentinel ghcr.io/coollabsio/sentinel:0.0.16 false sock:rw
cont a1-123456789 a1:abc123 false
cont x8k2-helper ghcr.io/coollabsio/coolify-helper:1.0.17 false sock:rw
EOF
[ -n "${FAKE_CONT:-}" ] && printf '%s\n' "$FAKE_CONT"
echo "df ${FAKE_USED_KB:-12000000} ${FAKE_TOTAL_KB:-40000000}"
echo "du /data/coolify/backups 1258291"
echo "du /root/db-dumps 314573"
printf 'ddf Images\t4.2GB\t2.1GB (50%%)\nddf Build Cache\t1GB\t1GB\n'
echo "facts done"
STUB
# Fake openssl: every certificate has FAKE_CERT_DAYS (default 60) left.
cat > "$HOME/bin/fake-openssl" <<'STUB'
#!/bin/sh
case $1 in
  s_client) echo "FAKE CERT" ;;
  x509) grep -q "FAKE CERT" || exit 1
        echo "notAfter=$(date -u -d "+${FAKE_CERT_DAYS:-60} days +1 hour" '+%b %e %H:%M:%S %Y GMT')" ;;
esac
STUB
# Fake hcloud: logs every call; answers list and describe -o json from FAKE_* variables.
cat > "$HOME/bin/hcloud" <<'STUB'
#!/bin/sh
echo "hcloud $*" >> "$HOME/hcloud.log"
[ "${FAKE_HCLOUD_FAIL:-0}" = 1 ] && { echo 'hcloud: no active context or token' >&2; exit 1; }
rule() { printf '{"direction": "in", "protocol": "%s", "port": %s, "source_ips": ["0.0.0.0/0", "::/0"], "destination_ips": [], "description": null}' "$1" "$2"; }
srv() { printf '{"id": %s, "name": "%s", "server_type": {"name": "cx22", "prices": [{"location": "nbg1", "price_monthly": {"net": "3.7900000000", "gross": "4.5101000000"}}, {"location": "fsn1", "price_monthly": {"net": "3.8700000000", "gross": "4.6000000000"}}]}, "datacenter": {"name": "fsn1-dc14", "location": {"name": "fsn1"}}, "backup_window": %s}' "$1" "$2" "$3"; }
case "$1 $2" in
  "firewall describe")
    rules="$(rule tcp '"22"'), $(rule tcp '"80"'), $(rule tcp '"443"'), $(rule icmp null)"
    [ -n "${FAKE_FW_EXTRA:-}" ] && rules="$rules, $(rule tcp "\"$FAKE_FW_EXTRA\"")"
    [ "${FAKE_FW_NO80:-0}" = 1 ] && rules="$(rule tcp '"22"'), $(rule tcp '"443"'), $(rule icmp null)"
    applied='[{"type": "server", "server": {"id": 42}}]'; [ "${FAKE_FW_UNAPPLIED:-0}" = 1 ] && applied='[]'
    echo "{\"id\": 7, \"name\": \"$3\", \"rules\": [$rules], \"applied_to\": $applied}" ;;
  "server describe") echo "{\"id\": 42, \"name\": \"$3\"}" ;;
  "server list")
    if [ "${FAKE_TWO_SERVERS:-0}" = 1 ]; then echo "[$(srv 42 coolify-1 null), $(srv 41 coolify-old null)]"
    else echo "[$(srv 42 coolify-1 "${FAKE_BACKUP_WINDOW:-null}")]"; fi ;;
  "primary-ip list") echo '[{"name": "primary_ip-1", "type": "ipv4", "datacenter": {"location": {"name": "fsn1"}}}]' ;;
  "volume list") echo '[]' ;;
  *) echo "hcloud: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$HOME/bin/"*
PATH="$HOME/bin:$PATH"
export STATUS_SSH="$HOME/bin/fake-ssh" STATUS_OPENSSL="$HOME/bin/fake-openssl" CHECKUP_SSH="$HOME/bin/fake-facts"
export STATUS_LATEST_URL="http://127.0.0.1:$PORT/latest" ADVISORIES_URL="http://127.0.0.1:$PORT/gh/advisories"
export CHECKUP_PROBE_TIMEOUT=2

ago_tz() { date -u -d "-$1 hours" '+%Y-%m-%dT%H:%M:%S+00:00'; }
ago() { date -u -d "-$1 hours" '+%Y-%m-%dT%H:%M:%S.000000Z'; }
# A clean setup as status.test.sh has it, plus the advisories GitHub publishes for Coolify.
BASE=$(jq -n --arg d "$(ago 2)" --arg b "$(ago_tz 5)" --arg b2 "$(ago_tz 29)" '{
  version: "4.3.23", latest: {tag_name: "v4.3.23"},
  apps: [{uuid: "a1", name: "starter", status: "running:healthy", fqdn: "https://app.example.test"}],
  deploys: {a1: {count: 1, deployments: [{status: "finished", created_at: $d, finished_at: $d, commit: "abc123"}]}},
  services: [],
  dbs: [{uuid: "d1", name: "starter-db", database_type: "standalone-postgresql", image: "postgres:17-alpine"}],
  backups: {d1: [{uuid: "b1", enabled: true, frequency: "0 2 * * *", save_s3: true, executions: []}]},
  execs: {b1: {executions: [
    {uuid: "e1", status: "success", created_at: $b, finished_at: null, message: "Backup done", s3_uploaded: true},
    {uuid: "e2", status: "success", created_at: $b2, finished_at: null, message: "Backup done", s3_uploaded: true}]}},
  notif: {discord: ({discord_enabled: true}
    + ([$ev | split(" ")[] | {key: "\(.)_discord_notifications", value: true}] | from_entries))},
  advisories: [
    {ghsa_id: "GHSA-aaaa-0000-0001", severity: "critical", published_at: "2025-01-10T00:00:00Z",
     vulnerabilities: [{package: {ecosystem: "other", name: "coolify"}, vulnerable_version_range: "< 4.0.0-beta.420", patched_versions: "4.0.0-beta.420"}]},
    {ghsa_id: "GHSA-aaaa-0000-0002", severity: "high", published_at: "2026-08-01T00:00:00Z",
     vulnerabilities: [{package: {ecosystem: "other", name: "coolify"}, vulnerable_version_range: "< 4.3.20", patched_versions: "4.3.20"}]}]
}' --arg ev "status_change deployment_failure backup_failure server_unreachable server_reachable server_disk_usage restart_limit_reached")

# run JQ_FILTER [jq args...] -> sets $out and $rc from checkup.sh on the patched scenario
run() {
  local f=$1; shift
  jq "$@" "$f" <<<"$BASE" > "$HOME/scenario.json"
  out=$("$REPO/checkup.sh" 2>&1); rc=$?
  printf '%s\n' "$out" >> "$HOME/outputs.log"
}
# expect NAME RC REGEX [JQ_FILTER [jq args...]]: run, then check the exit code and one line
expect() {
  local n=$1 want=$2 re=$3; shift 3
  run "${@:-.}"
  check "$n: exit $want" "$rc" "$want"; has "$n: line" "$out" "$re"
}

printf '{}' > "$HOME/scenario.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/latest" && break; sleep 0.3
done

# A clean setup: no WARN, no FAIL anywhere (the R16 done criterion), one log line, mode 600
: > "$HOME/hcloud.log"
run .
check "clean: exit 0" "$rc" "0"
hasnt "clean: no WARN or FAIL line" "$out" '^(WARN|FAIL) '
has "clean: status.sh inside" "$out" '^OK +app starter +running:healthy'
has "clean: first line" "$(head -n 1 <<<"$out")" "^Monthly checkup, $(date -u +%F): status.sh first, then the monthly checks$"
has "clean: firewall" "$out" '^OK +firewall +vps-setup-fw: in tcp/22 tcp/80 tcp/443 icmp only, applied to coolify-1$'
has "clean: Coolify ports closed from outside" "$out" "^OK +listening +$LO \\(docker-proxy\\), $HI \\(docker-proxy\\) on the server, closed from the internet; UDP not probed: 443 \\(docker-proxy\\)$"
has "clean: sshd" "$out" '^OK +sshd +password login off, root by key only$'
has "clean: root keys" "$out" '^OK +root keys +2 in /root/\.ssh/authorized_keys: ED25519 SHA256:fakeKeyUser, ED25519 SHA256:fakeKeyCoolify'
has "clean: docker api" "$out" '^OK +docker api +unix socket only$'
has "clean: docker socket, Coolify's own" "$out" "^OK +docker socket +only Coolify's own containers \\(coolify-proxy, coolify-sentinel, x8k2-helper\\)$"
has "clean: privileged" "$out" '^OK +docker privileged +none outside Coolify$'
has "clean: advisories" "$out" '^OK +advisories +none of 2 published advisories affects 4\.3\.23$'
has "clean: backup rate" "$out" '^OK +backup rate starter-db +2/2 runs succeeded; S3: 2 uploaded$'
has "clean: disk growth, first sample" "$out" '^OK +disk growth +11\.4 GB of 38\.1 GB; first sample, growth from the next checkup; backups 1\.2 GB, dumps 0\.3 GB, docker reclaimable 2\.1GB images, 1GB build cache$'
has "clean: cost" "$out" '^OK +cost +coolify-1: 4\.60 EUR a month; list price, gross; primary IPs 1, volumes 0 \(0 GB\): their prices, Object Storage and traffic in the Hetzner Console -> Usage$'
has "clean: Actions none" "$(sed -n '/^Actions$/,/^RESULT/p' <<<"$out")" '^  none$'
has "clean: RESULT" "$out" '^RESULT: all OK$'
check "clean: one RESULT line (status.sh's dropped)" "$(grep -c '^RESULT' <<<"$out")" "1"
check "clean: log line written, mode 600" "$(wc -l < "$LOG"):$(stat -c %a "$LOG")" "1:600"
check "clean: log line" "$(cut -f1,3-8 "$LOG")" "$(printf '%s\t127.0.0.1\t12000000\t40000000\t1258291\t314573\t4.60' "$(date -u +%F)")"
has "clean: says where it recorded" "$out" "^Recorded in $LOG for next month\\.$"
check "clean: hcloud only list and describe" "$(grep -cvE '^hcloud [a-z-]+ (list|describe)( [a-z0-9-]+)? -o json$' "$HOME/hcloud.log"):$(wc -l < "$HOME/hcloud.log")" "0:6"
check "token and auth header never printed" "$(grep -cE 'tok-SECRET|Bearer' <<<"$out")" "0"
check "no ANSI colors when piped" "$(grep -c $'\033' <<<"$out")" "0"

rm -f "$LOG"
CHECKUP_RECORD=0 run .
check "CHECKUP_RECORD=0: no log" "$([ -e "$LOG" ] && echo yes || echo no)" "no"
has "CHECKUP_RECORD=0: said" "$out" '^Not recorded \(CHECKUP_RECORD=0\)\.$'

# firewall (CHECKUP.md 3a)
FAKE_FW_EXTRA=8000 expect "firewall: extra port" 1 '^FAIL +firewall +.*; extra inbound rules: tcp/8000 from 0\.0\.0\.0/0,::/0$'
has "firewall: extra port in Actions with its runbook" "$out" '^  FAIL +firewall .* -> CHECKUP\.md 3a$'
FAKE_FW_EXTRA=22222 expect "firewall: Forgejo port not recorded" 1 '^FAIL +firewall .*extra inbound rules: tcp/22222'
echo "CHECKUP_PORTS_OK=tcp/22222" >> "$STATE"
FAKE_FW_EXTRA=22222 expect "firewall: CHECKUP_PORTS_OK" 0 '^OK +firewall +vps-setup-fw: in tcp/22 tcp/80 tcp/443 icmp tcp/22222 only, applied to coolify-1$'
sed -i '/^CHECKUP_PORTS_OK=/d' "$STATE"
FAKE_FW_UNAPPLIED=1 expect "firewall: not applied" 1 '^FAIL +firewall +.*; NOT applied to coolify-1$'
FAKE_FW_NO80=1 expect "firewall: a rule missing" 1 '^WARN +firewall +.*, applied to coolify-1; missing tcp/80$'
FAKE_HCLOUD_FAIL=1 expect "firewall: hcloud fails" 1 '^WARN +firewall +n/a \(hcloud firewall describe failed: hcloud: no active context or token'
has "hcloud fails: cost" "$out" '^WARN +cost +n/a \(hcloud server list failed'
sed -i 's/^PROVIDER=hetzner$/PROVIDER=other/' "$STATE"; : > "$HOME/hcloud.log"
expect "other provider: firewall n/a" 0 '^OK +firewall +n/a \(no cloud firewall API for this provider; it must let in only 22, 80 and 443: CHECKUP\.md 3a\)$'
has "other provider: cost n/a" "$out" "^OK +cost +n/a \\(not Hetzner; check your provider's invoice\\)$"
check "other provider: hcloud never called" "$(wc -l < "$HOME/hcloud.log")" "0"
sed -i 's/^PROVIDER=other$/PROVIDER=hetzner/' "$STATE"

# listening: probed from this machine; the fake API's port is a port that answers
FAKE_LISTEN="listen tcp 0.0.0.0:$PORT coolify" expect "listening: a reachable port" 1 "^FAIL +listening +reachable from the internet: $PORT \\(coolify\\)"
has "listening: Actions" "$out" '^  FAIL +listening .* -> CHECKUP\.md 3a$'
FAKE_LISTEN="listen tcp 127.0.0.1:$PORT coolify" expect "listening: loopback not probed" 0 "^OK +listening +$LO "
FAKE_LISTEN="listen tcp 0.0.0.0:$PORT coolify" CHECKUP_PROBE_TIMEOUT=x expect "listening: probe impossible" 1 '^WARN +listening +could not probe '

# SSH daemon (CHECKUP.md 3b)
FAKE_PASSWORD=yes expect "sshd: password login on" 1 '^FAIL +sshd +passwordauthentication yes \(want no\)$'
FAKE_ROOT=yes expect "sshd: root with password" 1 '^FAIL +sshd +permitrootlogin yes \(want without-password\)$'
has "sshd: Actions" "$out" '^  FAIL +sshd .* -> CHECKUP\.md 3b$'
FAKE_ROOT=prohibit-password expect "sshd: newer OpenSSH spelling" 0 '^OK +sshd +password login off'

# Docker (CHECKUP.md 3c)
FAKE_DOCKERD_TCP=tcp://0.0.0.0:2375 expect "docker: dockerd on tcp" 1 '^FAIL +docker api +the Docker API is on TCP \(dockerd tcp://0\.0\.0\.0:2375\): whoever reaches it is root$'
FAKE_DAEMON_HOSTS='"hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"]' expect "docker: daemon.json hosts" 1 '^FAIL +docker api +the Docker API is on TCP \( daemon\.json "hosts": .*tcp://0\.0\.0\.0:2376'
FAKE_LISTEN="listen tcp 0.0.0.0:2376 dockerd" expect "docker: 2376 listening" 1 '^FAIL +docker api +.*listening 0\.0\.0\.0:2376\)'
FAKE_CONT="cont portainer portainer/portainer-ce:2.21 false sock:rw" expect "docker: foreign socket" 1 '^FAIL +docker socket +mounted by portainer \(portainer/portainer-ce:2\.21, rw\): each of them controls the server$'
has "docker: Actions" "$out" '^  FAIL +docker socket .* -> CHECKUP\.md 3c$'
FAKE_CONT="cont coolify-helperish evil/coolify-helper:1 false sock:rw" expect "docker: image prefix is exact" 1 '^FAIL +docker socket +mounted by coolify-helperish'
FAKE_CONT="cont ghcr.io-lookalike ghcr.io/coollabsio/coolify-helper-x:1 false sock:ro" expect "docker: image name must match whole" 1 '^FAIL +docker socket +mounted by ghcr\.io-lookalike'
FAKE_CONT="cont vpn linuxserver/wireguard:1 true" expect "docker: privileged" 1 '^WARN +docker privileged +vpn \(linuxserver/wireguard:1\)$'

# Coolify advisories (CHECKUP.md 3d)
expect "advisory: affects this version" 1 '^FAIL +advisory GHSA-aaaa-0000-0003 +high, affects 4\.3\.23 \(>= 4\.0\.0, <= 4\.3\.23\); fixed in 4\.3\.24$' \
  '.advisories += [{ghsa_id: "GHSA-aaaa-0000-0003", severity: "high", published_at: "2026-10-01T00:00:00Z",
    vulnerabilities: [{vulnerable_version_range: ">= 4.0.0, <= 4.3.23", patched_versions: "4.3.24"}]}]'
has "advisory: Actions" "$out" '^  FAIL +advisory GHSA-aaaa-0000-0003 .* -> CHECKUP\.md 3d$'
check "advisory: no summary line when one hits" "$(grep -c '^OK +advisories' <<<"$out")" "0"
expect "advisory: beta range" 1 '^FAIL +advisory GHSA-aaaa-0000-0004 ' \
  '.version = "4.0.0-beta.400" | .latest.tag_name = "v4.0.0-beta.400" | .advisories[0].ghsa_id = "GHSA-aaaa-0000-0004"'
expect "advisory: no version range" 1 '^WARN +advisory GHSA-aaaa-0000-0005 +medium, no version range to compare with 4\.3\.23; read it on GitHub$' \
  '.advisories += [{ghsa_id: "GHSA-aaaa-0000-0005", severity: "medium", vulnerabilities: []}]'
echo "CHECKUP_ADVISORIES_SEEN=GHSA-aaaa-0000-0005" >> "$STATE"
expect "advisory: read and marked seen" 0 '^OK +advisories +none of 3 published advisories affects 4\.3\.23 \(1 without a version range read and marked seen\)$' \
  '.advisories += [{ghsa_id: "GHSA-aaaa-0000-0005", severity: "medium", vulnerabilities: []}]'
sed -i '/^CHECKUP_ADVISORIES_SEEN=/d' "$STATE"
expect "advisories: rate limit" 1 '^WARN +advisories +n/a \(GitHub rate limit \(HTTP 403; 60 calls an hour without a token\); run again in an hour\)$' '.advisories_status = 403'
expect "advisories: GitHub down" 1 '^WARN +advisories +n/a \(GitHub answered HTTP 503 to the advisories call; run again in an hour\)$' 'del(.advisories)'

# backup success rate, last 30 days (CHECKUP.md 3e)
expect "backup rate: a failed run" 1 "^WARN +backup rate starter-db +2/3 runs succeeded; S3: 2 uploaded; newest failure $(date -u -d '-1 day' +%F)$" \
  '.execs.b1.executions += [{uuid: "e3", status: "failed", created_at: $t, finished_at: null, message: "pg_dump: error"}]' --arg t "$(ago_tz 24)"
has "backup rate: Actions" "$out" '^  WARN +backup rate starter-db .* -> CHECKUP\.md 3e$'
expect "backup rate: 40 days old not counted" 0 '^OK +backup rate starter-db +2/2 runs succeeded' \
  '.execs.b1.executions += [{uuid: "e3", status: "failed", created_at: $t, finished_at: null}]' --arg t "$(ago_tz 960)"
expect "backup rate: mostly failing" 1 '^FAIL +backup rate starter-db +1/3 runs succeeded' \
  '.execs.b1.executions = [.execs.b1.executions[0], {uuid: "f1", status: "failed", created_at: $t, finished_at: null},
    {uuid: "f2", status: "failed", created_at: $t, finished_at: null}]' --arg t "$(ago_tz 30)"
expect "backup rate: S3 upload failed counted" 1 '^WARN +backup rate starter-db +2/2 runs succeeded; S3: 1 uploaded, 1 upload failed; newest failure ' \
  '.execs.b1.executions[1] |= (del(.s3_uploaded) | .message = "Backup done. Warning: S3 upload failed: Access Denied")'
expect "backup rate: no run in 30 days" 1 '^FAIL +backup rate starter-db +no backup run in the last 30 days$' \
  '.execs.b1.executions |= map(.created_at = $t)' --arg t "$(ago_tz 1000)"
expect "backup rate: no schedule leaves it to status.sh" 1 '^FAIL +backup starter-db +none \(no backup schedule\)' '.backups.d1 = []'
check "backup rate: no schedule, no second line" "$(grep -c 'backup rate starter-db' <<<"$out")" "0"
expect "off-site not reported by the API (real 4.3.23)" 1 '^WARN +off-site starter-db +.*S3 upload not reported by API' \
  '.execs.b1.executions |= map(del(.s3_uploaded))'
has "off-site not reported: Actions points at the restore drill" "$out" '^  WARN +off-site .* -> RESTORE\.md step 3$'
check "off-site not reported: backup rate stays OK" "$(grep -cE '^(WARN|FAIL) +backup rate' <<<"$out")" "0"
expect "backup rate: local only" 1 '^OK +backup rate starter-db +2/2 runs succeeded; local only$' '.backups.d1[0].save_s3 = false'

# disk growth from the checkup log (CHECKUP.md 3f)
NOW=$(date +%s)
sample() { printf '%s\t%s\t%s\t%s\t40000000\t1000\t1000\t%s\n' "$(date -u -d "@$(( NOW - $1 * 86400 ))" +%F)" "$(( NOW - $1 * 86400 ))" "$2" "$3" "${4:-4.20}"; }
( umask 077; sample 31 127.0.0.1 $((12000000 - 10485760)) > "$LOG" )
expect "disk growth: 10 GB a month" 1 "^WARN +disk growth +11\\.4 GB of 38\\.1 GB, \\+10\\.0 GB since $(date -u -d "@$(( NOW - 31 * 86400 ))" +%F) \\(~2 months to 85%\\); backups"
has "disk growth: Actions" "$out" '^  WARN +disk growth .* -> CHECKUP\.md 3f$'
has "cost: change since the last checkup" "$out" "^OK +cost +coolify-1: 4\\.60 EUR a month; \\+0\\.40 EUR since $(date -u -d "@$(( NOW - 31 * 86400 ))" +%F); list price"
( umask 077; sample 31 127.0.0.1 $((12000000 - 1048576)) > "$LOG" )
expect "disk growth: 1 GB a month" 0 '^OK +disk growth +11\.4 GB of 38\.1 GB, \+1\.0 GB since .* \(~21 months to 85%\)'
( umask 077; sample 31 127.0.0.1 20000000 > "$LOG" )
FAKE_USED_KB=30000000 expect "disk growth: full within a month" 1 '^FAIL +disk growth +28\.6 GB of 38\.1 GB, \+9\.5 GB since .* \(under a month to 85%\)'
( umask 077; sample 31 127.0.0.1 13000000 > "$LOG" )
expect "disk growth: shrinking" 0 '^OK +disk growth +.*-1\.0 GB since .* \(no growth\)'
( umask 077; sample 3 127.0.0.1 2000000 > "$LOG" )
expect "disk growth: too recent to project" 0 '^OK +disk growth +.*\+9\.5 GB since .* \(too recent to project\)'
( umask 077; { sample 60 127.0.0.1 11000000; sample 25 127.0.0.1 11900000; sample 2 127.0.0.1 1; } > "$LOG" )
expect "disk growth: newest sample at least 20 days old" 0 '^OK +disk growth +11\.4 GB of 38\.1 GB, \+0\.1 GB since '
( umask 077; sample 31 198.51.100.4 1 > "$LOG" )
expect "disk growth: another server's samples ignored" 0 '^OK +disk growth +11\.4 GB of 38\.1 GB; first sample'
check "disk growth: log kept private" "$(stat -c %a "$LOG")" "600"
FAKE_USED_KB=36000000 expect "disk growth: already above 85%" 1 '^WARN +disk growth +34\.3 GB of 38\.1 GB, .*; already above 85%; backups'
rm -f "$LOG"
FAKE_USED_KB=36000000 expect "disk growth: above 85% on the first sample" 1 '^WARN +disk growth +34\.3 GB of 38\.1 GB; already above 85%; first sample; backups'
rm -f "$LOG"

# cost (CHECKUP.md 3g)
FAKE_BACKUP_WINDOW='"22-02"' expect "cost: with backups" 0 '^OK +cost +coolify-1: 5\.52 EUR a month with backups \(\+0\.92\); list price'
FAKE_TWO_SERVERS=1 expect "cost: two servers" 1 '^WARN +cost +2 servers in the project \(coolify-1, coolify-old\): 9\.20 EUR a month; an old one left after REBUILD\.md step 10\?; '
has "cost: Actions" "$out" '^  WARN +cost .* -> CHECKUP\.md 3g$'
rm -f "$LOG"

# status.sh findings come into the Actions with their runbooks; unreachable is exit 2
FAKE_DISK=90 expect "status WARN: exit 1" 1 '^WARN +disk / +90% used$'
has "status WARN: in Actions with its runbook" "$out" '^  WARN +disk / +90% used -> DOCTOR\.md C$'
FAKE_CERT_DAYS=10 expect "status cert: runbook" 1 '^  WARN +cert app\.example\.test +expires in (9|10) days -> DOCTOR\.md D$'
rm -f "$LOG"
FAKE_SSH_RC=255 FAKE_FACTS_FAIL=1 expect "server unreachable: exit 2" 2 '^  FAIL +ssh +server unreachable \(exit 255\) -> DOCTOR\.md E$'
has "server unreachable: checkup says n/a, not OK" "$out" '^WARN +sshd +n/a \(could not read the server\)$'
has "server unreachable: RESULT" "$out" '^RESULT: cannot reach the server or the Coolify API$'
check "server unreachable: nothing recorded" "$([ -e "$LOG" ] && echo yes || echo no)" "no"
expect "API down: exit 2" 2 '^WARN +advisories +n/a \(Coolify API unreachable\)$' '.reject_token = true | del(.version)'

check "token never in any output or the log" "$(cat "$HOME/outputs.log" "$LOG" 2>/dev/null | grep -cE 'tok-SECRET|Bearer')" "0"
check "hcloud: never anything but list and describe" "$(grep -cvE '^hcloud [a-z-]+ (list|describe)( [a-z0-9-]+)? -o json$' "$HOME/hcloud.log")" "0"

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
