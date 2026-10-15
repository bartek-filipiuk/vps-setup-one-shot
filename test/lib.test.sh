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
S3_KEY, S3_SECRET = "AKFAKEKEY123", "s3SeCrEt/x+y=z|w"
storages = {}          # uuid -> storage, without key and secret (as the real API answers)
schedules = {"db-pg": [{"uuid": "bk1", "enabled": True, "frequency": "0 2 * * *", "save_s3": True}], "db-new": []}
execs = {}             # backup uuid -> executions
FINAL = {              # what a backup_now run of each schedule ends as
    "bk1": {"status": "success", "message": "Backup done", "s3_uploaded": True},
    "bk-warn": {"status": "success", "message": "Backup done. Warning: S3 upload failed: Access Denied"},
    "bk-msg": {"status": "success", "message": "Backup done"},
    "bk-fail": {"status": "failed", "message": "pg_dump: error: connection refused"},
}
WEBHOOK = "https://discord.com/api/webhooks/1/wh-SECRET-abc"
EVENTS = ["backup_failure", "backup_success", "deployment_failure", "deployment_success", "docker_cleanup_failure",
          "docker_cleanup_success", "restart_limit_reached", "scheduled_task_failure", "scheduled_task_success",
          "server_disk_usage", "server_patch", "server_reachable", "server_unreachable", "status_change", "traefik_outdated"]
# services as the live 4.3.23 GET answers (fields trimmed)
SERVICES = {"svc-umami": {"uuid": "svc-umami", "name": "umami", "service_type": "umami", "status": "running:healthy",
    "applications": [{"uuid": "sa1", "name": "umami", "human_name": None, "fqdn": "https://stats.example.com", "status": "running:healthy",
                      "image": "ghcr.io/umami-software/umami:postgresql-latest", "restart_limit_reached": False}],
    "databases": [{"uuid": "sd1", "name": "postgresql", "image": "postgres:16-alpine", "status": "running:healthy", "is_public": False}]},
  "svc-kuma": {"uuid": "svc-kuma", "name": "uptime-kuma", "service_type": "uptime-kuma", "status": "exited",
    "applications": [{"uuid": "sa2", "name": "uptime-kuma", "fqdn": "https://up.example.com", "status": "exited", "restart_limit_reached": True}],
    "databases": []}}
# Discord settings as the live GET answers (no URL in it); PATCH accepts only these keys plus the URL.
notif = {"id": 1, "team_id": 0, "discord_enabled": False, "discord_ping_enabled": False} | {e + "_discord_notifications": False for e in EVENTS}
def seq(line):
    with open(sys.argv[2], "a") as f: f.write(line + "\n")
def executions(b):
    if b not in execs:
        execs[b] = [{"uuid": "ex-old-" + b, "status": "success", "created_at": "2026-10-13T12:08:10+00:00", "finished_at": None,
                     "filename": "/data/coolify/backups/databases/old.dmp", "message": "Backup done", "size": 1000, "s3_uploaded": True}]
    for e in execs[b]:
        if "_final" in e:
            e["_polls"] += 1
            if e["_polls"] >= 2: e.update(e.pop("_final")); e.pop("_polls")
    return [{k: v for k, v in e.items() if not k.startswith("_")} for e in execs[b]]
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
            return self.send(200, {"count": 3, "deployments": [
                {"deployment_uuid": "d-pr", "status": "finished", "commit": "1111111111111111111111111111111111111111", "pull_request_id": 7},
                {"deployment_uuid": "d-old2", "status": "failed", "commit": "ffffffffffffffffffffffffffffffffffffffff", "pull_request_id": 0},
                {"deployment_uuid": "d-old1", "status": "finished", "commit": SHA, "pull_request_id": 0}]})
        if p.startswith("/applications/") and "/logs" in p:
            a, q = p.split("/")[2], p.partition("?")[2]
            seq("logs %s %s" % (a, q))
            if a == "stopped-app": return self.send(400, {"message": "Application is not running."})
            return self.send(200, {"logs": "2026-10-14T10:00:00Z ready on :::3000\nGET /api/health 200\n  stack line \"quoted\""})
        if p.startswith("/applications/") and p.count("/") == 2:
            a = p.split("/")[2]
            return self.send(200, {"uuid": a, "status": "exited:unhealthy" if a == "stopped-app" else "running:healthy"})
        if p.endswith("/rollback-images"):
            a = p.split("/")[2]
            imgs = [{"tag": SHA, "created_at": "2026-10-13 17:52:17 +0200 CEST", "is_current": False}] if a == "good" else []
            return self.send(200, {"current": None, "images": imgs})
        if p == "/databases/db-pg":
            return self.send(200, {"uuid": "db-pg", "name": "starter-db", "database_type": "standalone-postgresql", "image": "postgres:17-alpine",
                                   "postgres_user": "app", "postgres_db": "app", "postgres_password": "pw-SECRET-123"})
        if p.startswith("/databases/db-pg1") or p == "/databases/db-latest":   # db-pg16, db-pg18 (R14), image by name
            u = p.split("/")[2]
            return self.send(200, {"uuid": u, "name": u + "-db", "database_type": "standalone-postgresql",
                                   "image": "postgres:latest" if u == "db-latest" else "postgres:%s-alpine" % u[5:],
                                   "postgres_user": "app", "postgres_db": "app", "postgres_password": "pw-SECRET-123"})
        if p == "/databases/db-redis":
            return self.send(200, {"uuid": "db-redis", "database_type": "standalone-redis", "image": "redis:7.2"})
        if p == "/s3-storages": return self.send(200, list(storages.values()))
        if p == "/team/members":   # as the live GET: users without a role field
            return self.send(200, [
                {"id": 0, "name": "Dev Root", "email": "dev@example.invalid", "email_verified_at": "2026-10-09T10:00:00.000000Z",
                 "two_factor_confirmed_at": "2026-10-09T10:05:00.000000Z", "created_at": "2026-10-09T10:00:00.000000Z"},
                {"id": 3, "name": "Client Owner", "email": "client@example.invalid", "email_verified_at": None,
                 "two_factor_confirmed_at": None, "created_at": "2026-10-15T09:00:00.000000Z"}])
        if p == "/security/keys":  # a root token also gets private_key
            return self.send(200, [
                {"id": 1, "uuid": "key-local", "name": "localhost's key", "fingerprint": "SHA256:fakeFingerprintLocal",
                 "public_key": "ssh-ed25519 AAAAPUBLICKEYMATERIALxyz root@coolify",
                 "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\nPRIVATEKEYMATERIALabc\n-----END OPENSSH PRIVATE KEY-----",
                 "is_git_related": False, "team_id": 0},
                {"id": 2, "uuid": "key-gh", "name": "app-deploy", "fingerprint": "SHA256:fakeFingerprintDeploy",
                 "public_key": "ssh-ed25519 AAAAPUBLICKEYMATERIALdef coolify-app",
                 "private_key": "PRIVATEKEYMATERIALdef", "is_git_related": True, "team_id": 0}])
        if p == "/notifications/discord": return self.send(200, notif)
        if p == "/services": return self.send(200, list(SERVICES.values()))
        if p.startswith("/services/"):
            u = p.split("/")[2]
            return self.send(200, SERVICES[u]) if u in SERVICES else self.send(404, {"message": "Service not found."})
        if p.startswith("/s3-storages/"): return self.send(200, storages[p.split("/")[2]])
        if p.startswith("/databases/") and p.endswith("/backups"):
            return self.send(200, schedules.get(p.split("/")[2], []))
        if p.startswith("/databases/") and p.endswith("/executions"):
            return self.send(200, {"executions": executions(p.split("/")[4])})
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
        if p == "/s3-storages":
            b = json.loads(body); u = "s3-%d" % (len(storages) + 1)
            storages[u] = {k: b.get(k) for k in ("name", "description", "endpoint", "bucket", "region", "is_usable")} | {"uuid": u}
            seq("s3 POST %s %s %s %s creds=%s" % (b["name"], b["endpoint"], b["bucket"], b["region"],
                "ok" if (b.get("key"), b.get("secret")) == (S3_KEY, S3_SECRET) else "bad"))
            return self.send(201, {"uuid": u})
        if p.startswith("/s3-storages/") and p.endswith("/validate"):
            st = storages[p.split("/")[2]]
            if st["bucket"] == "wrong-bucket": return self.send(200, {"valid": False, "message": "The specified bucket does not exist"})
            return self.send(200, {"valid": True, "message": "S3 storage connection is valid."})
        if p.startswith("/databases/") and p.endswith("/backups"):
            d = p.split("/")[2]; seq("backup POST %s %s" % (d, json.dumps(json.loads(body), sort_keys=True, separators=(",", ":"))))
            schedules.setdefault(d, []).append({"uuid": "bk-new", "enabled": True, "frequency": json.loads(body)["frequency"], "save_s3": True})
            return self.send(201, {"uuid": "bk-new", "message": "Backup configuration created successfully."})
        if p == "/services":
            b = json.loads(body); seq("service POST %s" % json.dumps(b, sort_keys=True, separators=(",", ":")))
            url = b["urls"][0]["url"]
            if "taken.example.com" in url:   # shape from the 4.3.23 source
                return self.send(409, {"message": "Domain conflicts detected. Use force_domain_override=true to proceed.",
                    "conflicts": [{"domain": "taken.example.com", "resource_name": "starter", "resource_uuid": "a1",
                                   "resource_type": "application", "message": "Domain taken.example.com is already in use by application 'starter'"}]})
            if "invalid.example.com" in url:
                return self.send(422, {"message": "Validation failed.", "errors": {"urls.0.name": ["Service 'x' does not exist in the compose file."]}})
            return self.send(201, {"uuid": "svc-new", "domains": [url]})
        if p.endswith("/rollback"):
            seq("rollback " + p.split("/")[2] + " " + json.loads(body)["commit"])
            return self.send(200, {"message": "Rollback deployment queued.", "deployment_uuid": "d-good"})
        self.send(201, {"echo": json.loads(body)})
    def do_PATCH(self):
        p = self.path.removeprefix("/api/v1")
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if p == "/notifications/discord":
            bad = [k for k in b if k not in notif and k != "discord_webhook_url" or k in ("id", "team_id")]
            if bad: return self.send(422, {"message": "Validation failed.", "errors": {k: ["This field is not allowed."] for k in bad}})
            u = b.get("discord_webhook_url")
            if u and "localhost" in u:
                return self.send(422, {"message": "Validation failed.", "errors": {"discord_webhook_url": ["The URL %s points to a private address." % u]}})
            rest = {k: v for k, v in b.items() if k != "discord_webhook_url"}
            notif.update(rest)
            seq("notify PATCH discord %s url=%s" % (json.dumps(rest, sort_keys=True, separators=(",", ":")),
                "ok" if u == WEBHOOK else "absent" if u is None else "other"))
            # with a read:sensitive token the response carries the URL: the lib must never print it
            return self.send(200, {"message": "Notification settings updated.", "data": notif | {"discord_webhook_url": u}})
        if p.startswith("/s3-storages/"):
            u = p.split("/")[2]; storages[u].update({k: v for k, v in b.items() if k not in ("key", "secret")})
            seq("s3 PATCH %s creds=%s" % (u, "ok" if (b.get("key"), b.get("secret")) == (S3_KEY, S3_SECRET) else "bad"))
            return self.send(200, {"uuid": u})
        if p.startswith("/databases/") and "/backups/" in p:
            d, bk = p.split("/")[2], p.split("/")[4]
            if b == {"backup_now": True}:
                seq("backup PATCH %s %s backup_now" % (d, bk))
                if bk in FINAL:
                    n = len(executions(bk))
                    execs[bk].append({"uuid": "ex-new-%d" % n, "status": "running", "created_at": "2026-10-14T10:00:0%d+00:00" % n,
                        "finished_at": None, "filename": "/data/coolify/backups/databases/root/%s/pg-dump-app-176000000%d.dmp" % (d, n),
                        "size": 2048, "message": None, "_polls": 0, "_final": FINAL[bk]})
                return self.send(200, {"message": "Backup updated."})
            seq("backup PATCH %s %s %s" % (d, bk, json.dumps(b, sort_keys=True, separators=(",", ":"))))
            return self.send(200, {"message": "Backup updated."})
        self.send(404, {"message": "not found"})
    def do_DELETE(self):
        p = self.path.removeprefix("/api/v1")
        seq("DELETE " + p)
        if p.startswith("/services/"): return self.send(200, {"message": "Deletion request queued."})
        self.send(404, {"message": "not found"})
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
# The ssh stub logs the remote command and runs it locally with `sh` (as rssh would on the server)
# with a fake docker on PATH; SSH_STUB_FAIL=1 makes it fail like a dead server. Dumps land in
# $HOME/dumps (DUMP_DIR) instead of /root/db-dumps.
mkdir -p "$HOME/bin" "$HOME/fakebin"
cat > "$HOME/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/ssh.args"; cat > "$HOME/ssh.stdin"
echo ssh >> "$HOME/seq.log"
[ "${SSH_STUB_FAIL:-0}" = 1 ] && { echo "ssh: connect to host 203.0.113.9 port 22: Connection refused" >&2; exit 255; }
cmd=${*#*root@203.0.113.9 }
PATH="$HOME/fakebin:$PATH" sh -c "$cmd" < "$HOME/ssh.stdin"
STUB
cat > "$HOME/fakebin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >> "$HOME/docker.log"
case "$*" in
  "run --rm --env-file "*)
    # mc in a container: $4 env file, $6 DIR:/out, $9 image, ${12} source, ${13} /out/NAME
    want="MC_HOST_s3=https://AKFAKEKEY123:s3SeCrEt%2Fx%2By%3Dz%7Cw@fsn1.your-objectstorage.com"
    if [ "$(cat "$4")" = "$want" ]; then echo "envfile ok $(stat -c %a "$4")" >> "$HOME/envcheck.log"; else echo "envfile bad" >> "$HOME/envcheck.log"; fi
    [ "${FAKE_MC_FAIL:-0}" = 1 ] && { echo "mc: <ERROR> Object does not exist." >&2; exit 1; }
    printf 'PGDMP fake object %s\n' "${12}" > "${6%:/out}/${13#/out/}" ;;
  "images "*) [ "${FAKE_NO_HELPER:-0}" = 1 ] || printf '%s\n' ghcr.io/coollabsio/coolify-helper:1.0.9 ghcr.io/coollabsio/coolify-helper:1.0.17 ;;
  "ps -q -f name="*) [ "${FAKE_NO_CONTAINER:-0}" = 1 ] || echo cid ;;
  *pg_database_size*) echo "${FAKE_DB_SIZE:-4096}" ;;
  *" pg_dump "*) [ "${FAKE_PG_DUMP_FAIL:-0}" = 1 ] && exit 1; [ "${FAKE_PG_DUMP_EMPTY:-0}" = 1 ] && exit 0; printf 'PGDMP fake dump: %s\n' "$*" ;;
  *pg_restore*) cat >/dev/null; [ "${FAKE_PG_RESTORE_FAIL:-0}" = 1 ] && { echo "pg_restore: error: fake" >&2; exit 1; }; echo "pg_restore done" ;;
  *"drop schema public"*) echo "wiped" ;;
  *) echo "fake docker: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$HOME/bin/ssh" "$HOME/fakebin/docker"
PATH="$HOME/bin:$PATH"; export PATH
state_set VPS_IP 203.0.113.9
DUMP_DIR=$HOME/dumps
SHA=e4d273e858b3da0acefd09f4724d2073f3d5fab0
DUMPRE="$HOME/dumps/db-pg/[0-9]{8}T[0-9]{6}Z\.dump"

# success with a Postgres database: dump before deploy, rollback point and commands printed
state_set DB_UUID db-pg; : > "$HOME/seq.log"; : > "$HOME/docker.log"
out=$(deploy_and_wait good 2>&1); rc=$?
check "deploy success rc" "$rc" "0"
has "deploy prints rollback point" "$out" "^rollback point: commit $SHA \(image on the server\)$"
has "deploy prints dump path" "$out" "^database dump: $DUMPRE$"
check "dump runs before the deploy" "$(paste -sd ' ' "$HOME/seq.log")" "ssh deploy good"
case "$(cat "$HOME/ssh.args")" in *"root@203.0.113.9 sh -s -- db-pg app app 10 $HOME/dumps"*) check "dump ssh command" ok ok ;; *) check "dump ssh command" "$(cat "$HOME/ssh.args")" "... root@203.0.113.9 sh -s -- db-pg app app 10 $HOME/dumps" ;; esac
has "dump: exact container match" "$(cat "$HOME/docker.log")" '^docker ps -q -f name=\^/\?db-pg\$$'
has "dump: size checked before pg_dump" "$(paste -sd ' ' "$HOME/docker.log")" "pg_database_size.*pg_dump -U app -d app -Fc"
d1=$(state_get LAST_DUMP)
check "dump file exists with content" "$(test -s "$d1" && echo yes)" "yes"
check "dump file mode 600, dir 700" "$(stat -c %a "$d1"):$(stat -c %a "$HOME/dumps/db-pg"):$(stat -c %a "$HOME/dumps")" "600:700:700"
has "success prints rollback command" "$out" "^  \. \./lib\.sh; rollback_and_wait good $SHA$"
has "success prints restore command" "$out" "^  only if a migration broke the data: db_restore db-pg $DUMPRE$"
check "state records rollback point" "$(state_get ROLLBACK_COMMIT)" "$SHA"
case "$out$(cat "$HOME/ssh.args" "$HOME/ssh.stdin")" in *SECRET*|*"abc=def"*) check "no secrets in deploy output or ssh command" leaked none ;; *) check "no secrets in deploy output or ssh command" ok ok ;; esac

# dump failure aborts before the deploy (dead server, pg_dump error, empty dump, no container, full disk)
: > "$HOME/seq.log"
out=$(SSH_STUB_FAIL=1 deploy_and_wait good 2>&1); rc=$?
check "dump failure rc" "$rc" "1"
has "dump failure says nothing deployed" "$out" "database dump failed; nothing was deployed"
check "dump failure: no deploy call" "$(paste -sd ' ' "$HOME/seq.log")" "ssh"
sleep 1; out=$(FAKE_PG_DUMP_FAIL=1 db_dump db-pg 2>&1); rc=$?
check "pg_dump error rc" "$rc" "1"; has "pg_dump error message" "$out" "^pg_dump failed for database db-pg$"
sleep 1; out=$(FAKE_PG_DUMP_EMPTY=1 db_dump db-pg 2>&1); rc=$?
check "empty dump rc" "$rc" "1"
check "failed dumps leave no file behind" "$(find "$HOME/dumps/db-pg" -name '*.dump' | wc -l)" "1"
out=$(FAKE_NO_CONTAINER=1 db_dump db-pg 2>&1); rc=$?
check "no container rc:msg" "$rc:$out" "1:no running container for database db-pg"
: > "$HOME/docker.log"
out=$(FAKE_DB_SIZE=9000000000000000 db_dump db-pg 2>&1); rc=$?
check "full disk rc" "$rc" "1"; has "full disk message" "$out" "^not enough disk for a dump of app: database 9000000000000000 bytes, free [0-9]+ bytes, need 18000001073741824 \(2 x size \+ 1 GiB\)$"
case "$(cat "$HOME/docker.log")" in *pg_dump*) check "full disk: pg_dump not run" ran "not run" ;; *) check "full disk: pg_dump not run" ok ok ;; esac
out=$(DUMP_KEEP=0 db_dump db-pg 2>&1); check "DUMP_KEEP=0 refused" "$?:$out" "1:DUMP_KEEP must be an integer >= 1, got '0'"
out=$(DUMP_KEEP=abc db_dump db-pg 2>&1); check "DUMP_KEEP=abc refused" "$?:$out" "1:DUMP_KEEP must be an integer >= 1, got 'abc'"

# retention: DUMP_KEEP=2 prunes to one old dump before dumping, so two remain
sleep 1; DUMP_KEEP=2 db_dump db-pg >/dev/null 2>&1; sleep 1; DUMP_KEEP=2 db_dump db-pg >/dev/null 2>&1
check "retention keeps DUMP_KEEP dumps" "$(find "$HOME/dumps/db-pg" -name '*.dump' | wc -l)" "2"
check "retention keeps the newest" "$(test -e "$d1" || echo pruned)" "pruned"

# DEPLOY_SKIP_DUMP=1 is the explicit way around a dump that cannot be taken
: > "$HOME/seq.log"
out=$(SSH_STUB_FAIL=1 DEPLOY_SKIP_DUMP=1 deploy_and_wait good 2>&1); rc=$?
check "skip dump rc" "$rc" "0"
has "skip dump is said" "$out" "^database dump: skipped \(DEPLOY_SKIP_DUMP=1\)$"
check "skip dump: no ssh" "$(paste -sd ' ' "$HOME/seq.log")" "deploy good"

# ROLLBACK_MODE=1 (rebuild fallback in ROLLBACK.md): no dump, ROLLBACK_COMMIT untouched
state_set ROLLBACK_COMMIT 0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0; : > "$HOME/seq.log"
out=$(ROLLBACK_MODE=1 deploy_and_wait good 2>&1); rc=$?
check "rollback mode rc" "$rc" "0"
check "rollback mode keeps ROLLBACK_COMMIT" "$(state_get ROLLBACK_COMMIT)" "0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0"
has "rollback mode says so" "$out" "^rollback point: kept at 0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0 \(ROLLBACK_MODE=1\)$"
has "rollback mode prints the kept rollback command" "$out" "^  \. \./lib\.sh; rollback_and_wait good 0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0$"
check "rollback mode: no ssh" "$(paste -sd ' ' "$HOME/seq.log")" "deploy good"

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
state_set DB_UUID db-pg; sleep 1
out=$(deploy_and_wait bad 2>&1); rc=$?
check "deploy failure rc" "$rc" "1"
case "$out" in *"missing script: build"*) check "failure shows log" ok ok ;; *) check "failure shows log" "$out" "log tail";; esac
case "$out" in *"secret internals"*) check "hidden lines skipped" shown hidden ;; *) check "hidden lines skipped" ok ok ;; esac
has "failure: image not on server noted" "$out" "^rollback point: commit $SHA \(image not on the server; a rollback rebuilds it\)$"
has "failure prints rollback command" "$out" "^Deployment d-bad failed\. Back to the previous version \(ROLLBACK\.md\):$"
has "failure prints rollback_and_wait" "$out" "^  \. \./lib\.sh; rollback_and_wait bad $SHA$"
has "failure prints db_restore" "$out" "^  only if a migration broke the data: db_restore db-pg $DUMPRE$"
check "rollback point skips pull-request previews" "$(rollback_point good)" "$SHA"

# rollback_and_wait posts the commit and waits
: > "$HOME/seq.log"
out=$(rollback_and_wait good "$SHA" 2>&1); rc=$?
check "rollback rc" "$rc" "0"
has "rollback queued" "$out" "^rollback deployment d-good queued \(to commit $SHA\)$"
check "rollback posts the commit" "$(cat "$HOME/seq.log")" "rollback good $SHA"

# app_logs: runtime logs, N passed as lines=, the stopped app said plainly, bad N refused before any call
: > "$HOME/seq.log"
out=$(app_logs good 2>&1); rc=$?
check "app_logs rc:output" "$rc:$out" "0:2026-10-14T10:00:00Z ready on :::3000
GET /api/health 200
  stack line \"quoted\""
check "app_logs default 100 lines" "$(cat "$HOME/seq.log")" "logs good lines=100"
: > "$HOME/seq.log"; app_logs good 250 >/dev/null 2>&1
check "app_logs passes N" "$(cat "$HOME/seq.log")" "logs good lines=250"
out=$(app_logs stopped-app 2>&1); rc=$?
check "app_logs stopped app" "$rc:$out" '1:app_logs: app stopped-app is not running, so there are no runtime logs; check the container: rssh "docker ps -a --filter name=stopped-app"'
: > "$HOME/seq.log"
for n in 0 -5 abc 10001 007 99999999999999999999; do
  out=$(app_logs good "$n" 2>&1); rc=$?
  check "app_logs N=$n refused" "$rc:$out" "1:app_logs: N must be an integer from 1 to 10000, got '$n'"
done
out=$(app_logs good 10000 2>&1); check "app_logs N=10000 accepted" "$?" "0"
check "app_logs bad N: no request" "$(cat "$HOME/seq.log")" "logs good lines=10000"
out=$(app_logs 2>&1); check "app_logs without uuid" "$?:$out" "1:usage: app_logs APP_UUID [N]"

# team_members, ssh_keys_list: read-only TSV, the role note, no key material, API errors passed on
out=$(team_members 2>/dev/null); rc=$?
check "team_members rc:output" "$rc:$out" "0:name	email	verified	2fa
Dev Root	dev@example.invalid	yes	on
Client Owner	client@example.invalid	no	off"
err=$(team_members 2>&1 >/dev/null)
check "team_members role note on stderr" "$err" "team_members: role is not in the API; see Team -> Members in the Coolify UI"
out=$(ssh_keys_list 2>&1); rc=$?
check "ssh_keys_list rc:output" "$rc:$out" "0:uuid	name	fingerprint	git_related
key-local	localhost's key	SHA256:fakeFingerprintLocal	no
key-gh	app-deploy	SHA256:fakeFingerprintDeploy	yes"
check "ssh_keys_list prints no key material" "$(grep -cE 'PRIVATEKEYMATERIAL|PUBLICKEYMATERIAL|BEGIN OPENSSH' <<<"$out")" "0"
cp "$COOLIFY_CONFIG" "$HOME/config.good"
printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=wrong\n' "$PORT" > "$COOLIFY_CONFIG"
out=$(team_members 2>&1); rc=$?
check "team_members API error" "$rc:$out" '1:HTTP 401 GET /team/members: {"message": "Unauthenticated."}'
out=$(ssh_keys_list 2>&1); rc=$?
check "ssh_keys_list API error" "$rc:$out" '1:HTTP 401 GET /security/keys: {"message": "Unauthenticated."}'
cat "$HOME/config.good" > "$COOLIFY_CONFIG"

# services (R10): create with a domain, conflicts and validation errors said plainly, bad input
# refused before any call, status as TSV, delete only with --yes
: > "$HOME/seq.log"
out=$(service_create umami umami stats.example.com 2>&1); rc=$?
check "service_create without PROJECT_UUID" "$rc:$out" "1:service_create: no PROJECT_UUID in $VPS_SETUP_STATE (phase 05)"
state_set PROJECT_UUID proj-1
out=$(service_create umami umami Stats.Example.com 2>&1); rc=$?
check "service_create rc" "$rc" "0"
check "service_create: exact body" "$(cat "$HOME/seq.log")" 'service POST {"environment_name":"production","instant_deploy":true,"name":"umami","project_uuid":"proj-1","server_uuid":"s2","type":"umami","urls":[{"name":"umami","url":"https://stats.example.com"}]}'
check "service_create: output" "$out" "service umami (umami) created: svc-new, recorded as SERVICE_UMAMI_UUID
domain: https://stats.example.com
Coolify is pulling the images and starting it; next: the HTTPS wait (SERVICES.md step 4)."
check "service_create: state" "$(state_get SERVICE_UMAMI_UUID)" "svc-new"
: > "$HOME/seq.log"
service_create uptime-kuma my-kuma up.example.com uptime-kuma-app >/dev/null 2>&1
has "service_create: compose service override, name to key" "$(cat "$HOME/seq.log")" '"urls":\[\{"name":"uptime-kuma-app","url":"https://up\.example\.com"\}\]'
check "service_create: dashes in the state key" "$(state_get SERVICE_MY_KUMA_UUID)" "svc-new"
: > "$HOME/seq.log"
out=$(service_create umami umami other.example.com 2>&1); rc=$?
check "service_create: a recorded name is refused" "$rc:$out" "1:service umami already recorded as SERVICE_UMAMI_UUID=svc-new; pick another name, or service_delete it first. Nothing was created."
check "service_create: refused name sends nothing" "$(grep -c 'service POST' "$HOME/seq.log")" "0"
out=$(service_create umami other taken.example.com 2>&1); rc=$?
check "service_create 409" "$rc:$out" "1:domain taken.example.com is already used by starter (application); pick another domain or free this one first. Nothing was created."
out=$(service_create forgejo git invalid.example.com 2>&1); rc=$?
check "service_create 422" "$rc:$out" "1:Coolify refused the service (HTTP 422): Validation failed.; urls.0.name: Service 'x' does not exist in the compose file.. Nothing was created."
: > "$HOME/seq.log"
out=$(service_create plausible stats stats.example.com 2>&1); rc=$?
check "service_create: unsupported type" "$rc:$out" "1:service type 'plausible' is not supported; one of: umami n8n uptime-kuma forgejo (SERVICES.md)"
for d in https://stats.example.com stats localhost stats..example.com -a.example.com a-.example.com 'a b.example.com' 'x.example.com/path' 'a;b.example.com'; do
  out=$(service_create umami umami "$d" 2>&1); rc=$?
  check "service_create: domain '$d' refused" "$rc:$out" "1:not a domain name: '$d' (the host only, like stats.example.com, no https://)"
done
for n in Umami 'a b' -x 'x;y'; do
  out=$(service_create umami "$n" stats.example.com 2>&1); rc=$?
  check "service_create: name '$n' refused" "$rc:$out" "1:service name must be lower-case letters, digits and dashes, got '$n'"
done
out=$(service_create umami 2>&1); rc=$?
check "service_create usage" "$rc:$out" "1:usage: service_create TYPE NAME DOMAIN [COMPOSE_SERVICE]  (TYPE: umami n8n uptime-kuma forgejo)"
check "service_create: bad input sends nothing" "$(cat "$HOME/seq.log")" ""

out=$(service_status 2>&1); rc=$?
check "service_status rc:output" "$rc:$out" "0:$(printf '%s\t' kind service name status fqdn)restart_limit
$(printf '%s\t' service umami umami running:healthy '')
$(printf '%s\t' app umami umami running:healthy https://stats.example.com)no
$(printf '%s\t' db umami postgresql running:healthy '')
$(printf '%s\t' service uptime-kuma uptime-kuma exited '')
$(printf '%s\t' app uptime-kuma uptime-kuma exited https://up.example.com)yes"
out=$(service_status svc-umami 2>&1); rc=$?
check "service_status one" "$rc:$(sed -n 2p <<<"$out"):$(wc -l <<<"$out")" "0:$(printf '%s\t' service umami umami running:healthy ''):4"
out=$(service_status nope 2>&1); rc=$?
check "service_status unknown uuid" "$rc:$out" '1:HTTP 404 GET /services/nope: {"message": "Service not found."}'
out=$(service_status '../x' 2>&1); rc=$?
check "service_status bad uuid" "$rc:$out" "1:not a Coolify uuid: '../x'"

: > "$HOME/seq.log"
out=$(service_delete svc-umami 2>&1); rc=$?
check "service_delete without --yes refused" "$rc:$out" "1:service_delete: refusing without --yes. This deletes service svc-umami with its volumes: its database and files are gone for good. Ask the user, then: service_delete svc-umami --yes"
out=$(service_delete svc-umami yes 2>&1); rc=$?
check "service_delete with 'yes' (not --yes) refused" "$rc" "1"
out=$(service_delete 2>&1); rc=$?
check "service_delete usage" "$rc:$out" "1:usage: service_delete UUID --yes"
out=$(service_delete '../applications/a1' --yes 2>&1); rc=$?
check "service_delete bad uuid" "$rc:$out" "1:not a Coolify uuid: '../applications/a1'"
check "service_delete refused: no request sent" "$(cat "$HOME/seq.log")" ""
out=$(service_delete svc-umami --yes 2>&1); rc=$?
check "service_delete rc:output" "$rc:$out" "0:service umami (svc-umami) deleted with its volumes; Coolify removes the containers in the background"
check "service_delete: DELETE with delete_volumes" "$(cat "$HOME/seq.log")" "DELETE /services/svc-umami?delete_volumes=true"
: > "$HOME/seq.log"
out=$(service_delete svc-gone --yes 2>&1); rc=$?
check "service_delete unknown uuid: no DELETE" "$rc:$(cat "$HOME/seq.log")" "1:"

# db_restore: refused while the app runs, pg_restore all or nothing, wipe only on RESTORE_WIPE=yes
dump=$(state_get LAST_DUMP)
state_set APP_UUID good; : > "$HOME/docker.log"
out=$(db_restore db-pg "$dump" 2>&1); rc=$?
check "restore refused while app runs" "$rc:$out" "1:db_restore: app good is running:healthy; stop it first (ROLLBACK.md step 4) or set RESTORE_WITH_APP_RUNNING=1"
check "restore refused: nothing ran" "$(cat "$HOME/docker.log")" ""
sed -i '/^APP_UUID=/d' "$VPS_SETUP_STATE"
out=$(db_restore db-pg "$dump" 2>&1); rc=$?
check "restore refused without APP_UUID" "$rc" "1"; has "restore without APP_UUID message" "$out" "^db_restore: no APP_UUID in .*RESTORE_WITH_APP_RUNNING=1$"
state_set APP_UUID stopped-app
out=$(db_restore db-pg "$dump" 2>&1); rc=$?
check "restore rc:output" "$rc:$out" "0:pg_restore done
restored $dump into app"
case "$(cat "$HOME/ssh.args")" in *"sh -s -- db-pg app app $dump no"*) check "restore ssh command" ok ok ;; *) check "restore ssh command" "$(cat "$HOME/ssh.args")" "... sh -s -- db-pg app app $dump no" ;; esac
has "restore is all or nothing" "$(cat "$HOME/docker.log")" "^docker exec -i cid pg_restore -U app -d app --single-transaction --clean --if-exists --no-owner --no-privileges$"
case "$(cat "$HOME/docker.log")" in *"drop schema"*) check "restore: no wipe by default" wiped "not wiped" ;; *) check "restore: no wipe by default" ok ok ;; esac
: > "$HOME/docker.log"
out=$(RESTORE_WIPE=yes db_restore db-pg "$dump" 2>&1); rc=$?
check "restore with wipe rc" "$rc" "0"
has "restore with wipe drops the schema first" "$(paste -sd ' ' "$HOME/docker.log")" "psql -U app -d app -v ON_ERROR_STOP=1 -qc drop schema public cascade; create schema public; docker exec -i cid pg_restore"
has "restore with wipe says so" "$out" "^schema public wiped in app$"
out=$(RESTORE_WITH_APP_RUNNING=1 FAKE_PG_RESTORE_FAIL=1 db_restore db-pg "$dump" 2>&1); rc=$?
check "restore failure rc" "$rc" "1"; has "restore failure shows pg_restore error" "$out" "^pg_restore: error: fake$"
case "$out" in *"restored "*) check "restore failure: no success line" shown none ;; *) check "restore failure: no success line" ok ok ;; esac
out=$(db_restore db-pg "$HOME/dumps/db-pg/missing.dump" 2>&1); rc=$?
check "restore missing dump" "$rc:$out" "1:dump not found or empty: $HOME/dumps/db-pg/missing.dump"

# Postgres major upgrade (R14): db_major, pg_image_major, the plan, the explicit restore target
check "db_major 17" "$(db_major db-pg 2>&1)" "17"
check "db_major 16" "$(db_major db-pg16 2>&1)" "16"
out=$(db_major db-latest 2>&1); rc=$?
check "db_major postgres:latest" "$rc:$out" "1:no Postgres major version in the image tag: 'postgres:latest'"
out=$(db_major db-redis 2>&1); rc=$?
check "db_major redis" "$rc:$out" "1:db-redis is standalone-redis; only standalone-postgresql is supported"
out=$(db_major '../x' 2>&1); rc=$?
check "db_major bad uuid" "$rc:$out" "1:not a Coolify uuid: '../x'"
got=""; for i in postgres:17-alpine postgres:16.4 registry.example.com:5000/postgres:18 postgres:18.0-bookworm; do got="$got $(pg_image_major "$i")"; done
check "pg_image_major tags" "$got" " 17 16 18 18"
got=""; for i in postgres postgres:latest postgres@sha256:abc ''; do pg_image_major "$i" >/dev/null 2>&1 && got="$got $i"; done
check "pg_image_major refuses tags without a major" "${got:-none}" "none"

state_set PROJECT_UUID proj-1; state_set APP_UUID stopped-app; state_set DB_UUID db-pg
: > "$HOME/seq.log"
out=$(pg_major_upgrade_plan db-pg 18 2>&1); rc=$?
check "plan rc" "$rc" "0"
has "plan: old database" "$out" '^old: +db-pg +starter-db +postgres:17-alpine +user app, database app +\(Postgres 17\)$'
has "plan: new database" "$out" '^new: +starter-db-pg18 +postgres:18-alpine +user app, database app, new password$'
has "plan: where" "$out" '^ +project proj-1, environment production, server s2$'
has "plan: app" "$out" '^app: +stopped-app '
has "plan: explicit restore target" "$out" 'RESTORE_FROM_DB=db-pg db_restore <NEW_UUID> <dump>'
has "plan: Postgres 18 quirk" "$out" '^warning: Postgres 18\+ '
check "plan: DB_UUID matches, no note" "$(grep -c '^note:' <<<"$out")" "0"
check "plan: read-only (no POST, PATCH, DELETE, ssh)" "$(cat "$HOME/seq.log")" ""
case "$out" in *SECRET*) check "plan: no password" leaked none ;; *) check "plan: no password" ok ok ;; esac
out=$(pg_major_upgrade_plan db-pg16 17 2>&1); rc=$?
check "plan 16 -> 17 rc" "$rc" "0"
has "plan: other database than DB_UUID noted" "$out" '^note: +db-pg16 is not DB_UUID'
check "plan 17: no Postgres 18 warning" "$(grep -c '^warning:' <<<"$out")" "0"
for t in 17 16; do
  out=$(pg_major_upgrade_plan db-pg "$t" 2>&1); rc=$?
  check "plan refuses $t on 17" "$rc:$out" "1:database db-pg already runs Postgres 17; $t is not an upgrade (a downgrade needs a dump into a new database by hand)"
done
for t in x 18.1 -1 018 1000; do
  out=$(pg_major_upgrade_plan db-pg "$t" 2>&1); rc=$?
  check "plan refuses TARGET '$t'" "$rc:$out" "1:TARGET must be a major version like 18, got '$t'"
done
out=$(pg_major_upgrade_plan db-pg 2>&1); rc=$?
check "plan usage" "$rc:$out" "1:usage: pg_major_upgrade_plan DB_UUID TARGET  (TARGET: a major version like 18)"
out=$(pg_major_upgrade_plan db-redis 18 2>&1); rc=$?
check "plan refuses redis" "$rc:$out" "1:db-redis is standalone-redis; only standalone-postgresql is supported"
out=$(pg_major_upgrade_plan db-latest 18 2>&1); rc=$?
check "plan refuses an image without a major" "$rc" "1"

# db_restore: a dump of db-pg goes into another database only with RESTORE_FROM_DB, never into itself that way
: > "$HOME/docker.log"
out=$(db_restore db-pg18 "$dump" 2>&1); rc=$?
check "restore into another db without RESTORE_FROM_DB refused" "$rc:$out" "1:db_restore: dump $dump belongs to database db-pg, not db-pg18; to restore it into another database on purpose (UPGRADE.md) set RESTORE_FROM_DB=db-pg"
out=$(RESTORE_FROM_DB=db-pg db_restore db-pg "$dump" 2>&1); rc=$?
check "upgrade restore into the old db refused" "$rc:$out" "1:db_restore: RESTORE_FROM_DB is the target db-pg itself; the target of an upgrade restore is the NEW database"
out=$(RESTORE_FROM_DB=db-other db_restore db-pg18 "$dump" 2>&1); rc=$?
check "RESTORE_FROM_DB must match the dump's database" "$rc:$out" "1:db_restore: dump $dump belongs to database db-pg, not RESTORE_FROM_DB=db-other"
check "refused restores ran nothing" "$(cat "$HOME/docker.log")" ""
out=$(RESTORE_FROM_DB=db-pg db_restore db-pg18 "$dump" 2>&1); rc=$?
check "upgrade restore into the new db" "$rc:$out" "0:pg_restore done
restored $dump into app"
case "$(cat "$HOME/ssh.args")" in *"sh -s -- db-pg18 app app $dump no"*) check "upgrade restore: ssh targets the new db" ok ok ;; *) check "upgrade restore: ssh targets the new db" "$(cat "$HOME/ssh.args")" "... sh -s -- db-pg18 app app $dump no" ;; esac
has "upgrade restore: container of the new db" "$(cat "$HOME/docker.log")" '^docker ps -q -f name=\^/\?db-pg18\$$'
out=$(db_restore db-pg 2>&1); rc=$?
check "restore usage" "$rc:$out" "1:usage: db_restore DB_UUID DUMP_PATH"
# off-site backups (R04): S3 storage, schedule, backup now, list, fetch from S3, restore.
# jq and curl are wrapped to log their argv, so a credential on any command line shows up in argv.log.
mkdir -p "$HOME/argvbin" "$HOME/srvtmp"
for t in jq curl; do
  # shellcheck disable=SC2016 # $* and $@ belong to the generated wrapper
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "$HOME/argv.log"\nexec %s "$@"\n' "$t" "$(command -v "$t")" > "$HOME/argvbin/$t"
  chmod +x "$HOME/argvbin/$t"
done
PATH="$HOME/argvbin:$PATH"; export TMPDIR="$HOME/srvtmp"
S3E="$HOME/.config/vps-setup/s3.env"; : > "$HOME/outputs.log"
# s3run CMD...: runs a lib function, sets $out and $rc, keeps every output for the secret check
s3run() { out=$("$@" 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"; }
EP=https://fsn1.your-objectstorage.com

: > "$HOME/seq.log"
s3run s3_storage_create backups "$EP" my-backups fsn1
check "s3: missing s3.env refused" "$rc:$out" "1:no S3 credentials: $S3E is missing (phase 06 step 1)"
( umask 022; printf 'S3_KEY=AKFAKEKEY123\nS3_SECRET=s3SeCrEt/x+y=z|w\n' > "$S3E" )
s3run s3_storage_create backups "$EP" my-backups fsn1
check "s3: s3.env mode 644 refused" "$rc:$out" "1:refusing $S3E: mode 644, must be 600 (chmod 600 $S3E)"
check "s3: nothing sent while refused" "$(cat "$HOME/seq.log")" ""
chmod 600 "$S3E"
s3run s3_storage_create backups "$EP" my-backups fsn1
check "s3 create rc" "$rc" "0"
has "s3 create: created" "$out" '^S3 storage backups created \(s3-1\)$'
has "s3 create: validated" "$out" '^S3 storage s3-1 valid: S3 storage connection is valid\.$'
has "s3 create: keep s3.env" "$out" "^Keep $S3E: a restore"
check "s3 create: API got name, endpoint, bucket, region, key, secret" "$(cat "$HOME/seq.log")" "s3 POST backups $EP my-backups fsn1 creds=ok"
check "s3 create: state" "$(state_get S3_STORAGE_UUID)" "s3-1"
: > "$HOME/seq.log"
s3run s3_storage_create backups "$EP" my-backups fsn1
check "s3 create again: updates, no duplicate" "$rc:$(cat "$HOME/seq.log")" "0:s3 PATCH s3-1 creds=ok"
s3run s3_storage_create other "$EP" wrong-bucket fsn1
check "s3 validate fail rc" "$rc" "1"
has "s3 validate fail: Coolify's message" "$out" '^S3 storage s3-2 failed validation: The specified bucket does not exist$'
has "s3 validate fail: where to fix" "$out" 'Settings -> S3 Storages'
check "s3 validate fail: state unchanged" "$(state_get S3_STORAGE_UUID)" "s3-1"

# attach: PATCH the existing schedule, or POST a new one
: > "$HOME/seq.log"
s3run db_backup_attach_s3 db-pg s3-1
check "attach existing rc:state" "$rc:$(state_get BACKUP_UUID)" "0:bk1"
check "attach existing: PATCH body" "$(cat "$HOME/seq.log")" 'backup PATCH db-pg bk1 {"database_backup_retention_amount_s3":30,"s3_storage_uuid":"s3-1","save_s3":true}'
: > "$HOME/seq.log"
s3run db_backup_attach_s3 db-new s3-1
check "attach new rc:state" "$rc:$(state_get BACKUP_UUID)" "0:bk-new"
check "attach new: POST body" "$(cat "$HOME/seq.log")" 'backup POST db-new {"database_backup_retention_amount_locally":7,"database_backup_retention_amount_s3":30,"enabled":true,"frequency":"0 2 * * *","s3_storage_uuid":"s3-1","save_s3":true}'

# backup now: waits for the new run, then judges the run and the S3 upload
export BACKUP_POLL_SECONDS=0
: > "$HOME/seq.log"
s3run db_backup_now db-pg bk1
check "backup now rc" "$rc" "0"
check "backup now: PATCH backup_now" "$(cat "$HOME/seq.log")" "backup PATCH db-pg bk1 backup_now"
has "backup now: waits while running" "$out" '^\[0s\] running$'
has "backup now: execution line" "$out" '^execution ex-new-1: success, file /data/coolify/backups/databases/root/db-pg/pg-dump-app-1760000001\.dmp, 2048 bytes$'
has "backup now: S3 uploaded" "$out" '^S3: uploaded$'
s3run db_backup_now db-pg bk-warn
check "backup now S3 warning rc" "$rc" "1"
has "backup now S3 warning message" "$out" '^S3: upload FAILED: Backup done\. Warning: S3 upload failed: Access Denied$'
s3run db_backup_now db-pg bk-msg
check "backup now, s3_uploaded not reported: rc" "$rc" "0"
has "backup now, s3_uploaded not reported: said" "$out" '^S3: no upload error in the message \(this Coolify does not report s3_uploaded\)$'
s3run db_backup_now db-pg bk-fail
check "backup now failed rc" "$rc" "1"
has "backup now failed message" "$out" '^backup failed: pg_dump: error: connection refused$'
BACKUP_POLL_TRIES=2 s3run db_backup_now db-pg bk-never
check "backup now timeout rc" "$rc" "1"
has "backup now timeout message" "$out" '^Timed out after 0s; no finished backup run of schedule bk-never$'

# list: newest first, with the S3 state and the file name for db_fetch_from_s3
s3run db_backup_list db-pg
check "list rc" "$rc" "0"
check "list header" "$(head -1 <<<"$out")" "$(printf 'schedule\texecution\tcreated_at\tstatus\tsize\ts3\tfilename')"
check "list newest first" "$(sed -n 2p <<<"$out")" "$(printf 'bk1\tex-new-1\t2026-10-14T10:00:01+00:00\tsuccess\t2048\tuploaded\t/data/coolify/backups/databases/root/db-pg/pg-dump-app-1760000001.dmp')"
check "list older run" "$(sed -n 3p <<<"$out" | cut -f2,6)" "$(printf 'ex-old-bk1\tuploaded')"

# fetch from S3 onto the server: creds over stdin into a 600 env file, file 600, then restore it
F=/data/coolify/backups/databases/root/db-pg/pg-dump-app-1760000001.dmp
: > "$HOME/seq.log"; : > "$HOME/docker.log"; : > "$HOME/envcheck.log"
s3run db_fetch_from_s3 db-pg "$F"
got="$HOME/dumps/db-pg/s3-pg-dump-app-1760000001.dmp"
check "fetch rc:output" "$rc:$out" "0:$got $(stat -c %s "$got" 2>/dev/null)"
check "fetch file mode 600" "$(stat -c %a "$got")" "600"
check "fetch: mc got the creds from a 600 env file" "$(cat "$HOME/envcheck.log")" "envfile ok 600"
has "fetch: mc copies bucket/key without the leading slash" "$(cat "$HOME/docker.log")" "^docker run --rm --env-file $HOME/srvtmp/[^ ]+ -v $HOME/dumps/db-pg:/out --entrypoint mc ghcr\.io/coollabsio/coolify-helper:1\.0\.17 --quiet cp s3/my-backups/data/coolify/backups/databases/root/db-pg/pg-dump-app-1760000001\.dmp /out/s3-pg-dump-app-1760000001\.dmp$"
has "fetch: creds travel in the ssh stdin" "$(cat "$HOME/ssh.stdin")" '^MC_HOST_s3=https://AKFAKEKEY123:'
check "fetch: env file deleted" "$(ls -A "$HOME/srvtmp")" ""
s3run db_restore db-pg "$got"
check "restore of the fetched file" "$rc:$(tail -1 <<<"$out")" "0:restored $got into app"
: > "$HOME/envcheck.log"
FAKE_MC_FAIL=1 s3run db_fetch_from_s3 db-pg /data/x/pg-dump-app-2.dmp
check "fetch failure rc" "$rc" "1"
has "fetch failure message" "$out" '^download of s3/my-backups/data/x/pg-dump-app-2\.dmp failed$'
check "fetch failure: no file, env file deleted" "$(find "$HOME/dumps/db-pg" -name '*pg-dump-app-2*' | wc -l):$(ls -A "$HOME/srvtmp")" "0:"
FAKE_NO_HELPER=1 s3run db_fetch_from_s3 db-pg /data/x/pg-dump-app-3.dmp
check "fetch without a coolify-helper image" "$rc:$out" "1:no coolify-helper image on the server; set MC_IMAGE"
: > "$HOME/docker.log"
MC_IMAGE=my/mc:1 s3run db_fetch_from_s3 db-pg /data/x/pg-dump-app-4.dmp
has "fetch: MC_IMAGE overrides the helper" "$(cat "$HOME/docker.log")" " --entrypoint mc my/mc:1 --quiet cp "
: > "$HOME/seq.log"
S3_ENV="$HOME/nope.env" s3run db_fetch_from_s3 db-pg /data/x/y.dmp
check "fetch without creds refused" "$rc:$out" "1:no S3 credentials: $HOME/nope.env is missing (phase 06 step 1)"
check "fetch without creds: no ssh" "$(cat "$HOME/seq.log")" ""

# alerts (R06a): Coolify notifications to Discord; the webhook URL is handled like the S3 keys
NE="$HOME/.config/vps-setup/notify.env"; WH=https://discord.com/api/webhooks/1/wh-SECRET-abc
OFF7="status_change deployment_failure backup_failure server_unreachable server_reachable server_disk_usage restart_limit_reached"
: > "$HOME/seq.log"
s3run notify_setup
check "alerts: missing notify.env refused" "$rc:$out" "1:no notification webhook: $NE is missing (phase 06 step 2)"
( umask 022; printf 'DISCORD_WEBHOOK_URL=%s\n' "$WH" > "$NE" )
s3run notify_setup
check "alerts: notify.env mode 644 refused" "$rc:$out" "1:refusing $NE: mode 644, must be 600 (chmod 600 $NE)"
check "alerts: nothing sent while refused" "$(cat "$HOME/seq.log")" ""
( umask 077; printf 'OTHER=1\n' > "$HOME/empty.env" )
NOTIFY_ENV="$HOME/empty.env" s3run notify_setup
check "alerts: notify.env without the URL refused" "$rc:$out" "1:$HOME/empty.env needs a DISCORD_WEBHOOK_URL= line"
s3run notify_setup telegram
check "alerts: other channels refused" "$rc:$out" "1:notification channel 'telegram' is not supported; Discord is the one way (phase 06 step 2)"
chmod 600 "$NE"
s3run notify_status
check "alerts: status before setup" "$rc:$out" "1:discord: disabled, 0/7 alert events on (off: $OFF7)"
s3run notify_setup
check "alerts setup rc" "$rc" "0"
check "alerts setup: exact body, URL from notify.env" "$(cat "$HOME/seq.log")" 'notify PATCH discord {"backup_failure_discord_notifications":true,"deployment_failure_discord_notifications":true,"discord_enabled":true,"discord_ping_enabled":true,"restart_limit_reached_discord_notifications":true,"server_disk_usage_discord_notifications":true,"server_reachable_discord_notifications":true,"server_unreachable_discord_notifications":true,"status_change_discord_notifications":true} url=ok'
check "alerts setup: output" "$out" "discord: enabled, 7/7 alert events on
Next: Coolify -> Notifications -> Discord -> Send test notification (the API has no test call)."
check "alerts setup: state" "$(state_get ALERTS)" "discord"
first=$out; : > "$HOME/seq.log"
s3run notify_setup
check "alerts setup again: same body, same output" "$rc:$(cut -d' ' -f1-3 "$HOME/seq.log"):$out" "0:notify PATCH discord:$first"
s3run notify_status
check "alerts: status after setup" "$rc:$out" "0:discord: enabled, 7/7 alert events on"
( umask 077; printf 'DISCORD_WEBHOOK_URL=https://localhost/api/webhooks/2/wh-SECRET-bad\n' > "$HOME/bad.env" )
NOTIFY_ENV="$HOME/bad.env" s3run notify_setup
check "alerts: 422 shows Coolify's message without the URL" "$rc:$out" "1:Coolify refused the discord settings (HTTP 422): Validation failed.; discord_webhook_url: The URL <webhook URL> points to a private address.
Check the webhook URL in $HOME/bad.env (phase 06 step 2) and run this again."
check "alerts: 422 keeps the state" "$(state_get ALERTS)" "discord"

# the credentials never appear on a command line (jq, curl, ssh, docker) or in any output
leaks=$(grep -lE 's3SeCrEt|AKFAKEKEY|wh-SECRET|api/webhooks' "$HOME/argv.log" "$HOME/ssh.args" "$HOME/docker.log" "$HOME/outputs.log" 2>/dev/null)
check "s3 creds and webhook URL in no argv and no output" "${leaks:-none}" "none"
check "argv log was written" "$(grep -c '^jq ' "$HOME/argv.log" | awk '{print ($1 > 10) ? "yes" : "no"}')" "yes"
PATH=${PATH#"$HOME/argvbin:"}; unset TMPDIR BACKUP_POLL_SECONDS

sed -i '/^VPS_IP=/d; /^DB_UUID=/d; /^APP_UUID=/d; /^ROLLBACK_COMMIT=/d; /^LAST_DUMP=/d; /^PROJECT_UUID=/d; /^SERVICE_/d' "$VPS_SETUP_STATE"

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
