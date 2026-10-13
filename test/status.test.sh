#!/usr/bin/env bash
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
        if self.headers.get("Authorization") != "Bearer " + token:
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

ago() { date -u -d "-$1 hours" '+%Y-%m-%dT%H:%M:%S.000000Z'; }
BASE=$(jq -n --arg d "$(ago 2)" --arg b "$(ago 5)" '{
  version: "4.3.23", latest: {tag_name: "v4.3.23"},
  apps: [{uuid: "a1", name: "starter", status: "running:healthy", fqdn: "https://app.example.test,http://x.sslip.io"}],
  deploys: {a1: {count: 1, deployments: [{status: "finished", created_at: $d, logs: "SECRET-LOG-LINE"}]}},
  dbs: [{uuid: "d1", name: "starter-db"}],
  backups: {d1: [{uuid: "b1", frequency: "0 2 * * *"}]},
  execs: {b1: {executions: [{status: "success", created_at: $b, finished_at: $b}]}}
}')

# run JQ_FILTER [jq args...] -> sets $out and $rc from status.sh on the patched scenario
run() {
  local f=$1; shift
  jq "$@" "$f" <<<"$BASE" > "$HOME/scenario.json"
  out=$("$REPO/status.sh" 2>&1); rc=$?
}

printf '{}' > "$HOME/scenario.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/latest" && break; sleep 0.3
done

run .
check "all green: exit 0" "$rc" "0"
has "all green: version latest" "$out" '^OK +version +4\.3\.23 \(latest\)'
has "all green: app line" "$out" '^OK +app starter +running:healthy, last deploy: finished '
has "all green: cert checked for https host only" "$out" '^OK +cert app\.example\.test +(59|60) days left'
check "all green: http host skipped" "$(grep -c 'sslip' <<<"$out")" "0"
has "all green: backup" "$out" '^OK +backup starter-db +last success 5h ago'
check "token, auth header and deploy logs never printed" "$(grep -cE 'tok-SECRET|Bearer|SECRET-LOG-LINE' <<<"$out")" "0"
check "no ANSI colors when piped" "$(grep -c $'\033' <<<"$out")" "0"

FAKE_DISK=90 run .;  check "disk 90: exit 1" "$rc" "1"; has "disk 90: WARN" "$out" '^WARN +disk / +90% used'
FAKE_DISK=97 run .;  check "disk 97: exit 1" "$rc" "1"; has "disk 97: FAIL" "$out" '^FAIL +disk / +97% used'
FAKE_REBOOT=yes run .; check "reboot: exit 1" "$rc" "1"; has "reboot: WARN" "$out" '^WARN +reboot +required'

run '.apps[0].status = "exited:unhealthy"'
check "app exited: exit 1" "$rc" "1"; has "app exited: FAIL" "$out" '^FAIL +app starter +exited:unhealthy'
run '.deploys.a1.deployments[0].status = "failed"'
check "deploy failed: exit 1" "$rc" "1"; has "deploy failed: FAIL" "$out" '^FAIL +app starter +running:healthy, last deploy: failed'
run 'del(.deploys)'
check "deployments API missing: exit 0" "$rc" "0"; has "deployments API missing: n/a" "$out" '^OK +app starter .*last deploy: n/a'

FAKE_CERT_DAYS=10 run .;   check "cert 10d: exit 1" "$rc" "1"; has "cert 10d: WARN" "$out" '^WARN +cert app\.example\.test +expires in (9|10) days'
FAKE_CERT_DAYS=2 run .;    check "cert 2d: exit 1" "$rc" "1"; has "cert 2d: FAIL" "$out" '^FAIL +cert app\.example\.test +expires in (1|2) days'
FAKE_CERT_DAYS=fail run .; check "cert unreachable: exit 1" "$rc" "1"; has "cert unreachable: FAIL" "$out" '^FAIL +cert app\.example\.test +unreachable'

# shellcheck disable=SC2016 # $t is a jq variable
run '.execs.b1.executions[0] |= (.created_at = $t | .finished_at = $t)' --arg t "$(ago 30)"
check "backup 30h: exit 1" "$rc" "1"; has "backup 30h: WARN" "$out" '^WARN +backup starter-db +last success 30h ago'
run '.execs.b1.executions = []'
check "backup none: exit 1" "$rc" "1"; has "backup none: FAIL" "$out" '^FAIL +backup starter-db +no backup has run'
run '.backups.d1 = []'
check "no schedule: exit 1" "$rc" "1"; has "no schedule: FAIL" "$out" '^FAIL +backup starter-db +no backup schedule'
# shellcheck disable=SC2016 # $t is a jq variable
run '.execs.b1.executions += [{status: "failed", created_at: $t, finished_at: $t}]' --arg t "$(ago 1)"
check "backup failed: exit 1" "$rc" "1"; has "backup failed: FAIL" "$out" '^FAIL +backup starter-db +last backup failed'
run 'del(.backups)'
check "backup API missing: exit 1" "$rc" "1"; has "backup API missing: n/a" "$out" '^WARN +backup starter-db +n/a'

run 'del(.latest)'
check "latest unreachable: exit 0" "$rc" "0"; has "latest unreachable: unknown" "$out" '^OK +version +4\.3\.23 \(latest unknown\)'
run '.latest.tag_name = "v4.3.30"'
check "older version: exit 0" "$rc" "0"; has "older version: shows latest" "$out" '^OK +version +4\.3\.23 \(latest release 4\.3\.30\)'

FAKE_SSH_RC=255 run .
check "ssh down: exit 2" "$rc" "2"; has "ssh down: FAIL" "$out" '^FAIL +ssh +server unreachable'
has "ssh down: still checks apps" "$out" '^OK +app starter'
run 'del(.version)'
check "API down: exit 2" "$rc" "2"; has "API down: FAIL" "$out" '^FAIL +api '
has "API down: still checks server" "$out" '^OK +disk / '

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
