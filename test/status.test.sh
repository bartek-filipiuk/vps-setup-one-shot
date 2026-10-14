#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters in single quotes use jq variables ($t)
# Self-check for status.sh against a fake Coolify API, a fake ssh and a fake openssl.
# No server, no network. Run from the repo root: bash test/status.test.sh
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
        if s.get("reject_token") or self.headers.get("Authorization") != "Bearer " + token:
            return self.send(401, {"message": "Unauthenticated."})
        p = self.path.removeprefix("/api/v1").split("?")[0].split("/")[1:]
        def pick(v): return self.send(200, v) if v is not None else self.send(404, {"message": "Not found."})
        if p == ["version"]: return pick(s.get("version"))
        if p == ["applications"]: return pick(s.get("apps"))
        if p[:2] == ["deployments", "applications"]: return pick(s.get("deploys", {}).get(p[2]))
        if p == ["databases"]: return pick(s.get("dbs"))
        if len(p) == 3 and p[0] == "databases" and p[2] == "backups": return pick(s.get("backups", {}).get(p[1]))
        if len(p) == 5 and p[4] == "executions": return pick(s.get("execs", {}).get(p[3]))
        self.send(404, {"message": "Not found."})
HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$HOME"' EXIT

mkdir -p "$HOME/.config/coolify" "$HOME/bin"
( umask 077; printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=%s\n' "$PORT" "$TOKEN" > "$HOME/.config/coolify/config" )

# Fake ssh: ignores the script on stdin, answers from FAKE_* variables.
cat > "$HOME/bin/fake-ssh" <<'STUB'
#!/bin/sh
cat >/dev/null
[ "${FAKE_SSH_RC:-0}" = 0 ] || exit "$FAKE_SSH_RC"
echo "disk ${FAKE_DISK:-40}"
echo "mem 1200 3800"
echo "reboot ${FAKE_REBOOT:-no}"
STUB
# Fake openssl: s_client prints a placeholder cert, x509 turns it into an expiry FAKE_CERT_DAYS from now.
cat > "$HOME/bin/fake-openssl" <<'STUB'
#!/bin/sh
case $1 in
  s_client) [ "${FAKE_CERT_DAYS:-60}" = fail ] && exit 1; echo "FAKE CERT" ;;
  x509) grep -q "FAKE CERT" || exit 1
        echo "notAfter=$(date -u -d "+${FAKE_CERT_DAYS:-60} days +1 hour" '+%b %e %H:%M:%S %Y GMT')" ;;
esac
STUB
chmod +x "$HOME/bin/fake-ssh" "$HOME/bin/fake-openssl"
export STATUS_SSH="$HOME/bin/fake-ssh" STATUS_OPENSSL="$HOME/bin/fake-openssl"
export STATUS_LATEST_URL="http://127.0.0.1:$PORT/latest"

# Timestamps in the formats a real Coolify 4.3.23 returns: deployments "....000000Z",
# backup executions "+00:00" with finished_at null.
ago()    { date -u -d "-$1 hours" '+%Y-%m-%dT%H:%M:%S.000000Z'; }
ago_tz() { date -u -d "-$1 hours" '+%Y-%m-%dT%H:%M:%S+00:00'; }
BASE=$(jq -n --arg d "$(ago 2)" --arg b "$(ago_tz 5)" '{
  version: "4.3.23", latest: {tag_name: "v4.3.23"},
  apps: [{uuid: "a1", name: "starter", status: "running:healthy", fqdn: "https://app.example.test,http://x.sslip.io"}],
  deploys: {a1: {count: 1, deployments: [
    {status: "finished", created_at: $d, finished_at: $d, commit: "abc123", application_name: "starter", logs: "SECRET-LOG-LINE"},
    {status: "failed", created_at: "2026-01-01T00:00:00.000000Z", finished_at: "2026-01-01T00:01:00.000000Z", commit: "old", application_name: "starter"}]}},
  dbs: [{uuid: "d1", name: "starter-db"}],
  backups: {d1: [{uuid: "b1", enabled: true, frequency: "0 2 * * *", last_execution_at: null, save_s3: true,
    executions: [{uuid: "e0", status: "success", created_at: $b, finished_at: null}]}]},
  execs: {b1: {executions: [{uuid: "e1", status: "success", created_at: $b, finished_at: null,
    filename: "/data/coolify/backups/pg-dump.dmp", message: "Backup done", size: 1234, s3_uploaded: true}]}}
}')

# run JQ_FILTER [jq args...] -> sets $out and $rc from status.sh on the patched scenario
run() {
  local f=$1; shift
  jq "$@" "$f" <<<"$BASE" > "$HOME/scenario.json"
  out=$("$REPO/status.sh" 2>&1); rc=$?
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

run .
check "all green: exit 0" "$rc" "0"
has "all green: version latest" "$out" '^OK +version +4\.3\.23 \(latest\)'
has "all green: newest deploy (first) wins" "$out" '^OK +app starter +running:healthy, last deploy: finished '
has "all green: cert checked for https host only" "$out" '^OK +cert app\.example\.test +(59|60) days left'
check "all green: http host skipped" "$(grep -c 'sslip' <<<"$out")" "0"
has "all green: backup with +00:00 date" "$out" '^OK +backup starter-db +last success 5h ago'
check "token, auth header and deploy logs never printed" "$(grep -cE 'tok-SECRET|Bearer|SECRET-LOG-LINE' <<<"$out")" "0"
check "no ANSI colors when piped" "$(grep -c $'\033' <<<"$out")" "0"

FAKE_DISK=90 expect "disk 90" 1 '^WARN +disk / +90% used'
FAKE_DISK=97 expect "disk 97" 1 '^FAIL +disk / +97% used'
FAKE_REBOOT=yes expect "reboot" 1 '^WARN +reboot +required'

expect "app exited" 1 '^FAIL +app starter +exited:unhealthy' '.apps[0].status = "exited:unhealthy"'
expect "app degraded" 1 '^FAIL +app starter +degraded' '.apps[0].status = "degraded:unhealthy"'
expect "app running:unhealthy" 1 '^WARN +app starter +running:unhealthy' '.apps[0].status = "running:unhealthy"'
expect "app running:unknown" 0 '^OK +app starter +running:unknown' '.apps[0].status = "running:unknown"'

expect "deploy failed" 1 '^FAIL +app starter +running:healthy, last deploy: failed' '.deploys.a1.deployments[0].status = "failed"'
expect "deploy error" 1 '^FAIL +app starter .*last deploy: error' '.deploys.a1.deployments[0].status = "error"'
expect "deploy cancelled" 1 '^WARN +app starter .*last deploy: cancelled-by-user' '.deploys.a1.deployments[0].status = "cancelled-by-user"'
expect "deploy in progress" 0 '^OK +app starter .*last deploy: in_progress' '.deploys.a1.deployments[0].status = "in_progress"'
expect "deploy queued" 0 '^OK +app starter .*last deploy: queued' '.deploys.a1.deployments[0].status = "queued"'
expect "no deploys yet" 0 '^OK +app starter .*last deploy: none$' '.deploys.a1 = {count: 0, deployments: []}'
expect "deployments unreadable" 1 '^WARN +app starter .*last deploy: n/a \(could not read\)' '.deploys.a1 = {unexpected: 1}'
expect "deployments 404" 1 '^WARN +app starter .*last deploy: n/a \(could not read\)' 'del(.deploys)'

FAKE_CERT_DAYS=10 expect "cert 10d" 1 '^WARN +cert app\.example\.test +expires in (9|10) days'
FAKE_CERT_DAYS=2 expect "cert 2d" 1 '^FAIL +cert app\.example\.test +expires in (1|2) days'
FAKE_CERT_DAYS=fail expect "cert unreachable" 1 '^FAIL +cert app\.example\.test +unreachable'
expect "fqdn whitespace trimmed" 0 '^OK +cert app\.example\.test +(59|60) days' '.apps[0].fqdn = " https://app.example.test/path , http://x.sslip.io "'
expect "fqdn IPv6 literal" 0 '^OK +cert \[2001:db8::1\]:8443 +n/a \(IPv6 address\)' '.apps[0].fqdn = "https://app.example.test,https://[2001:db8::1]:8443"'
STATUS_TIMEOUT=none expect "no timeout command" 1 '^WARN +cert checks +skipped' '.apps[0].fqdn = "https://a.example.test,https://b.example.test"'
check "no timeout command: noted once" "$(grep -c 'cert ' <<<"$out")" "1"

expect "backup 30h" 1 '^WARN +backup starter-db +last success 30h ago' '.execs.b1.executions[0].created_at = $t' --arg t "$(ago_tz 30)"
expect "backup +02:00 offset" 0 '^OK +backup starter-db +last success 5h ago' \
  '.execs.b1.executions[0].created_at = $t' --arg t "$(date -u -d '-3 hours' '+%Y-%m-%dT%H:%M:%S+02:00')"
expect "backup space separator" 0 '^OK +backup starter-db +last success 4h ago' \
  '.execs.b1.executions[0].created_at = $t' --arg t "$(date -u -d '-4 hours' '+%Y-%m-%d %H:%M:%S')"
expect "backup none" 1 '^FAIL +backup starter-db +none \(no backup has run\)' '.execs.b1.executions = []'
expect "no schedule" 1 '^FAIL +backup starter-db +none \(no backup schedule\)' '.backups.d1 = []'
expect "backup failed" 1 '^FAIL +backup starter-db +last backup failed' \
  '.execs.b1.executions += [{uuid: "e2", status: "failed", created_at: $t, finished_at: null}]' --arg t "$(ago_tz 1)"
expect "executions 404: embedded copy used" 0 '^OK +backup starter-db +last success 5h ago' 'del(.execs)'
expect "backups 404" 1 '^WARN +backup starter-db +n/a \(could not read\)' 'del(.backups)'
expect "backups unreadable" 1 '^WARN +backup starter-db +n/a \(could not read\)' '.backups.d1 = {unexpected: 1}'
expect "unknown date format" 1 '^WARN +backup starter-db +n/a \(could not read\)' '.execs.b1.executions[0].created_at = "13/10/2026 12:00"'

# off-site (S3) copies: s3_uploaded when the API returns it, otherwise the message
run .
has "all green: off-site copy" "$out" '^OK +off-site starter-db +last S3 copy 5h ago$'
expect "s3 copy 30h" 1 '^WARN +off-site starter-db +last S3 copy 30h ago$' '.execs.b1.executions[0].created_at = $t' --arg t "$(ago_tz 30)"
expect "s3 newest upload failed" 1 '^WARN +off-site starter-db +last S3 copy 5h ago; newest upload failed \(upload not reported by API, from message\)$' \
  '.execs.b1.executions[0] |= del(.s3_uploaded) | .execs.b1.executions += [{uuid: "e2", status: "success", created_at: $t, finished_at: null,
    message: "Backup done. Warning: S3 upload failed: Access Denied"}]' --arg t "$(ago_tz 1)"
has "s3 newest upload failed: local backup still OK" "$out" '^OK +backup starter-db +last success 1h ago$'
expect "s3 upload never worked" 1 '^FAIL +off-site starter-db +no backup has reached S3; newest upload failed$' \
  '.execs.b1.executions[0] |= (del(.s3_uploaded) | .message = "Warning: S3 upload failed: InvalidAccessKeyId")'
expect "s3_uploaded false" 1 '^FAIL +off-site starter-db +no backup has reached S3; newest upload failed$' '.execs.b1.executions[0].s3_uploaded = false'
expect "s3_uploaded absent" 0 '^OK +off-site starter-db +last S3 copy 5h ago \(upload not reported by API, from message\)$' \
  '.execs.b1.executions[0] |= del(.s3_uploaded)'
expect "local only" 1 '^WARN +off-site starter-db +local only \(no backup schedule copies to S3\)$' '.backups.d1[0].save_s3 = false'
has "local only: local backup line unchanged" "$out" '^OK +backup starter-db +last success 5h ago$'
run '.backups.d1 = []'
check "no schedule: no off-site line on top of the FAIL" "$(grep -c 'off-site' <<<"$out")" "0"

expect "latest unreachable" 0 '^OK +version +4\.3\.23 \(latest unknown\)' 'del(.latest)'
expect "patch behind" 0 '^OK +version +4\.3\.23 \(latest release 4\.3\.30\)' '.latest.tag_name = "v4.3.30"'
expect "minor behind" 1 '^WARN +version +4\.3\.23, latest release 4\.4\.0' '.latest.tag_name = "v4.4.0"'
expect "major behind" 1 '^WARN +version +4\.3\.23, latest release 5\.0\.1' '.latest.tag_name = "v5.0.1"'

FAKE_SSH_RC=255 expect "ssh down" 2 '^FAIL +ssh +server unreachable'
has "ssh down: still checks apps" "$out" '^OK +app starter'
expect "API error" 2 '^FAIL +api +API error \(HTTP 404\)' 'del(.version)'
has "API error: still checks server" "$out" '^OK +disk / '
mkdir -p "$HOME/dead/.config/coolify"
printf 'COOLIFY_URL=http://127.0.0.1:9\nCOOLIFY_TOKEN=%s\n' "$TOKEN" > "$HOME/dead/.config/coolify/config"
out=$(HOME="$HOME/dead" "$REPO/status.sh" 2>&1); rc=$?
check "API unreachable: exit 2" "$rc" "2"; has "API unreachable: line" "$out" '^FAIL +api +Coolify API unreachable'
expect "token rejected" 2 '^FAIL +api +API token rejected \(HTTP 401\)' '.reject_token = true'
jq . <<<"$BASE" > "$HOME/scenario.json"
out=$(HOME="$HOME/no-config" "$REPO/status.sh" 2>&1); rc=$?
check "config missing: exit 2" "$rc" "2"; has "config missing: line" "$out" '^FAIL +api +Coolify config missing'

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
