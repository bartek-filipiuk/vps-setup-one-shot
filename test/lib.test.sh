#!/usr/bin/env bash
# Self-check for lib.sh and verify.sh against a fake Coolify API. No server, no network.
# Run from the repo root: bash test/lib.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
REAL_HOME=$HOME
export HOME; HOME=$(mktemp -d)
export GH_CONFIG_DIR="$REAL_HOME/.config/gh"
export DEPLOY_POLL_SECONDS=0
PORT=$((20000 + RANDOM % 10000))
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fails=$((fails + 1)); fi; }

python3 - "$PORT" <<'EOF' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
polls = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer 3|abc=def":
            return self.send(401, {"message": "Unauthenticated."})
        p = self.path.removeprefix("/api/v1")
        if p == "/version": return self.send(200, "4.0.0-test")
        if p == "/bad": return self.send(422, {"message": "Validation failed"})
        if p.startswith("/deploy?uuid="):
            return self.send(405, {"message": "This endpoint has changed to a POST request."})
        if p.startswith("/deployments/"):
            d = p.split("/")[2]; polls[d] = polls.get(d, 0) + 1
            if polls[d] < 3: return self.send(200, {"status": "in_progress"})
            if d == "d-good": return self.send(200, {"status": "finished"})
            logs = [{"output": "step 1", "hidden": False}, {"output": "secret internals", "hidden": True},
                    {"output": "npm ERR! missing script: build", "hidden": False}]
            return self.send(200, {"status": "failed", "logs": json.dumps(logs)})
        self.send(404, {"message": "not found"})
    def do_POST(self):
        p = self.path.removeprefix("/api/v1")
        if p.startswith("/deploy?uuid="):
            return self.send(200, {"deployments": [{"deployment_uuid": "d-" + p.split("=")[1]}]})
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send(201, {"echo": json.loads(body)})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$HOME"' EXIT
sleep 1

. ./lib.sh

# state: create, overwrite, values with | / = survive, file is private
state_set A 1; state_set B 'x|y/z=w'; state_set A 2
check "state overwrite" "$(state_get A)" "2"
check "state special chars" "$(state_get B)" "x|y/z=w"
check "state single entry per key" "$(grep -c '^A=' "$VPS_STATE")" "1"
check "state file mode" "$(stat -c %a "$VPS_STATE" 2>/dev/null || stat -f %Lp "$VPS_STATE")" "600"

# capi: missing config fails, token with | works, HTTP errors fail loudly
capi GET /version >/dev/null 2>&1; check "capi without config fails" "$?" "1"
mkdir -p "$HOME/.config/coolify"
printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=3|abc=def\n' "$PORT" > "$COOLIFY_CONFIG"
check "capi with pipe token" "$(capi GET /version)" '"4.0.0-test"'
check "capi POST body via stdin" "$(capi POST /x '{"k":"a b|c"}' | jq -r .echo.k)" "a b|c"
err=$(capi GET /bad 2>&1 >/dev/null); rc=$?
check "capi 422 returns 1" "$rc" "1"
case "$err" in *"HTTP 422"*"Validation failed"*) check "capi 422 message" ok ok ;; *) check "capi 422 message" "$err" "HTTP 422 ...";; esac

# phase 04: server uuid written into the coolify config (token kept, private, no duplicates)
( VPS_STATE=$COOLIFY_CONFIG; state_set COOLIFY_SERVER_UUID s1; state_set COOLIFY_SERVER_UUID s2 )
check "config keeps token" "$(coolify_get COOLIFY_TOKEN)" "3|abc=def"
check "config server uuid replaced" "$(grep -c '^COOLIFY_SERVER_UUID=' "$COOLIFY_CONFIG"):$(coolify_get COOLIFY_SERVER_UUID)" "1:s2"
check "config mode" "$(stat -c %a "$COOLIFY_CONFIG" 2>/dev/null || stat -f %Lp "$COOLIFY_CONFIG")" "600"

# PREPARE-APP secret upload loop: comments and blanks skipped, '=' and spaces kept in values
printf '# comment\n\nAPI_KEY=a=b c\nSMTP_PASS=x|y\n' > "$HOME/.env.production"
got=$(grep -Ev '^[[:space:]]*(#|$)' "$HOME/.env.production" | while IFS='=' read -r k v; do
  capi POST "/applications/A/envs" "$(jq -n --arg k "$k" --arg v "$v" '{key:$k, value:$v, is_preview:false}')" | jq -r '.echo | "\(.key)=\(.value)"'
done | paste -sd ';' -)
check "env upload loop" "$got" "API_KEY=a=b c;SMTP_PASS=x|y"

# deploy_and_wait: success, and failure with visible logs only
out=$(deploy_and_wait good 2>&1); rc=$?
check "deploy success rc" "$rc" "0"
out=$(deploy_and_wait bad 2>&1); rc=$?
check "deploy failure rc" "$rc" "1"
case "$out" in *"missing script: build"*) check "failure shows log" ok ok ;; *) check "failure shows log" "$out" "log tail";; esac
case "$out" in *"secret internals"*) check "hidden lines skipped" shown hidden ;; *) check "hidden lines skipped" ok ok ;; esac

# verify.sh picks the right phase
mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/id_ed25519.pub"
out=$("$REPO/verify.sh" 2>&1 | tail -1)
check "verify: no answers -> 00" "$out" "NEXT: phases/00-preflight.md"
for k in DOMAIN COOLIFY_DOMAIN APP_DOMAIN APP_NAME SSH_PUBKEY SETUP_DIR; do state_set "$k" example.invalid; done
state_set PROVIDER other
out=$("$REPO/verify.sh" 2>&1 | tail -1)
check "verify: answers, no server -> 01" "$out" "NEXT: phases/01-server.md"

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
