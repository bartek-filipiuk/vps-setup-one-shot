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
import json, re, sys, time
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
SERVICES = {"svc-umami": {"uuid": "svc-umami", "name": "umami", "service_type": "umami", "status": "running:healthy", "environment_id": 1,
    "applications": [{"uuid": "sa1", "name": "umami", "human_name": None, "fqdn": "https://stats.example.com", "status": "running:healthy",
                      "image": "ghcr.io/umami-software/umami:postgresql-latest", "restart_limit_reached": False}],
    "databases": [{"uuid": "sd1", "name": "postgresql", "image": "postgres:16-alpine", "status": "running:healthy", "is_public": False}]},
  "svc-kuma": {"uuid": "svc-kuma", "name": "uptime-kuma", "service_type": "uptime-kuma", "status": "exited", "environment_id": 3,
    "applications": [{"uuid": "sa2", "name": "uptime-kuma", "fqdn": "https://up.example.com", "status": "exited", "restart_limit_reached": True}],
    "databases": []}}
# Kuma services for UPTIME.md (R06b): only GET /services/{uuid} serves them, so the lists above stay as they are
KUMA_SVCS = {"svc-kuma-up": {"uuid": "svc-kuma-up", "name": "uptime-kuma", "service_type": "uptime-kuma", "status": "running:healthy",
    "environment_id": 1, "applications": [{"uuid": "sa3", "name": "uptime-kuma", "fqdn": "https://Status.Example.com:443/",
    "status": "running:healthy", "restart_limit_reached": False}], "databases": []},
  "svc-kuma-nodom": {"uuid": "svc-kuma-nodom", "name": "kuma2", "service_type": "uptime-kuma", "status": "running:healthy",
    "environment_id": 1, "applications": [{"uuid": "sa4", "name": "uptime-kuma", "fqdn": None, "status": "running:unknown"}], "databases": []},
  "svc-umami2": {"uuid": "svc-umami2", "name": "notkuma", "service_type": "umami", "status": "running:healthy", "environment_id": 1,
    "applications": [{"uuid": "sa5", "name": "umami", "fqdn": "https://u.example.com", "status": "running:healthy"}], "databases": []}}
# Kuma's public status page JSON (R06b), as the 2.x source builds it [verify]: GET /api/status-page/<slug> and
# /api/status-page/heartbeat/<slug>; status 0 down, 1 up, 2 pending, 3 maintenance; msg is always "" (2.5.6). No token.
KUMA_PAGES = {"acme": {"config": {"slug": "acme", "title": "Acme"}, "incidents": [], "maintenanceList": [],
    "publicGroupList": [{"id": 1, "name": "Acme", "weight": 1, "monitorList": [
        {"id": 1, "name": "shop", "type": "http"}, {"id": 2, "name": "starter", "type": "http"},
        {"id": 3, "name": "fresh", "type": "http"}, {"id": 4, "name": "slow\tone", "type": "http"}]},
      {"id": 2, "name": "Infra", "weight": 2, "monitorList": [{"id": 1, "name": "shop", "type": "http"}, {"id": 5, "name": "db", "type": "http"}]}]},
  "empty": {"config": {"slug": "empty"}, "incidents": [], "maintenanceList": [], "publicGroupList": []},
  "odd": {"msg": "not a page"}}
KUMA_BEATS = {"acme": {"heartbeatList": {
    "1": [{"status": 1, "time": "2026-10-19 10:00:00.000", "msg": "", "ping": 20}, {"status": 1, "time": "2026-10-19 09:59:00.000", "msg": "", "ping": 21}],
    "2": [{"status": 1, "time": "2026-10-19 09:58:00.000", "msg": "", "ping": 20}, {"status": 0, "time": "2026-10-19 09:59:00.000", "msg": "", "ping": None},
          {"status": 0, "time": "2026-10-19 10:00:00.000", "msg": "", "ping": None}],
    "4": [{"status": 2, "time": "2026-10-19 10:00:00.000", "msg": "", "ping": None}],
    "5": [{"status": 3, "time": "2026-10-19 10:00:00.000", "msg": "", "ping": None}]},
    "uptimeList": {"1_24": 0.9984, "2_24": 0.5, "5_24": 1}},
  "empty": {"heartbeatList": {}, "uptimeList": {}}, "odd": {"heartbeatList": {}, "uptimeList": {}}}
# projects (R09) as the live 4.3.23 GET /projects/{uuid} answers (fields trimmed); environments by numeric id.
# "twins" twice: Coolify does not keep project names unique [verify].
PROJECTS = {
  "p-starter": {"id": 1, "uuid": "p-starter", "name": "starter", "description": "created by vps-setup-one-shot",
                "environments": [{"id": 1, "uuid": "e1", "name": "production", "project_id": 1}]},
  "p-acme": {"id": 2, "uuid": "p-acme", "name": "Acme Corp", "description": None,
             "environments": [{"id": 2, "uuid": "e2", "name": "production", "project_id": 2},
                              {"id": 3, "uuid": "e3", "name": "staging", "project_id": 2}]},
  "p-tw1": {"id": 4, "uuid": "p-tw1", "name": "twins", "description": "", "environments": [{"id": 9, "uuid": "e9", "name": "production", "project_id": 4}]},
  "p-tw2": {"id": 5, "uuid": "p-tw2", "name": "twins", "description": "", "environments": []}}
APPS = [
  {"uuid": "a-starter", "name": "starter", "status": "running:healthy", "fqdn": "https://starter.example.com",
   "git_repository": "git@github.com:u/starter.git", "environment_id": 1, "manual_webhook_secret_github": "hook-SECRET-1"},
  {"uuid": "a-shop", "name": "shop", "status": "running:healthy", "fqdn": "https://shop.acme.example.com, https://WWW.Shop.example.com:443/x",
   "git_repository": "https://x-access-token:tok-SECRET-2@github.com/acme/shop.git", "environment_id": 2},
  {"uuid": "a-shop-stg", "name": "shop", "status": "exited:unhealthy", "fqdn": "https://staging.shop.acme.example.com",
   "git_repository": "git@github.com:acme/shop.git", "environment_id": 3},
  {"uuid": "a-orphan", "name": "orphan|pipe", "status": "running:unknown", "fqdn": None, "git_repository": None, "environment_id": 99}]
DBS = [{"uuid": "db-pg", "name": "starter-db", "status": "running:healthy", "database_type": "standalone-postgresql", "environment_id": 1,
        "internal_db_url": "postgres://app:pw-SECRET-123@db-pg:5432/app", "postgres_password": "pw-SECRET-123"}]
# staging (R11): env lists as the live 4.3.23 GET /applications/{uuid}/envs answers (no value field);
# apps created through POST /applications/private-deploy-key live in CREATED
def env(u, k, build=False, preview=False, coolify=False):
    return {"uuid": u, "key": k, "is_buildtime": build, "is_runtime": True, "is_preview": preview, "is_coolify": coolify,
            "is_literal": False, "is_multiline": False, "is_shown_once": False, "is_shared": False, "is_required": False,
            "is_really_required": False, "is_buildpack_control": False, "comment": None, "order": None, "version": "4.3.23",
            "created_at": "2026-10-16T10:00:00.000000Z", "updated_at": "2026-10-16T10:00:00.000000Z"}
ENVS = {"a-shop": [env("ev1", "DATABASE_URL"), env("ev2", "AUTH_SECRET"), env("ev3", "NEXT_PUBLIC_SITE_URL", build=True),
                   env("ev4", "AUTH_SECRET", preview=True), env("ev5", "SMTP_HOST"), env("ev6", "STRIPE_API_KEY"),
                   env("ev7", "SOURCE_COMMIT", coolify=True)],
        "a-new": [env("ev8", "AUTH_SECRET"), env("ev9", "AUTH_SECRET", preview=True)]}
ENV_VAL = "v-SECRET-1|a=b c\nline 2"
CREATED = {}
import os
DOWN = os.path.join(os.path.dirname(sys.argv[2]), "projects.down")   # touch it: GET /projects answers 500
# Discord settings as the live GET answers (no URL in it); PATCH accepts only these keys plus the URL.
notif = {"id": 1, "team_id": 0, "discord_enabled": False, "discord_ping_enabled": False} | {e + "_discord_notifications": False for e in EVENTS}
# Cloudflare API v4 (R18): the envelope {success, errors, messages, result}; zones and records in memory.
CF_TOKEN = "FAKE-cf-token_000"
ZONES = {"example.com": "0123456789abcdef0123456789abcdef", "example.org": "1123456789abcdef0123456789abcdef",
         "deep.example.org": "2123456789abcdef0123456789abcdef"}
cf_seq = [0]
def rid():
    cf_seq[0] += 1; return "%032x" % (0xabc000 + cf_seq[0])
records = {"0123456789abcdef0123456789abcdef": [
    {"id": rid(), "type": "CNAME", "name": "www.example.com", "content": "example.com", "proxied": True, "ttl": 1},
    {"id": rid(), "type": "A", "name": "two.example.com", "content": "198.51.100.1", "proxied": False, "ttl": 1},
    {"id": rid(), "type": "A", "name": "two.example.com", "content": "198.51.100.2", "proxied": False, "ttl": 300},
    {"id": rid(), "type": "AAAA", "name": "v6.example.com", "content": "2001:db8::1", "proxied": False, "ttl": 1},
    {"id": rid(), "type": "A", "name": "old.example.com", "content": "198.51.100.7", "proxied": True, "ttl": 1},
    {"id": rid(), "type": "MX", "name": "old.example.com", "content": "mx.example.net", "proxied": False, "ttl": 1, "priority": 10}]}
def cf(h, method):
    from urllib.parse import urlsplit, parse_qs
    u = urlsplit(h.path); p = u.path.removeprefix("/client/v4"); q = {k: v[0] for k, v in parse_qs(u.query).items()}
    raw = h.rfile.read(int(h.headers.get("Content-Length", 0))) if method in ("POST", "PATCH") else b""
    seq("cf %s %s%s%s" % (method, p, "?" + u.query if u.query else "",
        " " + json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":")) if raw else ""))
    ok = lambda r: h.send(200, {"success": True, "errors": [], "messages": [], "result": r})
    def err(code, c, m): return h.send(code, {"success": False, "errors": [{"code": c, "message": m}], "messages": [], "result": None})
    auth = h.headers.get("Authorization", "")
    if p == "/user/tokens/verify":
        if auth == "Bearer FAKE-cf-expired": return ok({"id": "t1", "status": "expired"})
        if auth != "Bearer " + CF_TOKEN: return err(401, 1000, "Invalid API Token")
        return ok({"id": "t1", "status": "active"})
    if auth != "Bearer " + CF_TOKEN: return err(403, 10000, "Authentication error")
    if p == "/zones" and method == "GET":
        n = q.get("name", "")
        return ok([{"id": ZONES[n], "name": n, "status": "pending" if n == "example.org" else "active"}] if n in ZONES else [])
    m = re.match(r"^/zones/([0-9a-f]{32})/dns_records(?:/([0-9a-f]{32}))?$", p)
    if not m or m.group(1) not in ZONES.values(): return err(404, 7003, "Could not route to %s, perhaps your object identifier is invalid?" % p)
    rs = records.setdefault(m.group(1), [])
    if method == "GET":
        if q.get("name") == "busy.example.com": return err(429, 971, "Please wait and consider throttling your request speed")
        return ok([r for r in rs if r["name"] == q.get("name") and r["type"] == q.get("type", r["type"])])
    b = json.loads(raw) if raw else {}
    if method == "POST":
        r = {"id": rid(), "proxied": False, "ttl": 1} | b; rs.append(r); return ok(r)
    if method == "PATCH":
        for r in rs:
            if r["id"] == m.group(2): r.update(b); return ok(r)
        return err(404, 81044, "Record does not exist.")
    return err(405, 10000, "method not allowed in the fake")
def seq(line):
    with open(sys.argv[2], "a") as f: f.write(line + "\n")
# backup runs relative to now (R16 backup_success_rate): (days ago, status, extra fields)
def ago(d): return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - d * 86400))
RATE = {"bk-rate": [(1, "success", {"s3_uploaded": True}), (2, "failed", {"message": "pg_dump: error"}),
                    (3, "success", {"message": "Backup done. Warning: S3 upload failed: Access Denied"}),
                    (4, "success", {"s3_uploaded": True}), (5, "success", {"s3_uploaded": True}),
                    (6, "success", {"s3_uploaded": True}), (40, "failed", {}), (0, "running", {})],
        "bk-local": [(1, "success", {}), (2, "success", {})]}
schedules["db-rate"] = [{"uuid": "bk-rate", "enabled": True, "frequency": "0 2 * * *", "save_s3": True},
                        {"uuid": "bk-local", "enabled": True, "frequency": "0 3 * * *", "save_s3": False}]
# GitHub security advisories of Coolify (R16), as the REST API answers them (fields trimmed)
ADVISORIES = [
    {"ghsa_id": "GHSA-old0-0000-0000", "severity": "critical", "published_at": "2025-01-10T00:00:00Z",
     "vulnerabilities": [{"package": {"ecosystem": "other", "name": "coolify"}, "vulnerable_version_range": "< 4.0.0-beta.420", "patched_versions": "4.0.0-beta.420"}]},
    {"ghsa_id": "GHSA-new0-0000-0000", "severity": "high", "published_at": "2026-10-01T00:00:00Z",
     "vulnerabilities": [{"package": {"ecosystem": "other", "name": "coolify"}, "vulnerable_version_range": ">= 4.0.0, <= 4.3.23", "patched_versions": "4.3.24"}]},
    {"ghsa_id": "GHSA-none-0000-0000", "severity": "medium", "published_at": "2026-02-01T00:00:00Z",
     "vulnerabilities": [{"package": None, "vulnerable_version_range": None, "patched_versions": None}]}]
def executions(b):
    if b in RATE:
        return [{"uuid": "%s-%d" % (b, i), "status": st, "created_at": ago(d), "finished_at": None} | x for i, (d, st, x) in enumerate(RATE[b])]
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
        if self.path.startswith("/client/v4/"): return cf(self, "GET")
        if self.path.startswith("/gh/"):
            seq("gh " + self.path)
            if self.path.startswith("/gh/limit"): return self.send(403, {"message": "API rate limit exceeded"})
            if self.path.startswith("/gh/odd"): return self.send(200, {"message": "not a list"})
            return self.send(200, ADVISORIES)
        m = re.match(r"^/api/status-page/(heartbeat/)?([a-z0-9-]+)$", self.path)
        if m:   # Kuma's public status page JSON (R06b), no token
            seq("kuma GET " + self.path)
            d = (KUMA_BEATS if m.group(1) else KUMA_PAGES).get(m.group(2))
            return self.send(200, d) if d is not None else self.send(404, {"msg": "Not Found"})
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
        if re.match(r"^/applications/[^/]+/envs$", p):
            a = p.split("/")[2]
            return self.send(200, ENVS.get(a, []))
        if p == "/applications/a-gone": return self.send(404, {"message": "Application not found."})
        if p.startswith("/applications/") and p.count("/") == 2 and p.split("/")[2] in CREATED:
            return self.send(200, CREATED[p.split("/")[2]])
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
        if p == "/databases/db-stg":
            return self.send(200, {"uuid": "db-stg", "name": "shop-staging-db", "status": "running:healthy"})
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
        if p == "/projects":
            if os.path.exists(DOWN): return self.send(500, {"message": "Server Error"})
            return self.send(200, [{k: v[k] for k in ("id", "uuid", "name", "description")} for v in PROJECTS.values()])
        if p.startswith("/projects/") and p.count("/") == 2:
            u = p.split("/")[2]
            return self.send(200, PROJECTS[u]) if u in PROJECTS else self.send(404, {"message": "Project not found."})
        if p == "/applications": return self.send(200, APPS)
        if p == "/databases": return self.send(200, DBS)
        if p == "/services": return self.send(200, list(SERVICES.values()))
        if p.startswith("/services/"):
            u = p.split("/")[2]
            if u in KUMA_SVCS: return self.send(200, KUMA_SVCS[u])
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
        if self.path.startswith("/client/v4/"): return cf(self, "POST")
        p = self.path.removeprefix("/api/v1")
        if p.startswith("/deploy?uuid="):
            seq("deploy " + p.split("=")[1])
            return self.send(200, {"deployments": [{"deployment_uuid": "d-" + p.split("=")[1]}]})
        m = re.match(r"^/services/([^/]+)/restart$", p)
        if m:   # R22: no body; Coolify queues the restart [verify]. touch $HOME/restart.fail: one 500
            seq("service restart " + m.group(1))
            fl = os.path.join(os.path.dirname(sys.argv[2]), "restart.fail")
            if os.path.exists(fl):
                os.remove(fl); return self.send(500, {"message": "Server Error"})
            return self.send(200, {"message": "Service restarting request queued."})
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
        if p == "/projects":
            b = json.loads(body); seq("project POST %s" % json.dumps(b, sort_keys=True, separators=(",", ":")))
            u = "p-new%d" % len(PROJECTS); n = 10 + len(PROJECTS)
            PROJECTS[u] = {"id": n, "uuid": u, "name": b["name"], "description": b.get("description"),
                           "environments": [{"id": n, "uuid": "e%d" % n, "name": "production", "project_id": n}]}
            return self.send(201, {"uuid": u})
        if p.startswith("/projects/") and p.endswith("/environments"):
            u = p.split("/")[2]; b = json.loads(body)
            seq("environment POST %s %s" % (u, json.dumps(b, sort_keys=True, separators=(",", ":"))))
            if u not in PROJECTS: return self.send(404, {"message": "Project not found."})
            if any(e["name"] == b["name"] for e in PROJECTS[u]["environments"]):
                return self.send(422, {"message": "Validation failed.", "errors": {"name": ["The name has already been taken."]}})
            n = 100 + sum(len(v["environments"]) for v in PROJECTS.values())
            PROJECTS[u]["environments"].append({"id": n, "uuid": "e%d" % n, "name": b["name"]})
            return self.send(201, {"uuid": "e%d" % n, "name": b["name"]})
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
        if p == "/applications/private-deploy-key":
            b = json.loads(body); seq("app POST %s" % json.dumps(b, sort_keys=True, separators=(",", ":")))
            u = "a-new" if b["name"] == "shop-staging" else "a-" + b["name"]
            CREATED[u] = {"uuid": u, "name": b["name"], "status": "exited", "fqdn": None, "git_branch": b["git_branch"]}
            return self.send(201, {"uuid": u})
        if re.match(r"^/applications/[^/]+/envs$", p):
            b = json.loads(body); a = p.split("/")[2]
            seq("env POST %s %s preview=%s value=%s" % (a, b["key"], b.get("is_preview"), "ok" if b.get("value") == ENV_VAL else "ok2" if b.get("value") == "v-SECRET-1 a=b|c" else "other"))
            ENVS.setdefault(a, []).append(env("ev-new", b["key"]))
            return self.send(201, {"uuid": "ev-new", "echo": b})   # the value comes back: the lib must not print it
        if p.endswith("/rollback"):
            seq("rollback " + p.split("/")[2] + " " + json.loads(body)["commit"])
            return self.send(200, {"message": "Rollback deployment queued.", "deployment_uuid": "d-good"})
        self.send(201, {"echo": json.loads(body)})
    def do_PATCH(self):
        if self.path.startswith("/client/v4/"): return cf(self, "PATCH")
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
        m = re.match(r"^/services/([^/]+)/applications/([^/]+)$", p)
        if m:   # R22: the domains of one application of a service, as UpdateServiceApplicationFromApi in the 4.3.23 source
            u, a = m.groups(); url = b.get("url", "")
            seq("svcapp PATCH %s %s url=%s" % (u, a, url))
            if not isinstance(url, str) or "invalid.example.com" in url:
                return self.send(422, {"message": "Validation failed.", "errors": {"url": ["The url format is invalid."]}})
            if "race.example.com" in url:
                return self.send(409, {"message": "Domain conflicts detected. Use force_domain_override=true to proceed.",
                    "conflicts": [{"domain": "race.example.com", "resource_name": "starter", "resource_uuid": "a-starter",
                                   "resource_type": "application", "message": "Domain race.example.com is already in use by application 'starter'"}],
                    "warning": "Using the same domain for multiple resources can cause routing conflicts and unpredictable behavior."})
            svc = KUMA_SVCS.get(u) or SERVICES.get(u)
            app = next((x for x in (svc or {}).get("applications", []) if x["uuid"] == a), None)
            if app is None: return self.send(404, {"message": "Service application not found."})
            app["fqdn"] = ",".join(x.strip().lower() for x in url.split(",") if x.strip())
            return self.send(200, {"uuid": a, "name": app["name"], "fqdn": app["fqdn"]})
        if p.startswith("/applications/") and p.count("/") == 2:
            a = p.split("/")[2]
            seq("app PATCH %s %s" % (a, ",".join(sorted(b))))
            if a == "a-down": return self.send(500, {"message": "Server Error"})
            if a == "a-noauth" and b.get("is_http_basic_auth_enabled"):   # a refusal that quotes the password back
                return self.send(422, {"message": "Validation failed.", "errors": {"http_basic_auth_password": ["bad: %s" % b.get("http_basic_auth_password")]}})
            if "domains" in b: seq("app PATCH %s domains=%s health=%s:%s" % (a, b["domains"], b.get("health_check_path"), b.get("health_check_port")))
            if "is_http_basic_auth_enabled" in b:
                seq("app PATCH %s basic_auth=%s user=%s password=%s" % (a, b["is_http_basic_auth_enabled"], b.get("http_basic_auth_username"),
                    "absent" if "http_basic_auth_password" not in b else "ok" if b["http_basic_auth_password"] == "ba-SECRET-pass1" else "other"))
            if "manual_webhook_secret_github" in b:
                seq("app PATCH %s webhook=%s" % (a, "ok" if b["manual_webhook_secret_github"] == "wh-sec-0123456789abcdef" else "other"))
            if a in CREATED and "domains" in b: CREATED[a]["fqdn"] = b["domains"]
            return self.send(200, {"uuid": a})
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
        if self.path.startswith("/client/v4/"): return cf(self, "DELETE")
        p = self.path.removeprefix("/api/v1")
        seq("DELETE " + p)
        if p.startswith("/services/"): return self.send(200, {"message": "Deletion request queued."})
        if p.startswith("/applications/") or p.startswith("/databases/"):
            if p.startswith("/applications/a-gone"): return self.send(404, {"message": "Application not found."})
            return self.send(200, {"message": "Deletion request queued."})
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
  "run --rm --env-file "*" --json ls --recursive "*)
    # mc ls in a container: $4 env file, $7 image, ${11} s3/BUCKET/PREFIX
    want="MC_HOST_s3=https://AKFAKEKEY123:s3SeCrEt%2Fx%2By%3Dz%7Cw@fsn1.your-objectstorage.com"
    if [ "$(cat "$4")" = "$want" ]; then echo "envfile ok $(stat -c %a "$4")" >> "$HOME/envcheck.log"; else echo "envfile bad" >> "$HOME/envcheck.log"; fi
    echo "ls ${11}" >> "$HOME/mcls.log"
    [ "${FAKE_MC_LS_FAIL:-0}" = nokey ] && { echo '{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"Object does not exist"}}}'; exit 1; }
    [ "${FAKE_MC_LS_FAIL:-0}" = 1 ] && { echo '{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"The specified bucket does not exist."}}}'; exit 1; }
    cat "$HOME/mc-ls.json" 2>/dev/null; true ;;
  "run --rm --env-file "*)
    # mc in a container: $4 env file, $6 DIR:/out, $9 image, ${12} source, ${13} /out/NAME
    want="MC_HOST_s3=https://AKFAKEKEY123:s3SeCrEt%2Fx%2By%3Dz%7Cw@fsn1.your-objectstorage.com"
    if [ "$(cat "$4")" = "$want" ]; then echo "envfile ok $(stat -c %a "$4")" >> "$HOME/envcheck.log"; else echo "envfile bad" >> "$HOME/envcheck.log"; fi
    [ "${FAKE_MC_FAIL:-0}" = 1 ] && { echo "mc: <ERROR> Object does not exist." >&2; exit 1; }
    printf 'PGDMP fake object %s\n' "${12}" > "${6%:/out}/${13#/out/}" ;;
  "images "*) [ "${FAKE_NO_HELPER:-0}" = 1 ] || printf '%s\n' ghcr.io/coollabsio/coolify-helper:1.0.9 ghcr.io/coollabsio/coolify-helper:1.0.17 ;;
  "ps -q -f name="*) [ "${FAKE_NO_CONTAINER:-0}" = 1 ] || echo cid ;;
  "exec -i cid node -e "*)
    # kuma.js in the Kuma container (R06b): the plan on stdin, the script as node's -e argument
    printf '%s\n' "$*" > "$HOME/kuma.argv"; cat > "$HOME/kuma.stdin"
    case ${FAKE_KUMA:-sync_ok} in
      init_ok) echo '{"ok":true,"db_setup":true,"admin_created":true}' ;;
      init_again) echo '{"ok":true,"db_setup":false,"admin_created":false}' ;;
      init_exists) echo '{"ok":false,"msg":"admin exists and kuma.env does not open it (authIncorrectCreds)"}'; exit 1 ;;
      sync_ok) echo '(node:1) a warning on stderr' >&2; echo '{"ok":true,"added":["shop (shop.acme.example.com)"],"kept":["shop (www.shop.example.com)"],"page":"/status/acme-corp","groups":2}' ;;
      sync_again) echo '{"ok":true,"added":[],"kept":["shop (shop.acme.example.com)","shop (www.shop.example.com)"],"page":"/status/acme-corp","groups":1}' ;;
      tfa) echo '{"ok":false,"msg":"2FA is on for the Kuma admin; this script cannot log in with it."}'; exit 1 ;;
      garbage) echo "node:internal/modules/cjs/loader: Cannot find module" >&2; exit 1 ;;
      # the domain action (R22)
      domain_ok) echo '{"ok":true,"page":"/status/acme-corp","domains":["status.acme.com"],"added":["status.acme.com"],"removed":[],"absent":[],"changed":true}' ;;
      domain_same) echo '{"ok":true,"page":"/status/acme-corp","domains":["status.acme.com"],"added":[],"removed":[],"absent":[],"changed":false}' ;;
      domain_other_page) echo '{"ok":false,"msg":"status.beta.com is on status page beta; nothing changed"}'; exit 1 ;;
      domain_removed) echo '{"ok":true,"page":"/status/acme-corp","domains":[],"added":[],"removed":["status.acme.com"],"absent":[],"changed":true}' ;;
      domain_absent) echo '{"ok":true,"page":"/status/acme-corp","domains":[],"added":[],"removed":[],"absent":["status.acme.com"],"changed":false}' ;;
    esac ;;
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
check "service_create without a project" "$rc:$out" "1:service_create: no project: no PROJECT_UUID in $VPS_SETUP_STATE; run project_ensure (phase 05 step 3, PREPARE-APP.md step 5)"
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

# projects and environments (R09): slugs, find and ensure, the context new resources go into,
# domain defaults and conflicts, the inventory and PROJECTS.md; an old setup keeps working
got=""; for n in "Acme Corp" "  Shop--2026 " "ŁÓDŹ sklep" "a.b_c" "$(printf 'x%.0s' $(seq 1 70))-tail"; do got="${got}[$(project_slug "$n")]"; done
check "project_slug" "$got" "[acme-corp][shop-2026][d-sklep][a-b-c][$(printf 'x%.0s' $(seq 1 63))]"
out=$(project_slug '--' 2>&1); check "project_slug nothing usable" "$?:$out" "1:not a usable name: '--'"
out=$(project_slug "$(printf 'a%.0s' $(seq 1 62))-b" 2>&1); check "project_slug no dash at the cut" "$out" "$(printf 'a%.0s' $(seq 1 62))"
: > "$HOME/seq.log"
check "project_find one" "$(project_find "Acme Corp" 2>&1)" "p-acme"
out=$(project_find nobody 2>&1); check "project_find none" "$?:$out" "0:"
out=$(project_find twins 2>&1); check "project_find ambiguous" "$?:$out" "1:2 projects named twins; rename one in the Coolify UI (Projects)"
out=$(project_find '' 2>&1); check "project_find empty name" "$?:$out" "1:not a usable project name: '' (1 to 100 characters, no control characters)"
out=$(project_find $'a\nb' 2>&1); check "project_find control chars" "$?" "1"
check "project_find: read-only" "$(cat "$HOME/seq.log")" ""

PS1_STATE=$HOME/r09.state; rm -f "$PS1_STATE"
out=$(VPS_STATE=$PS1_STATE project_ensure "Beta Shop" "client: Beta" 2>&1); rc=$?
check "project_ensure creates" "$rc:$out" "0:project Beta Shop: p-new4 (created)"
check "project_ensure: exact body" "$(cat "$HOME/seq.log")" 'project POST {"description":"client: Beta","name":"Beta Shop"}'
check "project_ensure: state" "$(VPS_STATE=$PS1_STATE state_get PROJECT_UUID):$(VPS_STATE=$PS1_STATE state_get PROJECT_NAME)" "p-new4:Beta Shop"
: > "$HOME/seq.log"
out=$(VPS_STATE=$PS1_STATE project_ensure "Beta Shop" 2>&1); rc=$?
check "project_ensure reuses" "$rc:$out" "0:project Beta Shop: p-new4 (existing)"
check "project_ensure rerun: no POST" "$(cat "$HOME/seq.log")" ""
out=$(VPS_STATE=$PS1_STATE project_ensure twins 2>&1); rc=$?
check "project_ensure ambiguous: nothing created" "$rc:$out:$(cat "$HOME/seq.log")" "1:2 projects named twins; rename one in the Coolify UI (Projects):"
out=$(project_ensure 2>&1); check "project_ensure usage" "$?:$out" "1:usage: project_ensure NAME [DESCRIPTION]"

out=$(VPS_STATE=$PS1_STATE env_ensure p-acme staging 2>&1); rc=$?
check "env_ensure existing" "$rc:$out" "0:environment staging in project p-acme: existing"
check "env_ensure existing: no POST" "$(cat "$HOME/seq.log")" ""
out=$(VPS_STATE=$PS1_STATE env_ensure p-new4 staging 2>&1); rc=$?
check "env_ensure creates" "$rc:$out" "0:environment staging in project p-new4: created"
check "env_ensure: exact body" "$(cat "$HOME/seq.log")" 'environment POST p-new4 {"name":"staging"}'
check "env_ensure: state" "$(VPS_STATE=$PS1_STATE state_get ENV_NAME)" "staging"
: > "$HOME/seq.log"
for e in Staging 'qa env' -x 'a/b'; do
  out=$(env_ensure p-acme "$e" 2>&1); rc=$?
  check "env_ensure refuses '$e'" "$rc:$out" "1:not an environment name: '$e' (lower-case letters, digits and dashes, like staging)"
done
out=$(env_ensure ../x staging 2>&1); check "env_ensure bad uuid" "$?:$out" "1:not a Coolify uuid: '../x'"
out=$(env_ensure p-gone staging 2>&1); check "env_ensure unknown project" "$?:$out" '1:HTTP 404 GET /projects/p-gone: {"message": "Project not found."}'
check "env_ensure refused: nothing sent" "$(cat "$HOME/seq.log")" ""

# project_ctx: VPS_PROJECT, then PROJECT_UUID, then COOLIFY_PROJECT_UUID (an old .coolify.env), then the setup state
check "ctx: new state" "$(VPS_STATE=$PS1_STATE project_ctx 2>&1)" "p-new4 staging"
check "ctx: VPS_ENV wins" "$(VPS_STATE=$PS1_STATE VPS_ENV=production project_ctx 2>&1)" "p-new4 production"
check "ctx: VPS_PROJECT by name" "$(VPS_PROJECT="Acme Corp" project_ctx 2>&1)" "p-acme production"
out=$(VPS_PROJECT=nobody project_ctx 2>&1); check "ctx: VPS_PROJECT must exist" "$?:$out" "1:no project named nobody in Coolify; create it with project_ensure (PREPARE-APP.md step 5)"
out=$(VPS_PROJECT=twins project_ctx 2>&1); check "ctx: VPS_PROJECT ambiguous" "$?:$out" "1:2 projects named twins; rename one in the Coolify UI (Projects)"
out=$(VPS_STATE=$PS1_STATE VPS_ENV=Prod project_ctx 2>&1); check "ctx: bad VPS_ENV" "$?:$out" "1:not an environment name: 'Prod'"
printf 'COOLIFY_PROJECT_UUID=p-old\nCOOLIFY_APP_UUID=a1\n' > "$HOME/old-app.env"
check "ctx: old .coolify.env" "$(VPS_STATE=$HOME/old-app.env project_ctx 2>&1)" "p-old production"
printf 'COOLIFY_PROJECT_UUID=p-old\nPROJECT_UUID=p-acme\nENV_NAME=staging\n' > "$HOME/new-app.env"
check "ctx: PROJECT_UUID before COOLIFY_PROJECT_UUID" "$(VPS_STATE=$HOME/new-app.env project_ctx 2>&1)" "p-acme staging"
printf 'GH_REPO=u/x\n' > "$HOME/bare-app.env"
check "ctx: setup state as the last fallback" "$(VPS_STATE=$HOME/bare-app.env project_ctx 2>&1)" "proj-1 production"
check "ctx: old setup state (no ENV_NAME)" "$(project_ctx 2>&1)" "proj-1 production"
out=$(VPS_SETUP_STATE=$HOME/none.state VPS_STATE=$HOME/bare-app.env project_ctx 2>&1)
check "ctx: no project anywhere" "$?:$out" "1:no project: no PROJECT_UUID in $HOME/bare-app.env; run project_ensure (phase 05 step 3, PREPARE-APP.md step 5)"
printf 'PROJECT_UUID=../x\n' > "$HOME/bad-app.env"
out=$(VPS_STATE=$HOME/bad-app.env project_ctx 2>&1); check "ctx: bad uuid in the state" "$?:$out" "1:not a Coolify uuid: '../x'"

# service_create goes into the context's project and environment
: > "$HOME/seq.log"
VPS_STATE=$PS1_STATE service_create n8n flows flows.example.com >/dev/null 2>&1
has "service_create: environment from project_ctx" "$(cat "$HOME/seq.log")" '"environment_name":"staging".*"project_uuid":"p-new4"'
: > "$HOME/seq.log"
VPS_STATE=$PS1_STATE VPS_PROJECT="Acme Corp" VPS_ENV=production service_create n8n flows2 flows2.example.com >/dev/null 2>&1
has "service_create: VPS_PROJECT and VPS_ENV" "$(cat "$HOME/seq.log")" '"environment_name":"production".*"project_uuid":"p-acme"'

# app_domain_default: from DOMAIN in the setup state
DS=$HOME/r09-setup.state; printf 'DOMAIN=example.com\nSETUP_DIR=/home/u/vps-setup-one-shot\n' > "$DS"
got=""
for a in "starter|starter" "Acme Corp|Acme Corp" "Acme Corp|shop" "Acme Corp|shop|staging" "starter|starter|staging"; do
  IFS='|' read -r p1 p2 p3 <<<"$a"
  got="$got $(VPS_SETUP_STATE=$DS app_domain_default "$p1" "$p2" ${p3:+"$p3"} 2>&1)"
done
check "app_domain_default shapes" "$got" " starter.example.com acme-corp.example.com shop.acme-corp.example.com staging.shop.acme-corp.example.com staging.starter.example.com"
out=$(VPS_SETUP_STATE=$HOME/none.state app_domain_default starter starter 2>&1)
check "app_domain_default without DOMAIN" "$?:$out" "1:no DOMAIN in $HOME/none.state (phase 00, question 2)"
out=$(VPS_SETUP_STATE=$DS app_domain_default "$(printf 'a%.0s' $(seq 1 63))" "$(printf 'b%.0s' $(seq 1 63))" 2>&1)
check "app_domain_default checks the host" "$?" "0"
out=$(app_domain_default starter 2>&1); check "app_domain_default usage" "$?:$out" "1:usage: app_domain_default PROJECT APP [STAGE]"

# domain_in_use: apps (any of several fqdns, port and path ignored, case-insensitive) and services
out=$(domain_in_use starter.example.com); check "domain_in_use app" "$?:$out" "0:app starter"
out=$(domain_in_use www.shop.example.com); check "domain_in_use second fqdn with port" "$?:$out" "0:app shop"
out=$(domain_in_use Up.Example.com); check "domain_in_use service" "$?:$out" "0:service uptime-kuma (uptime-kuma)"
out=$(domain_in_use https://Starter.example.com:443/x); check "domain_in_use a pasted URL" "$?:$out" "0:app starter"
out=$(domain_in_use starter.example.com.); check "domain_in_use trailing dot" "$?:$out" "0:app starter"
out=$(domain_in_use free.example.com); check "domain_in_use free" "$?:$out" "1:"
out=$(domain_in_use example.com); check "domain_in_use no suffix match" "$?:$out" "1:"
cp "$COOLIFY_CONFIG" "$HOME/config.good"
printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=wrong\n' "$PORT" > "$COOLIFY_CONFIG"
domain_in_use starter.example.com >/dev/null 2>&1; check "domain_in_use unreadable" "$?" "2"
cat "$HOME/config.good" > "$COOLIFY_CONFIG"

# projects_inventory: exact TSV, unknown environment as - -, no secrets
: > "$HOME/seq.log"
out=$(projects_inventory 2>&1); rc=$?
T=$'\t'
check "projects_inventory" "$rc:$out" "0:project${T}environment${T}kind${T}name${T}status${T}fqdn${T}repo${T}uuid
Acme Corp${T}production${T}app${T}shop${T}running:healthy${T}https://shop.acme.example.com, https://WWW.Shop.example.com:443/x${T}https://github.com/acme/shop.git${T}a-shop
Acme Corp${T}staging${T}app${T}shop${T}exited:unhealthy${T}https://staging.shop.acme.example.com${T}git@github.com:acme/shop.git${T}a-shop-stg
Acme Corp${T}staging${T}service${T}uptime-kuma${T}exited${T}https://up.example.com${T}-${T}svc-kuma
starter${T}production${T}app${T}starter${T}running:healthy${T}https://starter.example.com${T}git@github.com:u/starter.git${T}a-starter
starter${T}production${T}db${T}starter-db${T}running:healthy${T}-${T}-${T}db-pg
starter${T}production${T}service${T}umami${T}running:healthy${T}https://stats.example.com${T}-${T}svc-umami
-${T}-${T}app${T}orphan|pipe${T}running:unknown${T}-${T}-${T}a-orphan"
check "projects_inventory: no secrets" "$(grep -cE 'SECRET|internal_db_url|postgres://|Bearer' <<<"$out")" "0"
check "projects_inventory: read-only" "$(cat "$HOME/seq.log")" ""

# projects_md: the file, mode 600, every project (empty ones too), no secrets; "-" prints it
PM=$HOME/.config/vps-setup/PROJECTS.md
out=$(VPS_SETUP_STATE=$DS projects_md 2>&1); rc=$?
check "projects_md rc:output" "$rc:$out" "0:wrote $PM (5 projects, 7 resources)"
check "projects_md mode" "$(stat -c %a "$PM" 2>/dev/null || stat -f %Lp "$PM")" "600"
md=$(cat "$PM")
has "projects_md: title" "$md" '^# Projects and what runs where$'
# shellcheck disable=SC2016 # the backticks are Markdown code, not a command substitution
{
  has "projects_md: regenerate command" "$md" '^`cd /home/u/vps-setup-one-shot && \. \./lib\.sh && projects_md`'
  has "projects_md: project heading" "$md" '^## Acme Corp$'
  has "projects_md: environment heading" "$md" '^### staging$'
  has "projects_md: description" "$md" '^Project uuid `p-starter`; created by vps-setup-one-shot\.$'
  has "projects_md: app row" "$md" '^\| app \| shop \| exited:unhealthy \| https://staging\.shop\.acme\.example\.com \| git@github\.com:acme/shop\.git \| `a-shop-stg` \|$'
}
has "projects_md: empty environment" "$md" '^Nothing in it yet\.$'
has "projects_md: project without environments" "$md" '^No environments\.$'
has "projects_md: unknown environment" "$md" '^## \(no project\)$'
has "projects_md: pipe escaped" "$md" '^\| app \| orphan\\\|pipe \| '
check "projects_md: twins both listed" "$(grep -c '^## twins$' <<<"$md")" "2"
check "projects_md: no secrets" "$(grep -cE 'SECRET|internal_db_url|postgres://|Bearer|abc=def' <<<"$md")" "0"
check "projects_md -: stdout, same body" "$(VPS_SETUP_STATE=$DS projects_md - 2>&1 | sed 1,3d)" "$(sed 1,3d "$PM")"
cp "$PM" "$HOME/pm.before"; touch "$HOME/projects.down"
out=$(projects_md 2>&1); rc=$?
check "projects_md API error" "$rc:$out" "1:HTTP 500 GET /projects: {\"message\": \"Server Error\"}
projects_md: could not read Coolify; $PM left as it was"
check "projects_md API error: file untouched" "$(cmp -s "$PM" "$HOME/pm.before" && echo same)" "same"
out=$(projects_inventory 2>/dev/null); check "projects_inventory API error" "$?:$out" "1:"
rm -f "$HOME/projects.down" "$PM.tmp"

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
has "plan: environment from project_ctx" "$(VPS_ENV=staging pg_major_upgrade_plan db-pg 18 2>&1)" '^ +project proj-1, environment staging, server s2$'
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

# rebuild (R15): the backups in the bucket itself, newest first, by the old database's uuid
P=data/coolify/backups/databases
cat > "$HOME/mc-ls.full" <<'JSON'
{"status":"success","type":"folder","lastModified":"2026-10-14T02:00:00Z","size":0,"key":"root-0/"}
{"status":"success","type":"file","lastModified":"2026-10-13T02:00:05.5Z","size":1000,"key":"root-0/my-landing-db-oldpg1/pg-dump-app-1760000001.dmp"}
{"status":"success","type":"file","lastModified":"2026-10-14T03:00:00+02:00","size":2048,"key":"root-0/my-landing-db-oldpg1/pg-dump-app-1760086401.dmp"}
{"status":"success","type":"file","lastModified":"2026-10-14T01:30:00Z","size":500,"key":"root-0/shop-db-oth2/pg-dump-shop-1760005000.dmp"}
{"status":"success","type":"file","lastModified":"2026-10-11T02:00:00Z","size":300,"key":"root-0/all-db-dall3/pg-dump-all-1759900000.gz"}
{"status":"success","type":"file","lastModified":"2026-10-15T02:00:00Z","size":7,"key":"stray.txt"}
not json
{"status":"success","type":"file","lastModified":"2026-10-12T02:00:00.123456789Z","size":900,"key":"data/coolify/backups/databases/root-0/my-landing-db-oldpg1/pg-dump-app-1759999999.dmp"}
JSON
cp "$HOME/mc-ls.full" "$HOME/mc-ls.json"; : > "$HOME/envcheck.log"; : > "$HOME/mcls.log"
s3run s3_backup_list
check "s3 list rc" "$rc" "0"
check "s3 list header" "$(head -1 <<<"$out")" "$(printf 'db_uuid\tlast_modified\tsize\tkey')"
check "s3 list: newest first across offsets" "$(sed -n '2,$p' <<<"$out" | cut -f1,2 | paste -sd ' ' -)" \
  "$(printf 'oth2\t2026-10-14T01:30:00Z oldpg1\t2026-10-14T03:00:00+02:00 oldpg1\t2026-10-13T02:00:05.5Z oldpg1\t2026-10-12T02:00:00.123456789Z dall3\t2026-10-11T02:00:00Z')"
check "s3 list: folders, short keys and non-JSON skipped, every file once" "$(($(wc -l <<<"$out") - 1))" "5"
check "s3 list: a dump_all backup is listed with its .gz key" "$(grep -c 'dall3.*pg-dump-all-1759900000.gz$' <<<"$out")" "1"
check "s3 list: mc lists the backup prefix of the bucket" "$(cat "$HOME/mcls.log")" "ls s3/my-backups/$P/"
check "s3 list: mc got the creds from a 600 env file" "$(cat "$HOME/envcheck.log")" "envfile ok 600"
check "s3 list: env file deleted" "$(ls -A "$HOME/srvtmp")" ""
s3run s3_backup_list oldpg1
check "s3 list by uuid" "$rc:$(sed -n 2p <<<"$out")" "0:$(printf 'oldpg1\t2026-10-14T03:00:00+02:00\t2048\t%s/root-0/my-landing-db-oldpg1/pg-dump-app-1760086401.dmp' "$P")"
check "s3 list by uuid: only that database" "$(sed -n '2,$p' <<<"$out" | cut -f1 | sort -u)" "oldpg1"
check "s3 list: a full key is kept whole" "$(tail -1 <<<"$out" | cut -f4)" "$P/root-0/my-landing-db-oldpg1/pg-dump-app-1759999999.dmp"
s3run s3_backup_list gone9
check "s3 list: no backups for that uuid" "$rc:$out" "1:no backups for database gone9 in s3/my-backups/$P/ (backups there are of: dall3 oldpg1 oth2)"
: > "$HOME/mc-ls.json"
s3run s3_backup_list
check "s3 list: empty bucket" "$rc:$out" "1:no backups in s3/my-backups/$P/"
FAKE_MC_LS_FAIL=1 s3run s3_backup_list
check "s3 list: mc error" "$rc:$out" "1:listing of s3/my-backups/$P/ failed: The specified bucket does not exist. (wrong key pair or bucket: phase 06 step 1a and 1b)"
FAKE_MC_LS_FAIL=nokey s3run s3_backup_list
check "s3 list: missing prefix is no backups, not bad keys" "$rc:$out" "1:no backups in s3/my-backups/$P/ (Object does not exist)"
check "s3 list failure: env file deleted" "$(ls -A "$HOME/srvtmp")" ""
s3run s3_backup_list 'x;rm'
check "s3 list: bad uuid refused" "$rc:$out" "1:s3_backup_list: not a database uuid: 'x;rm'"
: > "$HOME/seq.log"
S3_ENV="$HOME/nope.env" s3run s3_backup_list oldpg1
check "s3 list without creds refused, no ssh" "$rc:$out:$(cat "$HOME/seq.log")" "1:no S3 credentials: $HOME/nope.env is missing (phase 06 step 1):"
s3u=$(state_get S3_STORAGE_UUID); state_set S3_STORAGE_UUID ''; VPS_STATE=$VPS_SETUP_STATE state_set S3_STORAGE_UUID ''
: > "$HOME/seq.log"
s3run s3_backup_list oldpg1
check "s3 list without S3_STORAGE_UUID refused, no ssh" "$rc:$out:$(cat "$HOME/seq.log")" "1:s3_backup_list: no S3_STORAGE_UUID in $VPS_SETUP_STATE or $VPS_SETUP_STATE (phase 06 step 1b):"
state_set S3_STORAGE_UUID "$s3u"
# a backup of the old database goes into the new one: fetched into DUMP_DIR/<new>/, so
# db_restore's guard passes without RESTORE_FROM_DB (source dir == target)
s3run db_fetch_from_s3 db-pg18 "$P/root-0/my-landing-db-oldpg1/pg-dump-app-1760086401.dmp"
got="$HOME/dumps/db-pg18/s3-pg-dump-app-1760086401.dmp"
check "rebuild fetch into the new database" "$rc:$out" "0:$got $(stat -c %s "$got" 2>/dev/null)"
s3run db_restore db-pg18 "$got"
check "rebuild restore without RESTORE_FROM_DB" "$rc:$(tail -1 <<<"$out")" "0:restored $got into app"
printf 'APP_NAME=shop\n' > "$HOME/app.state"; cp "$HOME/mc-ls.full" "$HOME/mc-ls.json"
VPS_STATE="$HOME/app.state" s3run s3_backup_list oth2
check "s3 list from an app's state: storage uuid from the setup state" "$rc:$(sed -n 2p <<<"$out" | cut -f1)" "0:oth2"

# rebuild_inventory: read only; survivors, the old server's keys, the commands
RS="$HOME/rebuild.state"
printf 'PROVIDER=hetzner\nDOMAIN=example.com\nVPS_IP=203.0.113.9\nADMIN_REGISTERED=1\nDB_UUID=oldpg1\nAPP_UUID=app1\nHOOK_ID=42\nWEBHOOK=github\nS3_BUCKET=my-backups\nS3_STORAGE_UUID=s3-1\nSERVICE_UMAMI_UUID=svc1\nKEY_UUID=\nHANDOVER_DONE=1\nAPP_DIR=/home/u/my-landing\nUPTIME_SERVICE=uptime-kuma\nUPTIME_URL=https://status.example.com\nUPTIME_PAGES=acme\n' > "$RS"
before=$(cksum < "$RS"); cfg_before=$(cksum < "$COOLIFY_CONFIG"); ls_before=$(ls -A "$(dirname "$COOLIFY_CONFIG")" "$HOME")
out=$(VPS_SETUP_STATE=$RS VPS_STATE=$RS rebuild_inventory 2>&1); rc=$?
d=$(date -u +%Y%m%d)
check "rebuild inventory" "$rc:$out" "0:state: $RS
survives (kept as is):
  PROVIDER=hetzner
  DOMAIN=example.com
  S3_BUCKET=my-backups
  APP_DIR=/home/u/my-landing
  UPTIME_URL=https://status.example.com
belongs to the old server (cleared before phase 01):
  VPS_IP=203.0.113.9
  ADMIN_REGISTERED=1
  DB_UUID=oldpg1
  APP_UUID=app1
  HOOK_ID=42
  WEBHOOK=github
  S3_STORAGE_UUID=s3-1
  SERVICE_UMAMI_UUID=svc1
  HANDOVER_DONE=1
  UPTIME_SERVICE=uptime-kuma
  UPTIME_PAGES=acme
old database: oldpg1; its backups: s3_backup_list oldpg1 (the copy below keeps the uuid)
commands, after the user's yes (rebuild_inventory changed nothing):
  cp -p $RS $RS.before-rebuild-$d
  state_set VPS_IP ''
  state_set ADMIN_REGISTERED ''
  state_set DB_UUID ''
  state_set APP_UUID ''
  state_set HOOK_ID ''
  state_set WEBHOOK ''
  state_set S3_STORAGE_UUID ''
  state_set SERVICE_UMAMI_UUID ''
  state_set HANDOVER_DONE ''
  state_set UPTIME_SERVICE ''
  state_set UPTIME_PAGES ''
  mv $COOLIFY_CONFIG $COOLIFY_CONFIG.before-rebuild-$d"
check "rebuild inventory writes nothing" "$(cksum < "$RS"):$(cksum < "$COOLIFY_CONFIG"):$(ls -A "$(dirname "$COOLIFY_CONFIG")" "$HOME")" "$before:$cfg_before:$ls_before"
printf '# old server\n' > "$HOME/SERVER.md"; printf '# Projects\n' > "$HOME/PROJECTS.md"
out=$(VPS_SETUP_STATE=$RS VPS_STATE=$RS rebuild_inventory 2>&1)
check "rebuild inventory: SERVER.md copied before phase 06 overwrites it" "$(grep -c "^  cp -p $HOME/SERVER.md $HOME/SERVER.md.before-rebuild-$d$" <<<"$out")" "1"
check "rebuild inventory: PROJECTS.md copied too" "$(grep -c "^  cp -p $HOME/PROJECTS.md $HOME/PROJECTS.md.before-rebuild-$d$" <<<"$out")" "1"
rm -f "$HOME/SERVER.md" "$HOME/PROJECTS.md"
printf 'COOLIFY_PROJECT_UUID=p1\nCOOLIFY_APP_UUID=a1\nCOOLIFY_DOMAIN=https://shop.example.com\nDB_UUID=shopdb\nGH_REPO=u/shop\n' > "$HOME/app.state"
out=$(VPS_STATE="$HOME/app.state" rebuild_inventory 2>&1); rc=$?
has "rebuild inventory of an app: keeps the app's URL" "$out" '^  COOLIFY_DOMAIN=https://shop\.example\.com$'
has "rebuild inventory of an app: sets VPS_STATE first" "$out" "^  VPS_STATE=$HOME/app.state$"
has "rebuild inventory of an app: clears its uuids" "$out" "^  state_set COOLIFY_APP_UUID ''$"
case "$out" in *"mv "*) check "rebuild inventory of an app: the Coolify config stays" moved kept ;; *) check "rebuild inventory of an app: the Coolify config stays" ok ok ;; esac
out=$(VPS_STATE="$HOME/none.state" rebuild_inventory 2>&1); rc=$?
check "rebuild inventory without state" "$rc:$out" "1:rebuild_inventory: no state in $HOME/none.state"

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

# DNS through the Cloudflare API (R18): fake API under /client/v4 on the same server
CFE="$HOME/.config/vps-setup/cloudflare.env"; CFT=FAKE-cf-token_000
export CF_API="http://127.0.0.1:$PORT/client/v4"
Z=0123456789abcdef0123456789abcdef
state_set DOMAIN app.sub.example.com
: > "$HOME/seq.log"
s3run cf_check
check "cf: missing cloudflare.env refused" "$rc:$out" "1:no Cloudflare token: $CFE is missing (phase 00, question 6)"
( umask 022; printf 'CF_API_TOKEN=%s\n' "$CFT" > "$CFE" )
s3run cf_check
check "cf: cloudflare.env mode 644 refused" "$rc:$out" "1:refusing $CFE: mode 644, must be 600 (chmod 600 $CFE)"
chmod 600 "$CFE"
CF_ENV="$HOME/empty.env" s3run cf_check
check "cf: file without the token line refused" "$rc:$out" "1:$HOME/empty.env needs a CF_API_TOKEN= line"
( umask 077; printf 'CF_API_TOKEN=abc"def\n' > "$HOME/cfq.env" )
CF_ENV="$HOME/cfq.env" s3run cf_check
check "cf: token with a quote refused" "$rc:$out" "1:CF_API_TOKEN in $HOME/cfq.env has characters a Cloudflare token does not have; write it again (phase 00, question 6)"
check "cf: nothing sent while refused" "$(cat "$HOME/seq.log")" ""
( umask 077; printf 'CF_API_TOKEN=FAKE-cf-invalid\n' > "$HOME/cfbad.env"; printf 'CF_API_TOKEN=FAKE-cf-expired\n' > "$HOME/cfexp.env" )
CF_ENV="$HOME/cfbad.env" s3run cf_check
check "cf: invalid token, Cloudflare's code and message" "$rc:$out" "1:Cloudflare refused GET /user/tokens/verify (HTTP 401):
  1000: Invalid API Token
The Cloudflare token does not work; create a new one (phase 00, question 6)"
CF_ENV="$HOME/cfexp.env" s3run cf_check
check "cf: expired token" "$rc:$out" "1:Cloudflare token is expired, not active; create a new one (phase 00, question 6)"
: > "$HOME/seq.log"
s3run cf_check
check "cf check: longest suffix that is a zone" "$rc:$out" "0:Cloudflare token active; zone example.com ($Z), status active"
check "cf check: tried the suffixes, longest first" "$(cat "$HOME/seq.log")" "cf GET /user/tokens/verify
cf GET /zones?name=app.sub.example.com
cf GET /zones?name=sub.example.com
cf GET /zones?name=example.com"
check "cf check: state" "$(state_get CF_ZONE_ID) $(state_get CF_ZONE)" "$Z example.com"
state_set DOMAIN x.deep.example.org
s3run cf_check
check "cf check: a sub-zone wins over its parent" "$rc:$out" "0:Cloudflare token active; zone deep.example.org (2123456789abcdef0123456789abcdef), status active"
state_set DOMAIN shop.example.org
s3run cf_check
check "cf check: zone not active is a warning" "$rc:$out" "0:Cloudflare token active; zone example.org (1123456789abcdef0123456789abcdef), status pending
warning: zone example.org is pending, not active: its records do not resolve until the domain's name servers are Cloudflare's"
state_set DOMAIN example.net
s3run cf_check
check "cf check: zone not found" "$rc:$out" "1:no Cloudflare zone for example.net that this token can read; create an \"Edit zone DNS\" token for that zone (phase 00, question 6)"
check "cf check: state keeps the last zone found" "$(state_get CF_ZONE)" "example.org"
state_set DOMAIN example.com; s3run cf_check
check "cf check back on example.com" "$rc" "0"

: > "$HOME/seq.log"
s3run dns_set_a app.example.com 203.0.113.10
check "dns create" "$rc:$out" "0:app.example.com: A created -> 203.0.113.10 (DNS only, TTL auto)"
check "dns create: one lookup, one POST, DNS only" "$(cat "$HOME/seq.log")" "cf GET /zones/$Z/dns_records?name=app.example.com&per_page=100
cf POST /zones/$Z/dns_records {\"comment\":\"vps-setup\",\"content\":\"203.0.113.10\",\"name\":\"app.example.com\",\"proxied\":false,\"ttl\":1,\"type\":\"A\"}"
: > "$HOME/seq.log"
s3run dns_set_a app.example.com 203.0.113.10
check "dns again: unchanged, nothing written" "$rc:$out:$(grep -c -v ' GET ' "$HOME/seq.log")" "0:app.example.com: A unchanged (203.0.113.10, DNS only):0"
: > "$HOME/seq.log"
s3run dns_set_a old.example.com 203.0.113.10
check "dns update: old IP and proxy said" "$rc:$out" "0:old.example.com: A updated 198.51.100.7 -> 203.0.113.10 (DNS only, proxy was on)"
has "dns update: PATCH with proxied false" "$(cat "$HOME/seq.log")" "^cf PATCH /zones/$Z/dns_records/[0-9a-f]{32} \{\"content\":\"203\.0\.113\.10\",\"proxied\":false\}$"
: > "$HOME/seq.log"
s3run dns_set_a www.example.com 203.0.113.10
check "dns CNAME refused" "$rc:$out" "1:www.example.com is a CNAME to example.com; an A record cannot sit next to it. Nothing changed. If the CNAME is not needed, the user deletes it in Cloudflare (DNS -> Records), then run this again."
s3run dns_set_a two.example.com 203.0.113.10
check "dns two A refused" "$rc:$out" "1:two.example.com has 2 A records; nothing changed. The user keeps one (or deletes all) in Cloudflare (DNS -> Records), then run this again:
  A 198.51.100.1 proxied false
  A 198.51.100.2 proxied false"
check "dns refusals sent no write" "$(grep -c -v ' GET ' "$HOME/seq.log")" "0"
s3run dns_set_a v6.example.com 203.0.113.10
check "dns AAAA: rc 2 after the A is set" "$rc:$out" "2:v6.example.com: A created -> 203.0.113.10 (DNS only, TTL auto)
warning: v6.example.com also has an AAAA record (2001:db8::1); IPv6 visitors and the certificate go there. The user deletes it in Cloudflare (DNS -> Records); this script never deletes records."
s3run dns_set_a busy.example.com 203.0.113.10
check "dns 429 said as the rate limit" "$rc:$out" "1:Cloudflare rate limit (HTTP 429 on GET /zones/$Z/dns_records?name=busy.example.com&per_page=100): at most 1200 requests per 5 minutes; wait 5 minutes, then run it again"
: > "$HOME/seq.log"
s3run dns_set_a 'a b.example.com' 203.0.113.10
check "dns bad name refused" "$rc:$out" "1:not a host name: 'a b.example.com' (lower case, like app.example.com)"
s3run dns_set_a app.example.com 203.0.113.256
check "dns bad IP refused" "$rc:$out" "1:not an IPv4 address: '203.0.113.256'"
s3run dns_set_a app.example.com 2001:db8::2
check "dns IPv6 refused" "$rc:$out" "1:not an IPv4 address: '2001:db8::2'"
s3run dns_set_a app.example.com 127.0.0.1
check "dns loopback refused" "$rc:$out" "1:not a public IPv4 address: '127.0.0.1'"
s3run dns_set_a app.example.com 203.0.113.010
check "dns leading zero refused" "$rc:$out" "1:not an IPv4 address (leading zero): '203.0.113.010'"
s3run dns_set_a app.example.net 203.0.113.10
check "dns name outside the zone refused" "$rc:$out" "1:app.example.net is not in the Cloudflare zone example.com"
check "dns: bad input sent nothing" "$(cat "$HOME/seq.log")" ""
s3run dns_list old.example.com
check "dns list" "$rc:$out" "0:$(printf 'type\tcontent\tproxied\tttl\nA\t203.0.113.10\tfalse\t1\nMX\tmx.example.net\tfalse\t1')"
s3run dns_list nothing.example.com
check "dns list, no records" "$rc:$out" "0:no records for nothing.example.com"
VPS_STATE="$HOME/app.coolify.env" s3run dns_set_a app.example.com 203.0.113.10
check "dns with VPS_STATE on an app's .coolify.env: zone from the setup state" "$rc:$out" "0:app.example.com: A unchanged (203.0.113.10, DNS only)"
check "cf: never a DELETE" "$(grep -c '^cf DELETE' "$HOME/seq.log")" "0"
check "cf: body temp files deleted" "$(ls -A "$HOME/srvtmp")" ""
has "cf: token handed to curl on stdin" "$(cat "$HOME/argv.log")" '^curl .* -K - .*/client/v4/user/tokens/verify$'
unset CF_API

# monthly checkup (R16): advisories, backup success rate, the checkup log, hcloud read-only,
# the server facts script
export ADVISORIES_URL="http://127.0.0.1:$PORT/gh/advisories"
s3run coolify_advisories 4.3.23
check "advisories: TSV, affected yes/no/unknown" "$rc:$out" "0:$(printf 'ghsa_id\tseverity\tpublished\tvulnerable\tpatched\taffected
GHSA-old0-0000-0000\tcritical\t2025-01-10\t< 4.0.0-beta.420\t4.0.0-beta.420\tno
GHSA-new0-0000-0000\thigh\t2026-10-01\t>= 4.0.0, <= 4.3.23\t4.3.24\tyes
GHSA-none-0000-0000\tmedium\t2026-02-01\t?\t?\tunknown')"
s3run coolify_advisories v4.3.24
check "advisories: patched version not affected" "$(cut -f1,6 <<<"$out" | sed -n 3p)" "$(printf 'GHSA-new0-0000-0000\tno')"
s3run coolify_advisories 4.0.0-beta.419
check "advisories: a beta before the fix is affected" "$(cut -f1,6 <<<"$out" | sed -n 2p)" "$(printf 'GHSA-old0-0000-0000\tyes')"
ADVISORIES_URL="http://127.0.0.1:$PORT/gh/limit" s3run coolify_advisories 4.3.23
check "advisories: rate limit is rc 2" "$rc:$out" "2:GitHub rate limit (HTTP 403; 60 calls an hour without a token)"
ADVISORIES_URL="http://127.0.0.1:$PORT/gh/odd" s3run coolify_advisories 4.3.23
check "advisories: not a list is rc 2" "$rc:$out" "2:the advisories answer is not a list"
ADVISORIES_URL="http://127.0.0.1:9/gh" s3run coolify_advisories 4.3.23
check "advisories: offline is rc 2" "$rc:$out" "2:GitHub did not answer (offline?)"
s3run coolify_advisories latest
check "advisories: version required" "$rc:$out" "1:usage: coolify_advisories VERSION (like 4.3.23)"
check "advisories: no version compare surprises" "$(jq -rn "$JQ_VERSION"'[("4.0.0-beta.420" | ver) < ("4.0.0" | ver), ("4.3" | ver) == ("4.3.0" | ver),
  ("4.3.9" | ver) < ("4.3.23" | ver), ("< 4.3.21" | range_match("4.3.21")), (">4.3.0,<4.3.30" | range_match("4.3.23")), ("~4.3" | range_match("4.3.23")),
  ("< 4.0.0-beta.420.7" | range_match("4.0.0-beta.419")), ("< 4.0.0-beta.420.7" | range_match("4.0.0-beta.420.6")),
  ("< 4.0.0-beta.420.7" | range_match("4.0.0-beta.420.7")), ("4.0.0-beta.420.6" | ver) < ("4.0.0" | ver)] | map(tostring) | join(" ")')" \
  "true true true false true null true true false true"

s3run backup_success_rate db-rate
check "backup rate: last 30 days, running not counted, S3 failures counted" "$rc:$out" "0:$(printf 'schedule\tfrequency\truns\tsuccess\tfailed\ts3\ts3_uploaded\ts3_failed\ts3_unreported\tnewest_failure
bk-rate\t0 2 * * *\t6\t5\t1\tyes\t4\t1\t0\t%s
bk-local\t0 3 * * *\t2\t2\t0\tno\t0\t0\t0\t-' "$(date -u -d '-2 days' +%F)")"
s3run backup_success_rate db-rate 50
check "backup rate: DAYS widens the window" "$(sed -n 2p <<<"$out" | cut -f3-5)" "$(printf '7\t5\t2')"
s3run backup_success_rate db-rate 0
check "backup rate: DAYS 0 refused" "$rc:$out" "1:backup_success_rate: DAYS must be a whole number above 0, got '0'"
s3run backup_success_rate 'db/../x'
check "backup rate: bad uuid refused" "$rc:$out" "1:not a Coolify uuid: 'db/../x'"
s3run backup_success_rate db-empty
check "backup rate: no schedule is just the header" "$rc:$(wc -l <<<"$out")" "0:1"

# the checkup log: TSV, mode 600, the sample to compare with
export CHECKUP_LOG="$HOME/.config/vps-setup/checkup.log"; NOW=1790000000
s3run checkup_sample_append $((NOW - 40 * 86400)) 203.0.113.9 1000 40000 10 20 4.51
s3run checkup_sample_append $((NOW - 25 * 86400)) 203.0.113.9 2000 40000 10 20 4.51
s3run checkup_sample_append $((NOW - 5 * 86400)) 203.0.113.9 3000 40000 10 20 -
s3run checkup_sample_append $((NOW - 30 * 86400)) 198.51.100.4 9000 40000 0 0 9.02
check "checkup log: four lines, mode 600" "$(wc -l < "$CHECKUP_LOG"):$(stat -c %a "$CHECKUP_LOG" 2>/dev/null || stat -f %Lp "$CHECKUP_LOG")" "4:600"
check "checkup log: line format" "$(sed -n 1p "$CHECKUP_LOG")" "$(printf '%s\t%s\t203.0.113.9\t1000\t40000\t10\t20\t4.51' "$(date -u -d "@$((NOW - 40 * 86400))" +%F)" "$((NOW - 40 * 86400))")"
check "checkup prev: newest at least 20 days old" "$(checkup_sample_prev 203.0.113.9 "$NOW" | cut -f4)" "2000"
check "checkup prev: none old enough -> the oldest" "$(checkup_sample_prev 203.0.113.9 "$NOW" 60 | cut -f4)" "1000"
check "checkup prev: another server's lines ignored" "$(checkup_sample_prev 198.51.100.4 "$NOW" | cut -f4)" "9000"
checkup_sample_prev 192.0.2.1 "$NOW" >/dev/null; check "checkup prev: unknown server" "$?" "1"
CHECKUP_RECORD=0 s3run checkup_sample_append "$NOW" 203.0.113.9 1 2 3 4 5
check "checkup log: CHECKUP_RECORD=0 writes nothing" "$rc:$(wc -l < "$CHECKUP_LOG")" "0:4"
s3run checkup_sample_append "$NOW" 'a b' 1 2 3 4 5
check "checkup log: bad server refused" "$rc:$out:$(wc -l < "$CHECKUP_LOG")" "1:checkup_sample_append: not a server name or address: 'a b':4"
s3run checkup_sample_append "$NOW" 203.0.113.9 1 2 3 4 '5;rm'
check "checkup log: bad cost refused" "$rc" "1"
rm -f "$CHECKUP_LOG"; ( umask 022; touch "$CHECKUP_LOG" )
s3run checkup_sample_append "$NOW" 203.0.113.9 1 2 3 4 -
check "checkup log: an existing log made private" "$(stat -c %a "$CHECKUP_LOG" 2>/dev/null || stat -f %Lp "$CHECKUP_LOG")" "600"
unset CHECKUP_LOG

# hcloud only through hcloud_json: list and describe, never anything that changes something
mkdir -p "$HOME/hbin"
cat > "$HOME/hbin/hcloud" <<'STUB'
#!/bin/sh
echo "hcloud $*" >> "$HOME/hcloud.log"
[ "${FAKE_HCLOUD_FAIL:-0}" = 1 ] && { echo 'hcloud: no active context or token' >&2; exit 1; }
case "$1 $2 $3" in
  "firewall describe vps-setup-fw") echo '{"id": 7, "name": "vps-setup-fw", "rules": [
    {"direction": "in", "protocol": "tcp", "port": "22", "source_ips": ["0.0.0.0/0", "::/0"]},
    {"direction": "in", "protocol": "icmp", "port": null, "source_ips": ["0.0.0.0/0", "::/0"]}],
    "applied_to": [{"type": "label_selector", "applied_to_resources": [{"type": "server", "server": {"id": 42}}]}]}' ;;
  "server describe coolify-1") echo '{"id": 42, "name": "coolify-1"}' ;;
  "server describe other-1") echo '{"id": 43, "name": "other-1"}' ;;
  "server list -o") echo '[{"id": 42, "name": "coolify-1", "server_type": {"name": "cx22", "prices": [
    {"location": "nbg1", "price_monthly": {"net": "3.7900000000", "gross": "4.5101000000"}},
    {"location": "fsn1", "price_monthly": {"net": "3.7900000000", "gross": "4.6000000000"}}]},
    "datacenter": {"name": "fsn1-dc14", "location": {"name": "fsn1"}}, "backup_window": "22-02"}]' ;;
  "primary-ip list -o") echo '[{"name": "primary_ip-1", "type": "ipv4", "datacenter": {"location": {"name": "fsn1"}}}]' ;;
  "volume list -o") echo '[]' ;;
  *) echo "hcloud: unexpected" >&2; exit 2 ;;
esac
STUB
chmod +x "$HOME/hbin/hcloud"; : > "$HOME/hcloud.log"
PATH="$HOME/hbin:$PATH" s3run hcloud_json server delete coolify-1
check "hcloud_json: delete refused" "$rc:$out" "1:hcloud_json: only list and describe are allowed (read-only), got 'server delete'"
PATH="$HOME/hbin:$PATH" s3run hcloud_json firewall add-rule vps-setup-fw
check "hcloud_json: add-rule refused" "$rc" "1"
PATH="$HOME/hbin:$PATH" s3run hcloud_json server describe coolify-1 --poweroff
check "hcloud_json: flags refused" "$rc:$out" "1:hcloud_json: no flags allowed, got '--poweroff'"
PATH="$HOME/hbin:$PATH" s3run hcloud_json '--context=x' list
check "hcloud_json: resource checked" "$rc" "1"
check "hcloud_json: refusals never ran hcloud" "$(cat "$HOME/hcloud.log")" ""
PATH="$HOME/hbin:$PATH" s3run firewall_rules
check "firewall_rules" "$rc:$out" "0:$(printf 'direction\tproto\tport\tsources\nin\ttcp\t22\t0.0.0.0/0,::/0\nin\ticmp\t-\t0.0.0.0/0,::/0')"
PATH="$HOME/hbin:$PATH" firewall_applied vps-setup-fw coolify-1; check "firewall_applied: through a label selector" "$?" "0"
PATH="$HOME/hbin:$PATH" firewall_applied vps-setup-fw other-1; check "firewall_applied: another server" "$?" "1"
PATH="$HOME/hbin:$PATH" s3run server_cost
check "server_cost: the location's gross price, backups, IPs and volumes" "$rc:$out" "0:$(printf 'kind\tname\ttype\tlocation\tmonthly_gross_eur\tbackups
server\tcoolify-1\tcx22\tfsn1\t4.6\ton
primary-ip\tprimary_ip-1\tipv4\tfsn1\t-\t-')"
FAKE_HCLOUD_FAIL=1 PATH="$HOME/hbin:$PATH" s3run firewall_rules
check "hcloud failing: said with the phase" "$rc:$out" '1:hcloud firewall describe failed: hcloud: no active context or token (not installed or not logged in? phase 01 step 1)'
check "hcloud: only list and describe ever ran" "$(grep -cvE '^hcloud [a-z-]+ (list|describe)( [a-z0-9-]+)? -o json$' "$HOME/hcloud.log")" "0"
PATH=/usr/bin:/bin s3run hcloud_json server list
check "hcloud missing" "$rc:$out" "1:hcloud not installed or not logged in (phase 01 step 1)"

# checkup_server_facts: the server script runs (here locally, with fake tools) and prints tags
mkdir -p "$HOME/factbin"
cat > "$HOME/factbin/ss" <<'STUB'
#!/bin/sh
case $1 in
  -tlnpH) echo 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
          echo 'LISTEN 0 4096 [::]:8000 [::]:* users:(("docker-proxy",pid=9,fd=4))'
          echo 'LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*' ;;
  -ulnpH) echo 'UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=2,fd=13))' ;;
esac
STUB
cat > "$HOME/factbin/sshd" <<'STUB'
#!/bin/sh
printf 'port 22\npasswordauthentication no\npermitrootlogin without-password\nx11forwarding no\n'
STUB
cat > "$HOME/factbin/ssh-keygen" <<'STUB'
#!/bin/sh
echo '256 SHA256:fakeKeyOne dev@example.invalid (ED25519)'
STUB
cat > "$HOME/factbin/ps" <<'STUB'
#!/bin/sh
echo '/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375 --containerd=/run/containerd/containerd.sock'
STUB
cat > "$HOME/factbin/docker" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "ps -aq") echo c1 ;;
  "inspect -f") echo '/coolify-proxy traefik:v3.6 false sock:ro' ;;
  "system df") printf 'Images\t2.1GB\t1.4GB (66%%)\n' ;;
esac
STUB
chmod +x "$HOME/factbin/"*
cat > "$HOME/factbin/fake-rssh" <<'STUB'
#!/bin/sh
cat > "$HOME/facts.stdin"; echo "$*" > "$HOME/facts.args"
PATH="$HOME/factbin:$PATH" sh "$HOME/facts.stdin"
STUB
chmod +x "$HOME/factbin/fake-rssh"
out=$(CHECKUP_SSH="$HOME/factbin/fake-rssh" checkup_server_facts 2>&1); rc=$?
check "facts: one ssh call with sh -s" "$rc:$(cat "$HOME/facts.args")" "0:sh -s"
has "facts: tcp listener with process" "$out" '^listen tcp \[::\]:8000 docker-proxy$'
has "facts: listener without process" "$out" '^listen tcp 127\.0\.0\.1:5432 \?$'
has "facts: udp listener" "$out" '^listen udp 127\.0\.0\.53%lo:53 systemd-resolve$'
has "facts: sshd keys, others dropped" "$out" '^sshd permitrootlogin without-password$'
check "facts: x11forwarding not asked for" "$(grep -c x11 <<<"$out")" "0"
has "facts: key without its comment" "$out" '^authkey 256 SHA256:fakeKeyOne \(ED25519\)$'
check "facts: no key comment (email) printed" "$(grep -c 'example.invalid' <<<"$out")" "0"
has "facts: dockerd tcp socket" "$out" '^dockerd_tcp tcp://0\.0\.0\.0:2375$'
has "facts: container with the socket" "$out" '^cont coolify-proxy traefik:v3\.6 false sock:ro$'
has "facts: disk" "$out" '^df [0-9]+ [0-9]+$'
has "facts: docker disk use" "$out" "^ddf Images$(printf '\t')2\.1GB"
has "facts: end marker" "$out" '^facts done$'
check "facts: the server script changes nothing (no rm, kill, write)" "$(grep -cE '\brm |\bkill|>[^&/]|\btee\b|docker (rm|stop|kill|run)|systemctl' "$HOME/facts.stdin")" "0"

# staging (R11): the staging state from production's, env names without values, the second app
# from the staging branch, basic auth, the shared webhook secret, teardown only with --yes.
# Runs under the jq and curl argv wrappers: no value, password or secret on a command line.
SD=$HOME/shop; mkdir -p "$SD"; PS=$SD/.coolify.env; SS=$SD/.coolify.staging.env; rm -f "$SS"
printf '%s\n' APP_UUID=a-shop GH_REPO=acme/shop KEY_UUID=key-gh APP_DOMAIN=shop.acme.example.com PROJECT_UUID=p-acme \
  "PROJECT_NAME=Acme Corp" ENV_NAME=production APP_NAME=shop "APP_DIR=$SD" HOOK_ID=42 WEBHOOK=github DB_UUID=db-pg > "$PS"
: > "$HOME/seq.log"
s3run staging_init "$PS" "$SS"
check "staging_init rc:output" "$rc:$out" "0:staging plan, nothing created yet: app shop-staging from branch staging on https://staging.shop.acme.example.com, project Acme Corp / staging, its own empty database shop-staging-db
state: $SS (production: $PS)"
check "staging_init: exact file" "$(cat "$SS")" "GH_REPO=acme/shop
KEY_UUID=key-gh
APP_DIR=$SD
PROJECT_NAME=Acme Corp
HOOK_ID=42
PROJECT_UUID=p-acme
APP_NAME=shop-staging
APP_DOMAIN=staging.shop.acme.example.com
ENV_NAME=staging
GIT_BRANCH=staging
PROD_STATE=$PS"
check "staging_init: mode 600" "$(stat -c %a "$SS" 2>/dev/null || stat -f %Lp "$SS")" "600"
check "staging_init: no API call" "$(cat "$HOME/seq.log")" ""
check "staging_init: production state untouched" "$(grep -c . "$PS")" "12"
check "staging: project_ctx of the staging state" "$(VPS_STATE=$SS project_ctx 2>&1)" "p-acme staging"
printf 'COOLIFY_APP_UUID=a-old\nCOOLIFY_PROJECT_UUID=p-old\nCOOLIFY_DOMAIN=https://old.example.com\nGH_REPO=u/old\nKEY_UUID=key-gh\nAPP_NAME=old\n' > "$HOME/old-prod.env"
s3run staging_init "$HOME/old-prod.env" "$HOME/old-stg.env"
check "staging_init: a pre-R09 .coolify.env" "$rc:$(VPS_STATE=$HOME/old-stg.env state_get PROJECT_UUID):$(VPS_STATE=$HOME/old-stg.env state_get APP_DOMAIN)" "0:p-old:staging.old.example.com"
s3run staging_init "$PS" "$SS"
check "staging_init: a rerun before the app exists writes the same file" "$rc:$(grep -c . "$SS")" "0:11"
VPS_STATE=$SS state_set APP_UUID a-stg
s3run staging_init "$PS" "$SS"
check "staging_init: refuses an existing staging app" "$rc:$out" "1:staging_init: $SS already has APP_UUID=a-stg; staging exists, nothing changed"
VPS_STATE=$SS state_set APP_UUID ''
grep -v '^KEY_UUID=' "$PS" > "$HOME/nokey.env"
s3run staging_init "$HOME/nokey.env" "$HOME/x.env"
check "staging_init: production without a deploy key" "$rc:$out" "1:staging_init: $HOME/nokey.env has no KEY_UUID; production must be set up first (phase 05 or PREPARE-APP.md)"
s3run staging_init "$PS" "$PS"
check "staging_init: same file refused" "$rc:$out" "1:staging_init: the staging state must be another file than $PS"
s3run staging_init "$HOME/none.env" "$SS"
check "staging_init: no production state" "$rc:$out" "1:staging_init: no production state in $HOME/none.env"
check "staging_init: refusals wrote nothing" "$([ -e "$HOME/x.env" ] && echo written || echo none)" "none"

# app_env_keys: names, build flag, kind; preview copies and Coolify's own left out
T=$'\t'
s3run app_env_keys a-shop
check "app_env_keys" "$rc:$out" "0:key${T}build_time${T}kind
AUTH_SECRET${T}no${T}secret
DATABASE_URL${T}no${T}database
NEXT_PUBLIC_SITE_URL${T}yes${T}ask
SMTP_HOST${T}no${T}ask
STRIPE_API_KEY${T}no${T}secret"
s3run app_env_keys ../x; check "app_env_keys bad uuid" "$rc" "1"

# app_env_set: the old key deleted (also its preview copy), then one POST; value from stdin only
: > "$HOME/seq.log"
out=$(printf 'v-SECRET-1|a=b c\nline 2\n' | app_env_set a-new AUTH_SECRET 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"
check "app_env_set rc:output" "$rc:$out" "0:set AUTH_SECRET (replaced)"
check "app_env_set: DELETE both, then POST with the value" "$(cat "$HOME/seq.log")" "DELETE /applications/a-new/envs/ev8
DELETE /applications/a-new/envs/ev9
env POST a-new AUTH_SECRET preview=False value=ok"
: > "$HOME/seq.log"
out=$(printf 'v-SECRET-1|a=b c\nline 2' | app_env_set a-new NEW_ONE 2>&1); rc=$?
check "app_env_set new key: no DELETE" "$rc:$out:$(cat "$HOME/seq.log")" "0:set NEW_ONE:env POST a-new NEW_ONE preview=False value=ok"
: > "$HOME/seq.log"
out=$(printf 'x' | app_env_set a-new 'BAD-KEY' 2>&1); rc=$?
check "app_env_set bad key" "$rc:$out" "1:not a variable name: 'BAD-KEY'"
out=$(app_env_set a-new EMPTY </dev/null 2>&1); rc=$?
check "app_env_set no value" "$rc:$out" "1:app_env_set: no value on stdin for EMPTY; nothing sent"
check "app_env_set refused: nothing sent" "$(cat "$HOME/seq.log")" ""
# STAGING.md step 5: the .env.staging upload loop, '=' and '|' kept in values, comments skipped
printf '# staging values\n\nSMTP_HOST=v-SECRET-1 a=b|c\nNEXT_PUBLIC_SITE_URL=v-SECRET-1 a=b|c\n' > "$SD/.env.staging"
: > "$HOME/seq.log"
out=$(grep -Ev '^[[:space:]]*(#|$)' "$SD/.env.staging" | while IFS='=' read -r k v; do printf '%s' "$v" | app_env_set a-new "$k"; done 2>&1)
printf '%s\n' "$out" >> "$HOME/outputs.log"
check "staging upload loop" "$out:$(grep -c 'value=ok2$' "$HOME/seq.log")" "set SMTP_HOST
set NEXT_PUBLIC_SITE_URL:2"

# app_create: the domain must be free; then POST from the state and PATCH domain and health check
: > "$HOME/seq.log"
VPS_STATE=$SS s3run app_create staging 3000 /api/health
check "app_create: domain in use refused" "$rc:$out" "1:app_create: staging.shop.acme.example.com is already used by app shop; pick another domain or free it first. Nothing was sent."
check "app_create refused: no POST or PATCH" "$(grep -cE 'POST|PATCH' "$HOME/seq.log")" "0"
VPS_STATE=$SS state_set APP_DOMAIN staging.shop2.acme.example.com
: > "$HOME/seq.log"
VPS_STATE=$SS s3run app_create staging 3000 /api/health
check "app_create rc:output" "$rc:$out" "0:app shop-staging: a-new (created in p-acme / staging, branch staging, not deployed)
domain https://staging.shop2.acme.example.com and health check /api/health on port 3000 set"
check "app_create: exact POST, then PATCH" "$(grep -E '^app ' "$HOME/seq.log")" 'app POST {"build_pack":"dockerfile","environment_name":"staging","git_branch":"staging","git_repository":"git@github.com:acme/shop.git","instant_deploy":false,"name":"shop-staging","ports_exposes":"3000","private_key_uuid":"key-gh","project_uuid":"p-acme","server_uuid":"s2"}
app PATCH a-new domains,health_check_enabled,health_check_path,health_check_port
app PATCH a-new domains=https://staging.shop2.acme.example.com health=/api/health:3000'
check "app_create: state" "$(VPS_STATE=$SS state_get APP_UUID):$(VPS_STATE=$SS state_get COOLIFY_APP_UUID):$(VPS_STATE=$SS state_get COOLIFY_DOMAIN):$(VPS_STATE=$SS state_get COOLIFY_PROJECT_UUID)" \
  "a-new:a-new:https://staging.shop2.acme.example.com:p-acme"
: > "$HOME/seq.log"
VPS_STATE=$SS s3run app_create staging 3000 /api/health
check "app_create rerun: existing, nothing sent" "$rc:$out:$(grep -cE 'POST|PATCH' "$HOME/seq.log")" "0:app shop-staging: a-new (existing, on https://staging.shop2.acme.example.com):0"
out=$({ app_create "a b" 3000 /h; app_create staging 99999 /h; app_create staging 3000 health; } 2>&1)
has "app_create: bad branch" "$out" "^not a branch name: 'a b'$"
has "app_create: bad port" "$out" "^not a port: '99999'$"
has "app_create: bad health path" "$out" "^not a health check path: 'health' \(like /api/health\)$"
printf 'APP_NAME=x\nGH_REPO=u/x\nKEY_UUID=k1\nAPP_DOMAIN=staging.x.example.com\nPROJECT_UUID=p-acme\nENV_NAME=staging\n' > "$HOME/base.env"
: > "$HOME/seq.log"
VPS_STATE=$HOME/base.env app_create staging 8080 /healthz /starter >/dev/null 2>&1
has "app_create: base_directory sent" "$(cat "$HOME/seq.log")" '^app POST \{"base_directory":"/starter",.*"ports_exposes":"8080"'

# app_basic_auth: password from stdin, never in argv or output; off; a 422 that quotes it back
: > "$HOME/seq.log"
out=$(printf 'ba-SECRET-pass1\n' | app_basic_auth a-new preview 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"
check "app_basic_auth on" "$rc:$out" "0:basic auth on for a-new, user preview; Coolify applies it with the next deploy [verify]"
check "app_basic_auth: fields sent" "$(cat "$HOME/seq.log")" "app PATCH a-new http_basic_auth_password,http_basic_auth_username,is_http_basic_auth_enabled
app PATCH a-new basic_auth=True user=preview password=ok"
: > "$HOME/seq.log"
s3run app_basic_auth a-new off
check "app_basic_auth off" "$rc:$out:$(sed -n 2p "$HOME/seq.log")" "0:basic auth off for a-new:app PATCH a-new basic_auth=False user=None password=absent"
out=$(printf 'ba-SECRET-pass1' | app_basic_auth a-noauth preview 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"
check "app_basic_auth 422: UI fallback" "$rc:$out" "1:Coolify refused the basic-auth fields (HTTP 422). Set it in the UI instead: the app -> Advanced -> HTTP Basic Auth (user preview when turning it on), then Save and redeploy."
out=$(printf 'ba-SECRET-pass1' | app_basic_auth a-down preview 2>&1); rc=$?
check "app_basic_auth other error: code only" "$rc:$out" "1:app_basic_auth: PATCH /applications/a-down failed (HTTP 500)"
: > "$HOME/seq.log"
out=$(printf 'short' | app_basic_auth a-new preview 2>&1); rc=$?
check "app_basic_auth short password" "$rc:$out" "1:app_basic_auth: the password on stdin is missing or shorter than 8 characters; nothing sent"
out=$(printf 'ba-SECRET-pass1' | app_basic_auth a-new 'a:b' 2>&1); rc=$?
check "app_basic_auth bad user" "$rc:$out" "1:not a basic-auth user name: 'a:b' (letters, digits, . _ -)"
check "app_basic_auth refused: nothing sent" "$(cat "$HOME/seq.log")" ""

# apps_webhook_secret: one secret onto production and staging; partial failure said plainly
: > "$HOME/seq.log"
out=$(printf 'wh-sec-0123456789abcdef\n' | apps_webhook_secret a-shop a-new 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"
check "apps_webhook_secret" "$rc:$out" "0:webhook secret set on 2 apps: a-shop a-new"
check "apps_webhook_secret: both apps" "$(grep webhook= "$HOME/seq.log")" "app PATCH a-shop webhook=ok
app PATCH a-new webhook=ok"
out=$(printf 'wh-sec-0123456789abcdef' | apps_webhook_secret a-shop a-down a-new 2>&1); rc=$?; printf '%s\n' "$out" >> "$HOME/outputs.log"
check "apps_webhook_secret partial" "$rc:$out" "1:apps_webhook_secret: failed on a-down; the new secret is on: a-shop. Pushes to those apps are rejected until the GitHub hook has it too: patch the GitHub hook with the same value to restore production's push-to-deploy, or rotate again."
: > "$HOME/seq.log"
out=$(printf 'short' | apps_webhook_secret a-shop 2>&1); rc=$?
check "apps_webhook_secret short secret" "$rc:$out:$(cat "$HOME/seq.log")" "1:apps_webhook_secret: the secret on stdin is missing or shorter than 16 characters; nothing sent:"

# staging_teardown: only with --yes, never production's uuids, both deletes, the link cleared
VPS_STATE=$SS state_set DB_UUID db-stg; VPS_STATE=$PS state_set STAGING_APP_UUID a-new
: > "$HOME/seq.log"
s3run staging_teardown "$SS"
check "staging_teardown without --yes" "$rc:$out" "1:staging_teardown: refusing without --yes. This deletes the staging app a-new and its database db-stg with their volumes: the staging data is gone for good. Ask the user, then: staging_teardown $SS --yes"
s3run staging_teardown "$SS" yes
check "staging_teardown 'yes' (not --yes) refused" "$rc" "1"
s3run staging_teardown "$PS" --yes
check "staging_teardown of the production state" "$rc:$out" "1:staging_teardown: $PS is not a staging state (no PROD_STATE, or ENV_NAME is not staging); nothing sent"
cp -p "$SS" "$HOME/twisted.env"; VPS_STATE=$HOME/twisted.env state_set APP_UUID a-shop
s3run staging_teardown "$HOME/twisted.env" --yes
check "staging_teardown: production's app refused" "$rc:$out" "1:staging_teardown: $HOME/twisted.env points at production's app or database ($PS); nothing sent"
VPS_STATE=$HOME/twisted.env state_set APP_UUID a-new; VPS_STATE=$HOME/twisted.env state_set DB_UUID db-pg
s3run staging_teardown "$HOME/twisted.env" --yes
check "staging_teardown: production's database refused" "$rc" "1"
check "staging_teardown refused: no request sent" "$(cat "$HOME/seq.log")" ""
s3run staging_teardown "$SS" --yes
check "staging_teardown rc:output" "$rc:$out" "0:staging app shop-staging (a-new) deleted with its volumes
staging database shop-staging-db (db-stg) deleted with its volume
left as they are: the DNS record staging.shop2.acme.example.com (remove it at the DNS provider if it should go), the staging branch, and the GitHub webhook (production uses it)"
check "staging_teardown: app, then database" "$(cat "$HOME/seq.log")" "DELETE /applications/a-new?delete_volumes=true&delete_configurations=true&docker_cleanup=true
DELETE /databases/db-stg?delete_volumes=true"
check "staging_teardown: states cleared" "$(VPS_STATE=$SS state_get APP_UUID):$(VPS_STATE=$SS state_get DB_UUID):$(VPS_STATE=$PS state_get STAGING_APP_UUID):$(VPS_STATE=$PS state_get APP_UUID)" ":::a-shop"
s3run staging_teardown "$SS" --yes
check "staging_teardown rerun: nothing left" "$rc:$out" "1:staging_teardown: no APP_UUID or DB_UUID in $SS; nothing to delete"
cp -p "$SS" "$HOME/noprod.env"; VPS_STATE=$HOME/noprod.env state_set APP_UUID a-x; VPS_STATE=$HOME/noprod.env state_set PROD_STATE "$HOME/none.env"
: > "$HOME/seq.log"
s3run staging_teardown "$HOME/noprod.env" --yes
check "staging_teardown: missing production state" "$rc:$out:$(cat "$HOME/seq.log")" "1:staging_teardown: the production state $HOME/none.env is missing or empty; nothing sent:"
VPS_STATE=$SS state_set APP_UUID a-gone; VPS_STATE=$SS state_set DB_UUID db-stg; VPS_STATE=$PS state_set STAGING_APP_UUID a-gone
: > "$HOME/seq.log"
s3run staging_teardown "$SS" --yes
check "staging_teardown: app already gone (404)" "$rc:$(sed -n 1,2p <<<"$out")" "0:staging app a-gone not in Coolify any more (404); cleared from the state
staging database shop-staging-db (db-stg) deleted with its volume"
check "staging_teardown 404: only the database DELETE" "$(cat "$HOME/seq.log")" "DELETE /databases/db-stg?delete_volumes=true"
check "staging_teardown 404: states cleared" "$(VPS_STATE=$SS state_get APP_UUID):$(VPS_STATE=$SS state_get DB_UUID):$(VPS_STATE=$PS state_get STAGING_APP_UUID)" "::"
check "rebuild clears STAGING_APP_UUID" "$(rebuild_clears STAGING_APP_UUID && echo yes)" "yes"
check "staging: argv log has the env POSTs" "$(grep -c '^curl .*/applications/a-new/envs' "$HOME/argv.log" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"

# uptime checks (R06b): kuma.env, kuma_init, kuma_targets, kuma_sync, kuma_status; kuma.js runs in the
# fake docker (its plan on the ssh stdin and its own stdin, never on a command line). Own state file.
VPS_STATE=$HOME/kuma.state
KE="$HOME/.config/vps-setup/kuma.env"; : > "$HOME/seq.log"
s3run kuma_env_init
check "kuma_env_init rc" "$rc" "0"
check "kuma_env_init output: the path, no password" "$out" "wrote $KE (mode 600): the Kuma admin login. Read it in your own terminal when you log in: cat $KE"
check "kuma_env_init: mode 600, admin, a 32-character password" \
  "$(stat -c %a "$KE"):$(kuma_cred KUMA_USER):$(kuma_cred KUMA_PASSWORD | wc -c)" "600:admin:33"
case "$out" in *"$(kuma_cred KUMA_PASSWORD)"*) check "kuma_env_init: password not printed" printed hidden ;; *) check "kuma_env_init: password not printed" ok ok ;; esac
before=$(cksum < "$KE"); s3run kuma_env_init
check "kuma_env_init twice: refused, file unchanged" "$rc:$out:$(cksum < "$KE")" "1:$KE exists already; nothing changed (Kuma keeps the password in it):$before"
( umask 077; printf 'KUMA_USER=admin\nKUMA_PASSWORD=kPW-SECRET+/xyz=1|2\n' > "$KE" )
check "kuma_env_check ok" "$(kuma_env_check 2>&1; echo $?)" "0"
chmod 644 "$KE"; s3run kuma_env_check
check "kuma_env_check: mode 644 refused" "$rc:$out" "1:refusing $KE: mode 644, must be 600 (chmod 600 $KE)"
chmod 600 "$KE"; cp -p "$KE" "$KE.good"
( umask 077; printf 'KUMA_USER=admin\n' > "$KE" ); s3run kuma_env_check
check "kuma_env_check: missing password" "$rc:$out" "1:$KE needs a KUMA_USER= and a KUMA_PASSWORD= line"
( umask 077; printf 'KUMA_USER=admin\nKUMA_PASSWORD=a"b\n' > "$KE" ); s3run kuma_env_check
check "kuma_env_check: quote in the password" "$rc:$out" "1:KUMA_PASSWORD in $KE contains a quote, a backslash or a control character; generate a new file with kuma_env_init"
rm -f "$KE"; s3run kuma_init uptime-kuma
check "kuma_init without kuma.env" "$rc:$out" "1:no Kuma login: $KE is missing; the user runs kuma_env_init in their own terminal (UPTIME.md step 3)"
mv "$KE.good" "$KE"

: > "$HOME/seq.log"
s3run kuma_init uptime-kuma
check "kuma_init without the service key" "$rc:$out" "1:no SERVICE_UPTIME_KUMA_UUID in $HOME/kuma.state; create Kuma first (UPTIME.md step 2)"
s3run kuma_init 'Up Kuma'
check "kuma_init bad name" "$rc:$out" "1:not a service name: 'Up Kuma'"
state_set SERVICE_UPTIME_KUMA_UUID svc-kuma
s3run kuma_init uptime-kuma
check "kuma_init: Kuma exited" "$rc:$out" "1:Kuma is not running yet (exited); wait a minute and run this again (UPTIME.md step 3)"
state_set SERVICE_NOTKUMA_UUID svc-umami2; s3run kuma_init notkuma
check "kuma_init: not a Kuma service" "$rc:$out" "1:service notkuma has no uptime-kuma application; is it an uptime-kuma service?"
state_set SERVICE_KUMA2_UUID svc-kuma-nodom; s3run kuma_init kuma2
check "kuma_init: no https domain" "$rc:$out" "1:service kuma2 has no https domain; SERVICES.md step 3 sets it"
check "kuma_init refusals: no ssh" "$(grep -c '^ssh$' "$HOME/seq.log")" "0"
state_set SERVICE_UPTIME_KUMA_UUID svc-kuma-up; : > "$HOME/docker.log"; rm -f "$HOME/kuma.stdin" "$HOME/kuma.argv"
FAKE_KUMA=init_ok s3run kuma_init uptime-kuma
check "kuma_init rc:output" "$rc:$out" "0:Kuma database set up (SQLite)
admin admin created; the password is in $KE
recorded UPTIME_SERVICE=uptime-kuma, UPTIME_URL=https://status.example.com; next: the HTTPS wait (UPTIME.md step 4)"
check "kuma_init: state" "$(state_get UPTIME_SERVICE) $(state_get UPTIME_URL)" "uptime-kuma https://status.example.com"
check "kuma_init: ssh command" "$(cat "$HOME/ssh.args")" "-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@203.0.113.9 sh -s -- uptime-kuma-svc-kuma-up"
has "kuma_init: exact container match" "$(cat "$HOME/docker.log")" '^docker ps -q -f name=\^/\?uptime-kuma-svc-kuma-up\$$'
check "kuma_init: the plan on kuma.js's stdin" "$(cat "$HOME/kuma.stdin")" '{"action":"init","user":"admin","password":"kPW-SECRET+/xyz=1|2"}'
check "kuma_init: kuma.js is node's -e script" "$(head -n 2 "$HOME/kuma.argv")" "exec -i cid node -e // kuma.js: drives Uptime Kuma 2.x from inside its own container (UPTIME.md; lib.sh kuma_run).
// Kuma 2.x has no REST API for writes: the web UI talks socket.io, and so does this script,"
check "kuma_init: the password only inside the PLAN heredoc of the ssh stdin" \
  "$(grep -c 'kPW-SECRET' "$HOME/ssh.stdin"):$(sed -n "/<<'PLAN'\$/,/^PLAN\$/p" "$HOME/ssh.stdin" | grep -c 'kPW-SECRET')" "1:1"
check "kuma_init: password in no argv (ssh, docker, kuma.js)" "$(grep -c 'kPW-SECRET' "$HOME/ssh.args" "$HOME/kuma.argv" "$HOME/docker.log" | grep -vc ':0$')" "0"
check "kuma_init: server temp dir deleted" "$(ls -A "$HOME/srvtmp")" ""
FAKE_KUMA=init_again s3run kuma_init uptime-kuma
check "kuma_init again" "$rc:$(head -n 1 <<<"$out")" "0:already initialised: the admin in $KE logs in"
FAKE_KUMA=init_exists s3run kuma_init uptime-kuma
check "kuma_init: admin made by someone else" "$rc:$out" "1:kuma_init: admin exists and kuma.env does not open it (authIncorrectCreds)
Someone created the Kuma admin before kuma_init did. If it was not the user, reset it (UPTIME.md step 3, human step)."
FAKE_KUMA=garbage s3run kuma_init uptime-kuma
check "kuma_init: no JSON from kuma.js" "$rc:$out" "1:kuma.js gave no result: node:internal/modules/cjs/loader: Cannot find module"
FAKE_NO_CONTAINER=1 s3run kuma_init uptime-kuma
check "kuma_init: no container" "$rc:$out" "1:kuma.js gave no result: no running container uptime-kuma-svc-kuma-up (is Kuma up? service_status)"
SSH_STUB_FAIL=1 s3run kuma_init uptime-kuma
check "kuma_init: server unreachable" "$rc:$out" "1:kuma.js gave no result: ssh: connect to host 203.0.113.9 port 22: Connection refused"
printf 'const a = 1;\nKUMAJS\n' > "$HOME/bad-kuma.js"; : > "$HOME/seq.log"
out=$(kuma_js_path() { echo "$HOME/bad-kuma.js"; }; kuma_run uptime-kuma-svc-kuma-up '{}' 2>&1); rc=$?
check "kuma_run: a KUMAJS line in the script is refused before ssh" "$rc:$out:$(grep -c '^ssh$' "$HOME/seq.log")" "1:$HOME/bad-kuma.js has a line that is exactly KUMAJS, the heredoc delimiter; nothing sent:0"
check "kuma_run: the server script cleans up on signals too" "$(grep -cxF "d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT; trap 'rm -rf \"\$d\"; exit 1' HUP INT TERM" "$HOME/ssh.stdin")" "1"

# kuma_targets: the https hosts of the project's apps in its environment, Kuma's own host left out
state_set PROJECT_UUID p-acme; state_set PROJECT_NAME "Acme Corp"
s3run kuma_targets
check "kuma_targets: Acme production, two hosts, lower case, port and path dropped" "$rc:$out" "0:$(printf 'shop (shop.acme.example.com)\thttps://shop.acme.example.com')
$(printf 'shop (www.shop.example.com)\thttps://www.shop.example.com')"
VPS_ENV=staging s3run kuma_targets
check "kuma_targets: VPS_ENV=staging" "$rc:$out" "0:$(printf 'shop\thttps://staging.shop.acme.example.com')"
VPS_PROJECT=starter s3run kuma_targets
check "kuma_targets: VPS_PROJECT=starter" "$rc:$out" "0:$(printf 'starter\thttps://starter.example.com')"
state_set UPTIME_URL https://WWW.shop.example.com; s3run kuma_targets
check "kuma_targets: Kuma's own host left out" "$rc:$out" "0:$(printf 'shop\thttps://shop.acme.example.com')"
state_set UPTIME_URL https://status.example.com
printf '%s' '{"projects":[],"resources":[{"kind":"app","name":"web","project_uuid":"p1","environment":"production","fqdn":"http://plain.example.com, https://Web.Example.com., https://[2001:db8::1]:443"},
  {"kind":"app","name":"nodomain","project_uuid":"p1","environment":"production","fqdn":""},
  {"kind":"service","name":"kuma","project_uuid":"p1","environment":"production","fqdn":"https://kuma.example.com"},
  {"kind":"app","name":"other","project_uuid":"p2","environment":"production","fqdn":"https://other.example.com"}]}' > "$HOME/pj.json"
out=$(projects_json() { cat "$HOME/pj.json"; }; project_ctx() { echo "p1 production"; }; kuma_targets 2>&1); rc=$?
check "kuma_targets: http, no domain, services and other projects skipped" "$rc:$out" "0:$(printf 'web ([2001:db8::1])\thttps://[2001:db8::1]')
$(printf 'web (web.example.com)\thttps://web.example.com')"
out=$(projects_json() { return 1; }; kuma_targets 2>&1); rc=$?
check "kuma_targets: Coolify unreadable" "$rc" "1"

# kuma_page_default and kuma_sync
check "kuma_page_default" "$(kuma_page_default)" "$(printf 'acme-corp\tAcme Corp')"
check "kuma_page_default: VPS_PROJECT and a stage" "$(VPS_PROJECT=Shop VPS_ENV=staging kuma_page_default)" "$(printf 'shop-staging\tShop (staging)')"
: > "$HOME/seq.log"
for sl in Acme 'a b' -acme acme- 'a--b' 'a/../b' "$(printf 'x%.0s' $(seq 1 64))"; do
  s3run kuma_sync "$sl" Acme
  case $out in "not a status page slug: '$sl'"*|"status page slug longer than 63 characters: '$sl'") check "kuma_sync: slug '${sl:0:12}' refused" ok ok ;;
    *) check "kuma_sync: slug '${sl:0:12}' refused" "$rc:$out" "1:not a status page slug ..." ;; esac
done
s3run kuma_sync acme "$(printf 'a\tb')"
check "kuma_sync: control character in the title" "$rc:$out" "1:not a usable page title: '$(printf 'a\tb')' (at most 100 characters, no control characters)"
check "kuma_sync: refused input sent nothing" "$(cat "$HOME/seq.log")" ""
state_set UPTIME_SERVICE ''; s3run kuma_sync
check "kuma_sync before kuma_init" "$rc:$out" "1:no UPTIME_SERVICE or UPTIME_URL in $HOME/kuma.state; run kuma_init first (UPTIME.md step 3)"
state_set UPTIME_SERVICE uptime-kuma; rm -f "$HOME/kuma.stdin"
VPS_ENV=nostage s3run kuma_sync
check "kuma_sync: nothing to monitor" "$rc:$out" "1:no application with an https domain in this project and environment; nothing to monitor"
check "kuma_sync: nothing to monitor, no ssh" "$(test -e "$HOME/kuma.stdin" && echo ran || echo none)" "none"
: > "$HOME/docker.log"
FAKE_KUMA=sync_ok s3run kuma_sync
check "kuma_sync rc:output" "$rc:$out" "0:monitors added: shop (shop.acme.example.com)
monitors kept: shop (www.shop.example.com)
status page: https://status.example.com/status/acme-corp (2 groups)
first checks within a minute; then: kuma_status acme-corp (UPTIME.md step 5)"
check "kuma_sync: exact plan" "$(cat "$HOME/kuma.stdin")" '{"action":"sync","user":"admin","password":"kPW-SECRET+/xyz=1|2","monitors":[{"name":"shop (shop.acme.example.com)","url":"https://shop.acme.example.com"},{"name":"shop (www.shop.example.com)","url":"https://www.shop.example.com"}],"page":{"slug":"acme-corp","title":"Acme Corp","description":"Status of Acme Corp"},"group":"Acme Corp"}'
check "kuma_sync: page recorded" "$(state_get UPTIME_PAGES)" "acme-corp"
check "kuma_sync: password in no argv" "$(grep -c 'kPW-SECRET' "$HOME/ssh.args" "$HOME/kuma.argv" "$HOME/docker.log" | grep -vc ':0$')" "0"
FAKE_KUMA=sync_again s3run kuma_sync
check "kuma_sync again" "$rc:$(sed -n 1,3p <<<"$out")" "0:monitors added: none
monitors kept: shop (shop.acme.example.com), shop (www.shop.example.com)
status page: https://status.example.com/status/acme-corp (1 group)"
FAKE_KUMA=sync_ok s3run kuma_sync shop-status "Shop"
has "kuma_sync with a slug and title" "$(cat "$HOME/kuma.stdin")" '"page":\{"slug":"shop-status","title":"Shop","description":"Status of Shop"\},"group":"Shop"\}$'
check "kuma_sync: second page recorded once" "$(kuma_sync shop-status Shop >/dev/null 2>&1; state_get UPTIME_PAGES)" "acme-corp shop-status"
FAKE_KUMA=tfa s3run kuma_sync
check "kuma_sync: 2FA" "$rc:$out" "1:kuma_sync: 2FA is on for the Kuma admin; this script cannot log in with it."
FAKE_KUMA=init_exists s3run kuma_sync
check "kuma_sync: wrong password" "$rc:$out" "1:kuma_sync: admin exists and kuma.env does not open it (authIncorrectCreds)"
check "kuma_sync: server temp dir deleted" "$(ls -A "$HOME/srvtmp")" ""

# kuma_status: the public JSON of a page, no login, no Kuma password
state_set UPTIME_URL "http://127.0.0.1:$PORT"; : > "$HOME/seq.log"
s3run kuma_status acme
T=$(printf '\t')
check "kuma_status: TSV, a monitor in two groups once, exit 1 for a down monitor" "$rc:$out" "1:monitor${T}status${T}uptime_24h${T}since${T}last_check${T}msg
shop${T}up${T}99.8%${T}2026-10-19 09:59:00.000${T}2026-10-19 10:00:00.000${T}-
starter${T}down${T}50%${T}2026-10-19 09:59:00.000${T}2026-10-19 10:00:00.000${T}-
fresh${T}none${T}n/a${T}-${T}-${T}-
slow one${T}pending${T}n/a${T}2026-10-19 10:00:00.000${T}2026-10-19 10:00:00.000${T}-
db${T}maintenance${T}100%${T}2026-10-19 10:00:00.000${T}2026-10-19 10:00:00.000${T}-"
check "kuma_status: the two public calls only" "$(cat "$HOME/seq.log")" "kuma GET /api/status-page/acme
kuma GET /api/status-page/heartbeat/acme"
s3run kuma_status empty
check "kuma_status: empty page" "$rc:$out" "0:monitor${T}status${T}uptime_24h${T}since${T}last_check${T}msg"
s3run kuma_status odd
check "kuma_status: not a page" "$rc:$out" "2:status page odd at http://127.0.0.1:$PORT: unexpected answer"
s3run kuma_status nope
check "kuma_status: no such page" "$rc:${out%%:*}" "2:could not read status page nope at http"
s3run kuma_status 'a b'
check "kuma_status: bad slug" "$rc:$out" "2:not a status page slug: 'a b' (lower-case letters, digits and single dashes, like acme)"
state_set UPTIME_URL ''; s3run kuma_status acme
check "kuma_status without UPTIME_URL" "$rc:$out" "2:no UPTIME_URL in $HOME/kuma.state; UPTIME.md step 3"
check "rebuild clears UPTIME_SERVICE, UPTIME_PAGES and UPTIME_DOMAINS, keeps UPTIME_URL" \
  "$(rebuild_clears UPTIME_SERVICE && echo y)$(rebuild_clears UPTIME_PAGES && echo y)$(rebuild_clears UPTIME_DOMAINS && echo y)$(rebuild_clears UPTIME_URL || echo n)" "yyyn"

# a status page on a client's domain (R22): dns_check, service_app, service_app_urls_set, service_restart,
# kuma_domain_add and kuma_domain_remove. A fake dig answers from FAKE_DIG_* (no network).
cat > "$HOME/bin/dig" <<'STUB'
#!/bin/sh
# dig +short TYPE HOST @1.1.1.1: the CNAME target first (as dig prints it), then the addresses
echo "dig $*" >> "$HOME/dig.log"
for c in ${FAKE_DIG_CNAME:-}; do echo "$c."; done
case $2 in
  A) for a in ${FAKE_DIG_A:-}; do echo "$a"; done ;;
  AAAA) for a in ${FAKE_DIG_AAAA:-}; do echo "$a"; done ;;
esac
STUB
chmod +x "$HOME/bin/dig"
state_set UPTIME_URL https://status.example.com
FAKE_DIG_A=203.0.113.9 s3run dns_check status.acme.com
check "dns_check: an A record, VPS_IP by default" "$rc:$out" "0:status.acme.com A=203.0.113.9 AAAA= CNAME= (want A=203.0.113.9, no AAAA)"
check "dns_check: 1.1.1.1, A and AAAA" "$(tail -n 2 "$HOME/dig.log")" "dig +short A status.acme.com @1.1.1.1
dig +short AAAA status.acme.com @1.1.1.1"
FAKE_DIG_CNAME=status.example.com FAKE_DIG_A=203.0.113.9 s3run dns_check status.acme.com 203.0.113.9
check "dns_check: a CNAME to Kuma's domain" "$rc:$out" "0:status.acme.com A=203.0.113.9 AAAA= CNAME=status.example.com (want A=203.0.113.9, no AAAA)"
FAKE_DIG_CNAME=status.example.com FAKE_DIG_A=203.0.113.9 FAKE_DIG_AAAA=2001:db8::1 s3run dns_check status.acme.com
check "dns_check: an AAAA too" "$rc:$out" "1:status.acme.com A=203.0.113.9 AAAA=2001:db8::1 CNAME=status.example.com (want A=203.0.113.9, no AAAA)"
FAKE_DIG_A="203.0.113.9 198.51.100.1" s3run dns_check status.acme.com
check "dns_check: a second address" "$rc:$out" "1:status.acme.com A=198.51.100.1 203.0.113.9 AAAA= CNAME= (want A=203.0.113.9, no AAAA)"
s3run dns_check status.acme.com
check "dns_check: nothing yet" "$rc:$out" "1:status.acme.com A= AAAA= CNAME= (want A=203.0.113.9, no AAAA)"
mkdir -p "$HOME/nodig"; ln -sf "$(command -v tr)" "$HOME/nodig/tr"
out=$(PATH=$HOME/nodig dns_check status.acme.com 203.0.113.9 2>&1); rc=$?
check "dns_check: no dig" "$rc:$out" "2:dns_check: dig is not installed (Debian/Ubuntu: dnsutils; macOS: it ships with the system)"
s3run dns_check 'a b'
check "dns_check: not a host" "$rc:$out" "2:not a host name: 'a b'"
s3run dns_check 'stätus.acme.com'
check "dns_check: an IDN" "$rc:$out" "2:not a host name: 'stätus.acme.com' (an IDN as punycode, xn--...)"
FAKE_DIG_A=203.0.113.9 s3run dns_check Status.Acme.COM.
check "dns_check: upper case and a trailing dot" "$rc:$out" "0:status.acme.com A=203.0.113.9 AAAA= CNAME= (want A=203.0.113.9, no AAAA)"

s3run service_app svc-kuma-up uptime-kuma
check "service_app: uuid and fqdn" "$rc:$out" "0:sa3${T}https://Status.Example.com:443/"
s3run service_app svc-umami2 uptime-kuma
check "service_app: no such application" "$rc:$out" "1:service svc-umami2 has no application uptime-kuma"
s3run service_app 'x/y' uptime-kuma
check "service_app: bad uuid" "$rc:$out" "1:not a Coolify uuid: 'x/y'"
: > "$HOME/seq.log"
s3run service_app_urls_set svc-kuma-up sa3 "https://status.example.com,https://invalid.example.com"
check "service_app_urls_set: 422" "$rc:$out" "1:Coolify refused the domains (HTTP 422): Validation failed.; url: The url format is invalid.; nothing changed"
s3run service_app_urls_set svc-umami2 sa5 "https://u.example.com,https://race.example.com"
check "service_app_urls_set: 409" "$rc:$out" "1:already used in Coolify: race.example.com (starter, application); nothing changed"
check "service_app_urls_set: refusals left the fqdn" "$(service_app svc-kuma-up uptime-kuma | cut -f2)" "https://Status.Example.com:443/"
s3run service_restart 'a b'
check "service_restart: bad uuid, nothing sent" "$rc:$out:$(grep -c restart "$HOME/seq.log")" "1:not a Coolify uuid: 'a b':0"

: > "$HOME/seq.log"; rm -f "$HOME/kuma.stdin"
s3run kuma_domain_add acme-corp
check "kuma_domain_add usage" "$rc:$out" "1:usage: kuma_domain_add SLUG HOST  (a page of kuma_sync; the client's host, like status.client.com)"
s3run kuma_domain_add Acme status.acme.com
check "kuma_domain_add: bad slug" "$rc:$out" "1:not a status page slug: 'Acme' (lower-case letters, digits and single dashes, like acme)"
s3run kuma_domain_add acme-corp https://status.acme.com
check "kuma_domain_add: a URL, not a host" "$rc:$out" "1:not a host name: 'https://status.acme.com' (the host only, like status.client.com, no https://)"
s3run kuma_domain_add acme-corp Status.Example.com.
check "kuma_domain_add: Kuma's own domain" "$rc:$out" "1:status.example.com is Kuma's own domain; a client's status page needs a host of its own (UPTIME.md step 9)"
out=$(coolify_get() { echo "https://Panel.Example.com:8443/"; }; kuma_domain_add acme-corp panel.example.com 2>&1); rc=$?
check "kuma_domain_add: the Coolify panel's domain" "$rc:$out" "1:panel.example.com is the Coolify panel's domain; a client's status page needs a host of its own (UPTIME.md step 9)"
s3run kuma_domain_add acme-corp 'stätus.acme.com'
check "kuma_domain_add: an IDN" "$rc:$out" "1:not a host name: 'stätus.acme.com' (the host only, like status.client.com, no https://) (an IDN as punycode, xn--...)"
s3run kuma_domain_add nope status.acme.com
check "kuma_domain_add: a page kuma_sync did not make" "$rc:$out" "1:status page nope is not in UPTIME_PAGES; run kuma_sync for it first (UPTIME.md step 5)"
FAKE_DIG_A=198.51.100.9 s3run kuma_domain_add acme-corp status.acme.com
check "kuma_domain_add: DNS not there yet" "$rc:$out" "1:status.acme.com A=198.51.100.9 AAAA= CNAME= (want A=203.0.113.9, no AAAA)
DNS of status.acme.com does not point at this server (203.0.113.9) yet; nothing changed (UPTIME.md step 9b, then the gate in 9c)"
FAKE_DIG_A=203.0.113.9 FAKE_DIG_AAAA=2001:db8::1 s3run kuma_domain_add acme-corp status.acme.com
check "kuma_domain_add: an AAAA record" "$rc:$(tail -n 1 <<<"$out")" "1:DNS of status.acme.com does not point at this server (203.0.113.9) yet; nothing changed (UPTIME.md step 9b, then the gate in 9c)"
FAKE_DIG_A=203.0.113.9 s3run kuma_domain_add acme-corp stats.example.com
check "kuma_domain_add: the host belongs to another resource" "$rc:$(tail -n 1 <<<"$out")" "1:stats.example.com is already used by service umami (umami) in Coolify; nothing changed (if a previous run mapped it in Kuma: kuma_domain_remove acme-corp stats.example.com --yes undoes that)"
check "kuma_domain_add: refusals sent nothing (no ssh, no PATCH, no restart)" "$(cat "$HOME/seq.log"):$(test -e "$HOME/kuma.stdin" && echo ran || echo none)" ":none"
FAKE_DIG_CNAME=status.example.com FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_ok s3run kuma_domain_add acme-corp Status.Acme.com
check "kuma_domain_add rc:output" "$rc:$out" "0:status.acme.com A=203.0.113.9 AAAA= CNAME=status.example.com (want A=203.0.113.9, no AAAA)
Kuma: status.acme.com now serves status page acme-corp
domains of uptime-kuma: https://status.example.com:443/, https://status.acme.com
service svc-kuma-up restarting: Traefik picks up its domains; Kuma's checks pause for about a minute
recorded acme-corp=status.acme.com in UPTIME_DOMAINS; next: the HTTPS wait on https://status.acme.com/api/entry-page (UPTIME.md step 9e)"
check "kuma_domain_add: the plan on kuma.js's stdin" "$(cat "$HOME/kuma.stdin")" '{"action":"domain","user":"admin","password":"kPW-SECRET+/xyz=1|2","slug":"acme-corp","add":["status.acme.com"],"remove":[]}'
check "kuma_domain_add: Kuma first, then the domains (Kuma's own first), then the restart" "$(cat "$HOME/seq.log")" "ssh
svcapp PATCH svc-kuma-up sa3 url=https://Status.Example.com:443/,https://status.acme.com
service restart svc-kuma-up"
check "kuma_domain_add: recorded" "$(state_get UPTIME_DOMAINS)" "acme-corp=status.acme.com"
check "kuma_domain_add: password in no argv" "$(grep -c 'kPW-SECRET' "$HOME/ssh.args" "$HOME/kuma.argv" "$HOME/docker.log" | grep -vc ':0$')" "0"
: > "$HOME/seq.log"
FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_same s3run kuma_domain_add acme-corp status.acme.com
check "kuma_domain_add again: nothing changed, no restart" "$rc:$(sed 1d <<<"$out" | sed '$d'):$(cat "$HOME/seq.log")" "0:Kuma: status.acme.com is already on status page acme-corp
Coolify: status.acme.com is already a domain of the Kuma service; no restart:ssh"
check "kuma_domain_add again: recorded once" "$(state_get UPTIME_DOMAINS)" "acme-corp=status.acme.com"
: > "$HOME/seq.log"
FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_other_page s3run kuma_domain_add acme-corp status.beta.com
check "kuma_domain_add: the host is on another page" "$rc:$(sed 1d <<<"$out"):$(cat "$HOME/seq.log")" "1:kuma.js: status.beta.com is on status page beta; nothing changed:ssh"
: > "$HOME/seq.log"
FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_ok s3run kuma_domain_add acme-corp race.example.com
check "kuma_domain_add: Coolify finds a conflict (409), no restart" "$rc:$(sed 1,2d <<<"$out")" "1:already used in Coolify: race.example.com (starter, application); nothing changed
Kuma has race.example.com on the page, Coolify does not route it yet: fix the cause and run kuma_domain_add acme-corp race.example.com again"
check "kuma_domain_add 409: no restart, not recorded" "$(grep -c restart "$HOME/seq.log"):$(state_get UPTIME_DOMAINS)" "0:acme-corp=status.acme.com"

# the page in PROJECTS.md and in kuma_sync's output
state_set UPTIME_PAGES "acme-corp shop-status acme-corp-staging"
md=$(VPS_SETUP_STATE=$DS projects_md - 2>&1)
check "projects_md: the status page lines of Acme Corp, with the client domain" "$(sed -n '/^## Acme Corp$/,/^### /p' <<<"$md" | grep '^Status page')" \
  "Status page: https://status.example.com/status/acme-corp, also https://status.acme.com
Status page: https://status.example.com/status/acme-corp-staging"
check "projects_md: no status page line for a project without a page" "$(sed -n '/^## starter$/,/^### /p' <<<"$md" | grep -c '^Status page')" "0"
state_set UPTIME_PAGES "acme-corp shop-status"
FAKE_KUMA=sync_ok s3run kuma_sync
has "kuma_sync: the client domain of the page" "$out" '^also at: https://status\.acme\.com \(UPTIME\.md step 9\)$'
FAKE_KUMA=sync_ok s3run kuma_sync shop-status Shop
check "kuma_sync: no client domain on another page" "$(grep -c '^also at' <<<"$out")" "0"

: > "$HOME/seq.log"; rm -f "$HOME/kuma.stdin"
s3run kuma_domain_remove shop-status status.acme.com --yes
check "kuma_domain_remove: recorded under another page, nothing sent" "$rc:$out:$(cat "$HOME/seq.log"):$(test -e "$HOME/kuma.stdin" && echo ran || echo none)" \
  "1:status.acme.com is recorded for status page acme-corp, not shop-status; nothing changed (kuma_domain_remove acme-corp status.acme.com --yes)::none"
s3run kuma_domain_remove acme-corp status.acme.com
check "kuma_domain_remove without --yes: refused, nothing sent" "$rc:$out:$(cat "$HOME/seq.log")" "1:kuma_domain_remove: refusing without --yes. This stops https://status.acme.com from serving status page acme-corp. Ask the user, then: kuma_domain_remove acme-corp status.acme.com --yes:"
FAKE_KUMA=domain_removed s3run kuma_domain_remove acme-corp status.acme.com --yes
check "kuma_domain_remove rc:output" "$rc:$out" "0:domains of uptime-kuma: https://status.example.com:443/
service svc-kuma-up restarting: Traefik picks up its domains; Kuma's checks pause for about a minute
Kuma: status.acme.com no longer serves status page acme-corp
the page and its checks stay; the client deletes their DNS record for status.acme.com (this guide never deletes DNS records)"
check "kuma_domain_remove: Coolify first (Kuma's domain kept), then Kuma" "$(cat "$HOME/seq.log")" "svcapp PATCH svc-kuma-up sa3 url=https://status.example.com:443/
service restart svc-kuma-up
ssh"
check "kuma_domain_remove: the remove plan" "$(cat "$HOME/kuma.stdin")" '{"action":"domain","user":"admin","password":"kPW-SECRET+/xyz=1|2","slug":"acme-corp","add":[],"remove":["status.acme.com"]}'
check "kuma_domain_remove: state cleared" "$(state_get UPTIME_DOMAINS)" ""
: > "$HOME/seq.log"
FAKE_KUMA=domain_absent s3run kuma_domain_remove acme-corp status.acme.com --yes
check "kuma_domain_remove again: not recorded any more, refused, nothing sent" "$rc:$out:$(cat "$HOME/seq.log")" \
  "1:status.acme.com is not recorded in UPTIME_DOMAINS for any page; nothing changed. If it was mapped by hand, remove it by hand: in Coolify the Kuma service's domains (then restart it), in Kuma the page's Domain Names (UPTIME.md step 9f):"

# a restart that fails (500 once): nothing recorded, and the next run only restarts
: > "$HOME/seq.log"; touch "$HOME/restart.fail"
FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_ok s3run kuma_domain_add acme-corp status2.acme.com
check "kuma_domain_add: restart failed" "$rc:$(sed 1,3d <<<"$out")" "1:HTTP 500 POST /services/svc-kuma-up/restart: {\"message\": \"Server Error\"}
the restart of service svc-kuma-up failed (it needs a token with the deploy ability); run: service_restart svc-kuma-up
Coolify has status2.acme.com, Traefik does not route it yet; nothing recorded: run kuma_domain_add acme-corp status2.acme.com again"
check "kuma_domain_add: restart failed, not recorded" "$(state_get UPTIME_DOMAINS)" ""
: > "$HOME/seq.log"
FAKE_DIG_A=203.0.113.9 FAKE_KUMA=domain_same s3run kuma_domain_add acme-corp status2.acme.com
check "kuma_domain_add again: the due restart only" "$rc:$(sed 1,2d <<<"$out" | sed '$d'):$(cat "$HOME/seq.log")" "0:Coolify: status2.acme.com is already a domain of the Kuma service; its restart is still due
service svc-kuma-up restarting: Traefik picks up its domains; Kuma's checks pause for about a minute:ssh
service restart svc-kuma-up"
check "kuma_domain_add again: recorded after the restart" "$(state_get UPTIME_DOMAINS)" "acme-corp=status2.acme.com"
: > "$HOME/seq.log"; touch "$HOME/restart.fail"
FAKE_KUMA=domain_removed s3run kuma_domain_remove acme-corp status2.acme.com --yes
check "kuma_domain_remove: restart failed, Kuma not touched, still recorded" "$rc:$(sed 1d <<<"$out"):$(cat "$HOME/seq.log"):$(state_get UPTIME_DOMAINS)" \
  "1:HTTP 500 POST /services/svc-kuma-up/restart: {\"message\": \"Server Error\"}
the restart of service svc-kuma-up failed (it needs a token with the deploy ability); run: service_restart svc-kuma-up
Coolify no longer has status2.acme.com; Kuma still maps it: run kuma_domain_remove acme-corp status2.acme.com --yes again:svcapp PATCH svc-kuma-up sa3 url=https://status.example.com:443/
service restart svc-kuma-up:acme-corp=status2.acme.com"
: > "$HOME/seq.log"
FAKE_KUMA=domain_removed s3run kuma_domain_remove acme-corp status2.acme.com --yes
check "kuma_domain_remove again: the due restart, then Kuma" "$rc:$(sed '$d' <<<"$out"):$(cat "$HOME/seq.log"):$(state_get UPTIME_DOMAINS)" "0:Coolify: status2.acme.com is no longer a domain of the Kuma service; its restart is still due
service svc-kuma-up restarting: Traefik picks up its domains; Kuma's checks pause for about a minute
Kuma: status2.acme.com no longer serves status page acme-corp:service restart svc-kuma-up
ssh:"
check "R22: the restart flag was used up" "$(test -e "$HOME/restart.fail" && echo left || echo used)" "used"
check "R22: the dig stub never left the machine" "$(grep -vc '@1\.1\.1\.1$' "$HOME/dig.log")" "0"
rm -f "$HOME/bin/dig"
if command -v node >/dev/null 2>&1; then
  check "node --check kuma.js" "$(node --check "$REPO/kuma.js" 2>&1; echo $?)" "0"
  out=$(node "$REPO/test/kuma.test.js" 2>&1); rc=$?
  check "kuma.js unit tests (test/kuma.test.js)" "$rc:$(tail -n 1 <<<"$out")" "0:ALL PASSED"
  [ "$rc" = 0 ] || printf '%s\n' "$out" | grep -v '^ok '
else
  echo "skip kuma.js checks: node not found"
fi
VPS_STATE=$VPS_SETUP_STATE

# the credentials never appear on a command line (jq, curl, ssh, docker) or in any output
leaks=$(grep -lE 's3SeCrEt|AKFAKEKEY|wh-SECRET|api/webhooks|FAKE-cf-|v-SECRET-1|ba-SECRET-pass1|wh-sec-0123|kPW-SECRET|3\|abc=def' "$HOME/argv.log" "$HOME/ssh.args" "$HOME/docker.log" "$HOME/outputs.log" 2>/dev/null)
check "s3 creds, webhook URL, Coolify and Cloudflare tokens, staging secrets and the Kuma password in no argv and no output" "${leaks:-none}" "none"
has "capi: Coolify token handed to curl as a config on a pipe" "$(cat "$HOME/argv.log")" '^curl .*/api/v1/.* -K /dev/fd/[0-9]+ '
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
