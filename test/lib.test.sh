#!/usr/bin/env bash
# Self-check for lib.sh and verify.sh against a fake Coolify API. No server, no network.
# Run from the repo root: bash test/lib.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
export HOME; HOME=$(mktemp -d)
export DEPLOY_POLL_SECONDS=0
PORT=$((20000 + RANDOM % 10000))
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fails=$((fails + 1)); fi; }
# has NAME OUTPUT REGEX: OUTPUT has a line matching REGEX
has() { if grep -qE "$3" <<<"$2"; then echo "ok   $1"; else echo "FAIL $1: no line matching [$3] in:"; echo "     ${2//$'\n'/$'\n'     }"; fails=$((fails + 1)); fi; }

python3 - "$PORT" "$HOME/seq.log" <<'EOF' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
polls = {}
SHA = "e4d273e858b3da0acefd09f4724d2073f3d5fab0"
def seq(line):
    with open(sys.argv[2], "a") as f: f.write(line + "\n")
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
        if p == "/slow":
            time.sleep(3)
            try: return self.send(200, "late")
            except OSError: return
        if p.startswith("/deploy?uuid="):
            return self.send(405, {"message": "This endpoint has changed to a POST request."})
        if p.startswith("/deployments/applications/"):
            a = p.split("/")[3]
            if a == "first": return self.send(200, {"count": 0, "deployments": []})
            return self.send(200, {"count": 2, "deployments": [
                {"deployment_uuid": "d-old2", "status": "failed", "commit": "ffffffffffffffffffffffffffffffffffffffff"},
                {"deployment_uuid": "d-old1", "status": "finished", "commit": SHA}]})
        if p.endswith("/rollback-images"):
            a = p.split("/")[2]
            imgs = [{"tag": SHA, "created_at": "2026-10-13 17:52:17 +0200 CEST", "is_current": False}] if a == "good" else []
            return self.send(200, {"current": None, "images": imgs})
        if p == "/databases/db-pg":
            return self.send(200, {"uuid": "db-pg", "database_type": "standalone-postgresql", "image": "postgres:17-alpine",
                                   "postgres_user": "app", "postgres_db": "app", "postgres_password": "pw-SECRET-123"})
        if p == "/databases/db-redis":
            return self.send(200, {"uuid": "db-redis", "database_type": "standalone-redis", "image": "redis:7.2"})
        if p.startswith("/deployments/"):
            d = p.split("/")[2]; polls[d] = polls.get(d, 0) + 1
            if polls[d] < 3: return self.send(200, {"status": "in_progress"})
            if d in ("d-good", "d-first"): return self.send(200, {"status": "finished"})
            logs = [{"output": "step 1", "hidden": False}, {"output": "secret internals", "hidden": True},
                    {"output": "npm ERR! missing script: build", "hidden": False}]
            return self.send(200, {"status": "failed", "logs": json.dumps(logs)})
        self.send(404, {"message": "not found"})
    def do_POST(self):
        p = self.path.removeprefix("/api/v1")
        if p.startswith("/deploy?uuid="):
            seq("deploy " + p.split("=")[1])
            return self.send(200, {"deployments": [{"deployment_uuid": "d-" + p.split("=")[1]}]})
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if p.endswith("/rollback"):
            seq("rollback " + p.split("/")[2] + " " + json.loads(body)["commit"])
            return self.send(200, {"message": "Rollback deployment queued.", "deployment_uuid": "d-good"})
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
start=$SECONDS; CAPI_MAX_TIME=1 capi GET /slow >/dev/null 2>&1; rc=$?
check "capi CAPI_MAX_TIME gives up" "$rc:$((SECONDS - start < 3))" "1:1"

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

# deploy_and_wait: rollback point, dump over a stubbed ssh, deploy, rollback instructions.
# The ssh stub logs the remote command and its stdin; SSH_STUB_FAIL=1 makes it fail like a dead server.
mkdir -p "$HOME/bin"
cat > "$HOME/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/ssh.args"; cat > "$HOME/ssh.stdin"
echo ssh >> "$HOME/seq.log"
[ "${SSH_STUB_FAIL:-0}" = 1 ] && { echo "ssh: connect to host 203.0.113.9 port 22: Connection refused" >&2; exit 255; }
grep -q pg_dump "$HOME/ssh.stdin" && echo "/root/db-dumps/db-pg/20261014T120000Z.dump 4096"
grep -q pg_restore "$HOME/ssh.stdin" && echo "restored"
exit 0
STUB
chmod +x "$HOME/bin/ssh"
PATH="$HOME/bin:$PATH"; export PATH
state_set VPS_IP 203.0.113.9
SHA=e4d273e858b3da0acefd09f4724d2073f3d5fab0

# success with a Postgres database: dump before deploy, rollback point and commands printed
state_set DB_UUID db-pg; : > "$HOME/seq.log"
out=$(deploy_and_wait good 2>&1); rc=$?
check "deploy success rc" "$rc" "0"
has "deploy prints rollback point" "$out" "^rollback point: commit $SHA \(image on the server\)$"
has "deploy prints dump path" "$out" "^database dump: /root/db-dumps/db-pg/20261014T120000Z.dump$"
check "dump runs before the deploy" "$(paste -sd ' ' "$HOME/seq.log")" "ssh deploy good"
case "$(cat "$HOME/ssh.args")" in *"root@203.0.113.9 sh -s -- db-pg app app 10"*) check "dump ssh command" ok ok ;; *) check "dump ssh command" "$(cat "$HOME/ssh.args")" "... root@203.0.113.9 sh -s -- db-pg app app 10" ;; esac
grep -qF "pg_dump -U \"\$2\" -d \"\$3\" -Fc" "$HOME/ssh.stdin"; check "dump script uses pg_dump custom format" "$?" "0"
has "success prints rollback command" "$out" "^  \. \./lib\.sh; rollback_and_wait good $SHA$"
has "success prints restore command" "$out" "^  only if a migration broke the data: db_restore db-pg /root/db-dumps/db-pg/20261014T120000Z.dump$"
check "state records rollback point and dump" "$(state_get ROLLBACK_COMMIT):$(state_get LAST_DUMP)" "$SHA:/root/db-dumps/db-pg/20261014T120000Z.dump"
case "$out$(cat "$HOME/ssh.args" "$HOME/ssh.stdin")" in *SECRET*|*"abc=def"*) check "no secrets in deploy output or ssh command" leaked none ;; *) check "no secrets in deploy output or ssh command" ok ok ;; esac

# dump failure aborts before the deploy; DEPLOY_SKIP_DUMP=1 is the explicit way around it
: > "$HOME/seq.log"
out=$(SSH_STUB_FAIL=1 deploy_and_wait good 2>&1); rc=$?
check "dump failure rc" "$rc" "1"
has "dump failure says nothing deployed" "$out" "database dump failed; nothing was deployed"
check "dump failure: no deploy call" "$(paste -sd ' ' "$HOME/seq.log")" "ssh"
: > "$HOME/seq.log"
out=$(SSH_STUB_FAIL=1 DEPLOY_SKIP_DUMP=1 deploy_and_wait good 2>&1); rc=$?
check "skip dump rc" "$rc" "0"
has "skip dump is said" "$out" "^database dump: skipped \(DEPLOY_SKIP_DUMP=1\)$"
check "skip dump: no ssh" "$(paste -sd ' ' "$HOME/seq.log")" "deploy good"

# only Postgres can be dumped; a Redis DB_UUID is refused before anything deploys
state_set DB_UUID db-redis; : > "$HOME/seq.log"
out=$(deploy_and_wait good 2>&1); rc=$?
check "redis dump refused rc" "$rc" "1"
has "redis dump refused message" "$out" "only standalone-postgresql is supported"
check "redis: no ssh, no deploy" "$(cat "$HOME/seq.log")" ""

# no database in the state: deploy goes ahead and says so
sed -i '/^DB_UUID=/d' "$VPS_SETUP_STATE"; : > "$HOME/seq.log"
out=$(deploy_and_wait good 2>&1); rc=$?
check "no DB_UUID rc" "$rc" "0"
has "no DB_UUID is said" "$out" "^database dump: none \(no DB_UUID in "
check "no DB_UUID: no ssh" "$(paste -sd ' ' "$HOME/seq.log")" "deploy good"

# first deploy ever: no rollback point, no rollback command
out=$(deploy_and_wait first 2>&1); rc=$?
check "first deploy rc" "$rc" "0"
has "first deploy: no rollback point" "$out" "^rollback point: none \(no finished deployment yet\)$"
case "$out" in *rollback_and_wait*) check "first deploy: no rollback command" shown none ;; *) check "first deploy: no rollback command" ok ok ;; esac

# failure: visible logs only, image gone from the server, rollback instructions
state_set DB_UUID db-pg
out=$(deploy_and_wait bad 2>&1); rc=$?
check "deploy failure rc" "$rc" "1"
case "$out" in *"missing script: build"*) check "failure shows log" ok ok ;; *) check "failure shows log" "$out" "log tail";; esac
case "$out" in *"secret internals"*) check "hidden lines skipped" shown hidden ;; *) check "hidden lines skipped" ok ok ;; esac
has "failure: image not on server noted" "$out" "^rollback point: commit $SHA \(image not on the server; a rollback rebuilds it\)$"
has "failure prints rollback command" "$out" "^Deployment d-bad failed\. Back to the previous version \(ROLLBACK\.md\):$"
has "failure prints rollback_and_wait" "$out" "^  \. \./lib\.sh; rollback_and_wait bad $SHA$"
has "failure prints db_restore" "$out" "^  only if a migration broke the data: db_restore db-pg /root/db-dumps/db-pg/20261014T120000Z.dump$"

# rollback_and_wait posts the commit and waits; db_restore runs pg_restore on the given dump
: > "$HOME/seq.log"
out=$(rollback_and_wait good "$SHA" 2>&1); rc=$?
check "rollback rc" "$rc" "0"
has "rollback queued" "$out" "^rollback deployment d-good queued \(to commit $SHA\)$"
check "rollback posts the commit" "$(cat "$HOME/seq.log")" "rollback good $SHA"
out=$(db_restore db-pg /root/db-dumps/db-pg/20261014T120000Z.dump 2>&1); rc=$?
check "restore rc:output" "$rc:$out" "0:restored"
case "$(cat "$HOME/ssh.args")" in *"sh -s -- db-pg app app /root/db-dumps/db-pg/20261014T120000Z.dump"*) check "restore ssh command" ok ok ;; *) check "restore ssh command" "$(cat "$HOME/ssh.args")" "... sh -s -- db-pg app app /root/...dump" ;; esac
grep -qF "pg_restore -U \"\$2\" -d \"\$3\" --single-transaction --clean --if-exists" "$HOME/ssh.stdin"; check "restore script is all or nothing" "$?" "0"
sed -i '/^VPS_IP=/d; /^DB_UUID=/d; /^ROLLBACK_COMMIT=/d; /^LAST_DUMP=/d' "$VPS_SETUP_STATE"

# verify.sh picks the right phase
mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/id_ed25519.pub"
# Stub gh so the check does not depend on this machine's (or CI's) gh login.
# GH_STUB_LOGGED_IN=0 makes `gh auth status` fail.
mkdir -p "$HOME/bin"
cat > "$HOME/bin/gh" <<'STUB'
#!/bin/sh
[ "$1 $2" = "auth status" ] && [ "${GH_STUB_LOGGED_IN:-1}" = 0 ] && exit 1
exit 0
STUB
chmod +x "$HOME/bin/gh"
out=$(PATH="$HOME/bin:$PATH" "$REPO/verify.sh" 2>&1 | tail -1)
check "verify: no answers -> 00" "$out" "NEXT: phases/00-preflight.md"
for k in DOMAIN COOLIFY_DOMAIN APP_DOMAIN APP_NAME SSH_PUBKEY SETUP_DIR; do state_set "$k" example.invalid; done
state_set PROVIDER other
out=$(PATH="$HOME/bin:$PATH" "$REPO/verify.sh" 2>&1 | tail -1)
check "verify: answers, no server -> 01" "$out" "NEXT: phases/01-server.md"
out=$(GH_STUB_LOGGED_IN=0 PATH="$HOME/bin:$PATH" "$REPO/verify.sh" 2>&1)
case "$out" in *"gh not logged in"*"NEXT: phases/00-preflight.md") check "verify: gh not logged in -> 00" ok ok ;;
  *) check "verify: gh not logged in -> 00" "$(echo "$out" | tail -3)" "gh not logged in ... NEXT: phases/00-preflight.md" ;; esac

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
