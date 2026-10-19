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
def pick2(h, v): return h.send(200, v) if v is not None else h.send(404, {"msg": "Not Found"})
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        s = json.load(open(path))
        if self.path.startswith("/api/status-page/"):   # Kuma's public status page JSON (R06b), no token
            q = self.path.split("/")[3:]
            k = s.get("kuma", {})
            return pick2(self, (k.get("beats", {}).get(q[1]) if q[0] == "heartbeat" else k.get("pages", {}).get(q[0])))
        if self.path.startswith("/entry/"):   # Kuma's public /api/entry-page on a client host (R22), no token
            q = self.path.split("/")
            v = s.get("kuma", {}).get("entry", {}).get(q[2]) if len(q) == 5 and q[3:] == ["api", "entry-page"] else None
            return self.send(200, v) if v is not None else self.send(503, {"msg": "no route"})
        if self.path == "/latest":
            return self.send(200, s["latest"]) if s.get("latest") else self.send(503, {})
        if s.get("reject_token") or self.headers.get("Authorization") != "Bearer " + token:
            return self.send(401, {"message": "Unauthenticated."})
        p = self.path.removeprefix("/api/v1").split("?")[0].split("/")[1:]
        def pick(v): return self.send(200, v) if v is not None else self.send(404, {"message": "Not found."})
        if p == ["version"]: return pick(s.get("version"))
        if p == ["projects"]: return pick(s.get("projects"))
        if len(p) == 2 and p[0] == "projects": return pick(s.get("project", {}).get(p[1]))
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

mkdir -p "$HOME/.config/coolify" "$HOME/bin"
( umask 077; printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_TOKEN=%s\n' "$PORT" "$TOKEN" > "$HOME/.config/coolify/config" )

# Fake ssh: ignores the script on stdin, answers from FAKE_* variables.
cat > "$HOME/bin/fake-ssh" <<'STUB'
#!/bin/sh
cat >/dev/null
[ "${FAKE_SSH_RC:-0}" = 0 ] || exit "$FAKE_SSH_RC"
echo "disk ${FAKE_DISK:-40}"
echo "mem 1200 3800"
if [ -n "${FAKE_REBOOT_SINCE:-}" ]; then   # days since /var/run/reboot-required appeared
  echo "reboot yes"; echo "reboot_since $(( $(date +%s) - FAKE_REBOOT_SINCE * 86400 - 60 ))"
else echo "reboot ${FAKE_REBOOT:-no}"; fi
# apt-check counts; FAKE_UPDATES=missing: no apt-check on the server
if [ "${FAKE_UPDATES:-0}" = missing ]; then echo "updates none-check"
else echo "updates ${FAKE_UPDATES:-0} ${FAKE_SECURITY:-0}"; fi
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
  projects: [{id: 1, uuid: "p1", name: "starter", description: null}],
  project: {p1: {id: 1, uuid: "p1", name: "starter", environments: [{id: 1, uuid: "e1", name: "production", project_id: 1}]}},
  apps: [{uuid: "a1", name: "starter", status: "running:healthy", fqdn: "https://app.example.test,http://x.sslip.io", environment_id: 1}],
  deploys: {a1: {count: 1, deployments: [
    {status: "finished", created_at: $d, finished_at: $d, commit: "abc123", application_name: "starter", logs: "SECRET-LOG-LINE"},
    {status: "failed", created_at: "2026-01-01T00:00:00.000000Z", finished_at: "2026-01-01T00:01:00.000000Z", commit: "old", application_name: "starter"}]}},
  services: [{uuid: "s1", name: "umami", service_type: "umami", status: "running:healthy", environment_id: 1,
    applications: [{uuid: "sa1", name: "umami", fqdn: "https://stats.example.test", status: "running:healthy", restart_limit_reached: false}],
    databases: [{uuid: "sd1", name: "postgresql", status: "running:healthy", is_public: false}]}],
  dbs: [{uuid: "d1", name: "starter-db", database_type: "standalone-postgresql", image: "postgres:17-alpine"}],
  backups: {d1: [{uuid: "b1", enabled: true, frequency: "0 2 * * *", last_execution_at: null, save_s3: true,
    executions: [{uuid: "e0", status: "success", created_at: $b, finished_at: null, s3_uploaded: true}]}]},
  execs: {b1: {executions: [{uuid: "e1", status: "success", created_at: $b, finished_at: null,
    filename: "/data/coolify/backups/pg-dump.dmp", message: "Backup done", size: 1234, s3_uploaded: true}]}},
  notif: {
    discord: ({id: 1, team_id: 0, discord_enabled: true, discord_ping_enabled: true, status_change_discord_notifications: true}
      + ([$ev | split(" ")[] | {key: "\(.)_discord_notifications", value: true}] | from_entries)),
    telegram: {id: 2, team_id: 0, telegram_enabled: false, deployment_failure_telegram_notifications: true},
    email: {id: 3, team_id: 0, smtp_enabled: false, resend_enabled: false, use_instance_email_settings: false}}
}' --arg ev "status_change deployment_failure backup_failure server_unreachable server_reachable server_disk_usage restart_limit_reached")

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

# Ubuntu updates and Postgres majors (R14): due dates for UPGRADE.md
run .
has "all green: updates none" "$out" '^OK +updates +none pending$'
has "all green: postgres 17" "$out" '^OK +postgres starter-db +17 \(postgres:17-alpine\)$'
FAKE_UPDATES=12 expect "updates without security" 0 '^OK +updates +12 pending, 0 security$'
FAKE_UPDATES=12 FAKE_SECURITY=3 expect "security updates" 1 '^WARN +updates +12 pending, 3 security \(security updates not installed yet; UPGRADE\.md, Ubuntu\)$'
FAKE_UPDATES=missing expect "apt-check missing" 0 '^OK +updates +n/a \(no apt-check on the server\)$'
FAKE_REBOOT_SINCE=8 expect "reboot pending 8 days" 1 '^WARN +updates +none pending; reboot pending 8 days \(UPGRADE\.md, Ubuntu\)$'
has "reboot pending 8 days: reboot line" "$out" '^WARN +reboot +required \(kernel or library update\), pending 8 days$'
FAKE_REBOOT_SINCE=2 expect "reboot pending 2 days" 1 '^OK +updates +none pending$'
has "reboot pending 2 days: reboot line still WARN" "$out" '^WARN +reboot +required \(kernel or library update\), pending 2 days$'
expect "postgres 16" 1 '^WARN +postgres starter-db +16 \(postgres:16-alpine\), major upgrade due \(UPGRADE\.md, Postgres\)$' '.dbs[0].image = "postgres:16-alpine"'
expect "postgres 18" 0 '^OK +postgres starter-db +18 \(postgres:18-alpine\)$' '.dbs[0].image = "postgres:18-alpine"'
expect "postgres latest" 1 "^WARN +postgres starter-db +n/a \\(no major version in image 'postgres:latest'\\)$" '.dbs[0].image = "postgres:latest"'
expect "non-postgres skipped" 0 '^OK +postgres +none$' '.dbs[0] += {database_type: "standalone-redis", image: "redis:7.2"}'
check "non-postgres: no line for it" "$(grep -c '^[A-Z]* *postgres starter-db' <<<"$out")" "0"
expect "no database_type: image decides" 0 '^OK +postgres starter-db +17 ' '.dbs[0] |= del(.database_type)'

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

# services (R10): one line per service, its domains' certificates like the apps'
run .
has "all green: service" "$out" '^OK +service umami +running:healthy, https://stats\.example\.test$'
has "all green: service cert" "$out" '^OK +cert stats\.example\.test +(59|60) days left'
expect "service unhealthy" 1 '^WARN +service umami +running:unhealthy, https://stats\.example\.test$' '.services[0].status = "running:unhealthy"'
expect "service degraded" 1 '^WARN +service umami +degraded:unhealthy' '.services[0].status = "degraded:unhealthy"'
expect "service exited" 1 '^FAIL +service umami +exited, https://stats\.example\.test$' '.services[0].status = "exited"'
expect "service starting" 1 '^WARN +service umami +starting' '.services[0].status = "starting"'
expect "service plain running" 0 '^OK +service umami +running' '.services[0].status = "running"'
expect "service no health check" 0 '^OK +service umami +running:unknown' '.services[0].status = "running:unknown"'
expect "service restart limit" 1 '^FAIL +service umami +running:healthy, https://stats\.example\.test, restart limit reached: umami$' \
  '.services[0].applications[0].restart_limit_reached = true'
expect "service two domains" 0 '^OK +service umami +running:healthy, https://a\.example\.test, https://b\.example\.test$' \
  '.services[0].applications[0].fqdn = "https://a.example.test,https://b.example.test"'
has "service two domains: both certs" "$(grep -cE '^OK +cert [ab]\.example\.test' <<<"$out")" '^2$'
expect "services none" 0 '^OK +services +none$' '.services = []'
check "services none: no service cert" "$(grep -c 'stats\.example' <<<"$out")" "0"
expect "services 404" 1 '^WARN +services +n/a \(could not read services\)$' 'del(.services)'
expect "services unreadable" 1 '^WARN +services +n/a \(could not read services\)$' '.services = {unexpected: 1}'
FAKE_CERT_DAYS=10 expect "service cert 10d" 1 '^WARN +cert stats\.example\.test +expires in (9|10) days'

# projects (R09): apps and services grouped under "project <name> / <environment>" lines; the
# WARN and FAIL lines, labels and exit codes stay as they were (15 with the uptime line of R06b)
run .
check "projects: mark lines on a clean run unchanged" "$(grep -cE '^(OK|WARN|FAIL) ' <<<"$out")" "15"
check "projects: group line before the app and before the service" \
  "$(grep -E '^  project |^OK +(app|service) ' <<<"$out" | sed 's/  */ /g; s/, last deploy: .*//' | paste -sd '|' -)" \
  " project starter / production|OK app starter running:healthy| project starter / production|OK service umami running:healthy, https://stats.example.test"
run '.projects += [{id: 2, uuid: "p2", name: "acme"}] | .project.p2 = {uuid: "p2", name: "acme", environments: [{id: 2, name: "production"}, {id: 3, name: "staging"}]}
  | .apps += [{uuid: "a2", name: "shop", status: "running:healthy", fqdn: "", environment_id: 3},
              {uuid: "a3", name: "blog", status: "running:healthy", fqdn: "", environment_id: 2},
              {uuid: "a4", name: "lost", status: "running:healthy", fqdn: "", environment_id: 42}]
  | .deploys.a2 = .deploys.a1 | .deploys.a3 = .deploys.a1 | .deploys.a4 = .deploys.a1'
check "projects: two projects sorted, unknown environment last" \
  "$(sed -n '/^Apps$/,/^Services$/p' <<<"$out" | grep -E '^  |^OK +app ' | sed 's/  */ /g; s/ running.*//' | paste -sd '|' -)" \
  " project acme / production|OK app blog| project acme / staging|OK app shop| project starter / production|OK app starter| (no project)|OK app lost"
check "projects: grouped run exit" "$rc" "0"
# staging (R11): the staging app of STAGING.md sits under its project's staging environment,
# with its own certificate line (basic auth does not change the TLS check)
run '.project.p1.environments += [{id: 5, uuid: "e5", name: "staging", project_id: 1}]
  | .apps += [{uuid: "a5", name: "starter-staging", status: "running:healthy", fqdn: "https://staging.app.example.test", environment_id: 5}]
  | .deploys.a5 = .deploys.a1'
check "staging: group, app and its cert under project starter / staging" \
  "$(sed -n '/^Apps$/,/^Services$/p' <<<"$out" | grep -E '^  project |^OK +(app|cert) ' | sed 's/  */ /g; s/ running.*//; s/ [0-9]* days left//' | paste -sd '|' -)" \
  " project starter / production|OK app starter|OK cert app.example.test| project starter / staging|OK app starter-staging|OK cert staging.app.example.test"
check "staging: exit" "$rc" "0"
expect "projects 404" 1 '^WARN +projects +n/a \(could not read; apps and services listed without their project\)$' 'del(.projects)'
has "projects 404: apps still listed" "$out" '^OK +app starter +running:healthy'
check "projects 404: no group lines" "$(grep -cE '^  (project |\(no project\))' <<<"$out")" "0"
expect "project detail 404" 1 '^WARN +projects +n/a ' 'del(.project)'
expect "projects with no environment ids" 0 '^OK +app starter ' 'del(.apps[0].environment_id) | del(.services[0].environment_id)'
check "projects with no environment ids: no project" "$(grep -c '^  (no project)$' <<<"$out")" "2"

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
expect "s3 newest upload failed" 1 '^WARN +off-site starter-db +newest run with no upload error 5h ago; S3 upload not reported by API, RESTORE\.md step 3 proves it; newest upload failed$' \
  '.execs.b1.executions[0] |= del(.s3_uploaded) | .execs.b1.executions += [{uuid: "e2", status: "success", created_at: $t, finished_at: null,
    message: "Backup done. Warning: S3 upload failed: Access Denied"}]' --arg t "$(ago_tz 1)"
has "s3 newest upload failed: local backup still OK" "$out" '^OK +backup starter-db +last success 1h ago$'
expect "s3 upload never worked" 1 '^FAIL +off-site starter-db +no backup has reached S3; newest upload failed$' \
  '.execs.b1.executions[0] |= (del(.s3_uploaded) | .message = "Warning: S3 upload failed: InvalidAccessKeyId")'
expect "s3_uploaded false" 1 '^FAIL +off-site starter-db +no backup has reached S3; newest upload failed$' '.execs.b1.executions[0].s3_uploaded = false'
expect "s3_uploaded absent: never OK" 1 '^WARN +off-site starter-db +newest run with no upload error 5h ago; S3 upload not reported by API, RESTORE\.md step 3 proves it$' \
  '.execs.b1.executions[0] |= del(.s3_uploaded)'
expect "local only" 1 '^WARN +off-site starter-db +local only \(no backup schedule copies to S3\)$' '.backups.d1[0].save_s3 = false'
has "local only: local backup line unchanged" "$out" '^OK +backup starter-db +last success 5h ago$'
run '.backups.d1 = []'
check "no schedule: no off-site line on top of the FAIL" "$(grep -c 'off-site' <<<"$out")" "0"

# uptime (R06b): the Kuma status pages in UPTIME_PAGES, read from their public JSON
run .
has "all green: no uptime pages" "$out" '^OK +uptime +none \(UPTIME\.md\)$'
mkdir -p "$HOME/.config/vps-setup"
printf 'UPTIME_URL=http://127.0.0.1:%s\nUPTIME_PAGES=acme\n' "$PORT" > "$HOME/.config/vps-setup/state"
KUMA='.kuma = {pages: {acme: {config: {slug: "acme"}, incidents: [], publicGroupList: [{id: 1, name: "Acme", monitorList: [{id: 1, name: "shop"}, {id: 2, name: "starter"}]}]},
                       empty: {config: {slug: "empty"}, publicGroupList: []}},
               beats: {acme: {heartbeatList: {"1": [{status: 1, time: "2026-10-19 10:00:00.000", msg: ""}],
                                              "2": [{status: 0, time: "2026-10-19 09:58:00.000", msg: ""}, {status: 0, time: "2026-10-19 10:00:00.000", msg: ""}]},
                              uptimeList: {"1_24": 0.998, "2_24": 1}},
                       empty: {heartbeatList: {}, uptimeList: {}}}}'
expect "uptime: all up" 0 '^OK +uptime shop +up, 24h 99\.8%$' "$KUMA"' | .kuma.beats.acme.heartbeatList["2"][1].status = 1'
has "uptime: all up, second monitor" "$out" '^OK +uptime starter +up, 24h 100%$'
check "uptime: one page, no page line" "$(grep -c 'status page' <<<"$out")" "0"
expect "uptime: one down" 1 '^FAIL +uptime starter +down since 2026-10-19 09:58:00\.000$' "$KUMA"
has "uptime: one down, the other still up" "$out" '^OK +uptime shop +up, 24h 99\.8%$'
expect "uptime: pending" 1 '^WARN +uptime shop +pending since 2026-10-19 10:00:00\.000$' "$KUMA"' | .kuma.beats.acme.heartbeatList["1"][0].status = 2 | .kuma.beats.acme.heartbeatList["2"][1].status = 1'
expect "uptime: no check yet" 1 '^WARN +uptime starter +no check yet$' "$KUMA"' | .kuma.beats.acme.heartbeatList |= del(.["2"])'
expect "uptime: a message, should Kuma send one" 1 '^FAIL +uptime starter +down since 2026-10-19 09:58:00\.000: timeout$' "$KUMA"' | .kuma.beats.acme.heartbeatList["2"][1].msg = "timeout"'
expect "uptime: maintenance" 0 '^OK +uptime starter +in maintenance, 24h 100%$' "$KUMA"' | .kuma.beats.acme.heartbeatList["2"][1].status = 3'
expect "uptime: page unreadable" 1 "^WARN +uptime acme +n/a \\(could not read http://127\\.0\\.0\\.1:$PORT/status/acme\\)$" "$KUMA"' | del(.kuma.pages.acme)'
expect "uptime: unexpected answer" 1 '^WARN +uptime acme +n/a ' "$KUMA"' | .kuma.beats.acme = [1]'
printf 'UPTIME_URL=http://127.0.0.1:%s\nUPTIME_PAGES=acme empty\n' "$PORT" > "$HOME/.config/vps-setup/state"
expect "uptime: a page without monitors" 1 '^WARN +uptime empty +no monitors on the page \(kuma_sync, UPTIME\.md step 5\)$' "$KUMA"' | .kuma.beats.acme.heartbeatList["2"][1].status = 1'
check "uptime: two pages, a line per page" "$(grep -E '^  status page ' <<<"$out" | paste -sd '|' -)" "  status page acme|  status page empty"
# a client's domain for a page (R22): /api/entry-page on that host must name the page
printf 'UPTIME_URL=http://127.0.0.1:%s\nUPTIME_PAGES=acme\nUPTIME_DOMAINS=acme=status.acme.test other=status.other.test\n' "$PORT" > "$HOME/.config/vps-setup/state"
export STATUS_ENTRY_URL="http://127.0.0.1:$PORT/entry"
UP="$KUMA"' | .kuma.beats.acme.heartbeatList["2"][1].status = 1'
expect "page domain: serves the page" 0 '^OK +page acme +https://status\.acme\.test serves it$' "$UP"' | .kuma.entry["status.acme.test"] = {type: "statusPageMatchedDomain", statusPageSlug: "acme"}'
check "page domain: one line, only for the page's own pairs" "$(grep -c '^[A-Z]* *page ' <<<"$out")" "1"
check "page domain: after the page's monitor lines" "$(grep -E '^(OK|WARN|FAIL) +(uptime|page) ' <<<"$out" | awk '{print $2}' | paste -sd ' ' -)" "uptime uptime page"
expect "page domain: Kuma's own entry (the login) on the client host" 1 \
  "^FAIL +page acme +https://status\\.acme\\.test answers with Kuma's own entry, not the page \\(kuma_domain_add acme status\\.acme\\.test, UPTIME\\.md step 9\\)$" \
  "$UP"' | .kuma.entry["status.acme.test"] = {type: "entryPage", entryPage: "dashboard"}'
expect "page domain: another page on the host" 1 '^FAIL +page acme +https://status\.acme\.test serves status page beta, not acme \(UPTIME\.md step 9\)$' \
  "$UP"' | .kuma.entry["status.acme.test"] = {type: "statusPageMatchedDomain", statusPageSlug: "beta"}'
expect "page domain: no answer" 1 '^WARN +page acme +n/a \(https://status\.acme\.test does not answer: DNS, certificate or Kuma; UPTIME\.md step 9\)$' "$UP"
expect "page domain: not JSON" 1 '^WARN +page acme +n/a ' "$UP"' | .kuma.entry["status.acme.test"] = "<html>"'
expect "page domain: still checked when the page cannot be read" 1 '^OK +page acme +https://status\.acme\.test serves it$' \
  "$KUMA"' | del(.kuma.pages.acme) | .kuma.entry["status.acme.test"] = {type: "statusPageMatchedDomain", statusPageSlug: "acme"}'
has "page domain: the page itself still WARN" "$out" '^WARN +uptime acme +n/a '
unset STATUS_ENTRY_URL
rm -f "$HOME/.config/vps-setup/state"

# alerts: Coolify notification channels; the seven alert events of NOTIFY_EVENTS must be on
run .
has "all green: alerts" "$out" '^OK +alerts +discord: on, alert events on \(delivery not checked\)$'
expect "alerts: discord off" 1 '^WARN +alerts +none \(no notification channel enabled; phase 06 step 2\)$' '.notif.discord.discord_enabled = false'
expect "alerts: event missing" 1 '^WARN +alerts +discord on but backup_failure server_disk_usage off$' \
  '.notif.discord.backup_failure_discord_notifications = false | del(.notif.discord.server_disk_usage_discord_notifications)'
expect "alerts: another channel fully on" 0 '^OK +alerts +telegram: on, alert events on \(delivery not checked\)$' \
  '.notif.telegram = (.notif.discord | with_entries(.key |= sub("discord"; "telegram"))) | .notif.discord.discord_enabled = false'
expect "alerts: email through SMTP" 1 '^WARN +alerts +email on but status_change deployment_failure .* off$' '.notif.discord.discord_enabled = false | .notif.email.smtp_enabled = true'
expect "alerts: all 404" 1 '^WARN +alerts +n/a \(could not read\)$' 'del(.notif)'
expect "alerts: unreadable" 1 '^WARN +alerts +n/a \(could not read\)$' '.notif = {discord: [1], telegram: "x"}'

expect "latest unreachable" 0 '^OK +version +4\.3\.23 \(latest unknown\)' 'del(.latest)'
expect "patch behind" 0 '^OK +version +4\.3\.23 \(latest release 4\.3\.30\)' '.latest.tag_name = "v4.3.30"'
expect "minor behind" 1 '^WARN +version +4\.3\.23, latest release 4\.4\.0 \(minor or major update behind; UPGRADE\.md, Coolify\)$' '.latest.tag_name = "v4.4.0"'
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
