# DOCTOR: my app is down

You are an AI coding agent helping a user whose app does not work: the site is down, a deploy
failed, the browser shows 502 or a certificate error, or the server does not answer. Work from
the repo root of `vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in
`PREPARE-APP.md`); every command starts with `. ./lib.sh` and, for an app set up through
PREPARE-APP, `VPS_STATE=.coolify.env` in that app's repo, or
`VPS_STATE=<APP_DIR>/.coolify.staging.env` for a staging app (`STAGING.md`; a `401` there is its
basic auth, not a fault). Rules from `SETUP.md` apply: API only via `capi`, server commands only
via `rssh`, nothing destructive without the user's yes, prove every step.

**Not run on a real server yet.** `app_logs` is tested against a fake Coolify API only
(`test/lib.test.sh`); `GET /applications/{uuid}/logs` was checked on a live Coolify 4.3.23, its
"not running" answer comes from the source and is marked `[verify]` in
`references/coolify-api.md`. The five symptoms have not been broken on purpose on a server yet
(see "Fixtures" at the end).

**Read only until the user agrees to a fix.** Sections 1 to 3 use only `GET` calls through
`capi`, `rssh` with `docker ps`, `docker logs`, `docker inspect`, `df` and `journalctl`, and
`dig`, `curl`, `openssl` on this machine. A fix (redeploy, rollback, restart, a DNS change,
restarting `coolify-proxy`) is proposed in one sentence with the runbook or table row it comes
from, and happens only after an explicit yes. Logs (`docker logs`, `app_logs`, `deploy_logs`)
can hold tokens and personal data: quote only the lines that explain the failure, never whole logs
or environment values.

## 1. Triage, in this order

Run each step, write down what it says, then go to the symptom in step 2.

1. The one-screen check:

   ```
   ./status.sh; echo "status.sh exit $?"
   ```

   Exit `0`: everything it checks is OK. `1`: some line is `WARN` or `FAIL`. `2`: the server
   (ssh) or the Coolify API cannot be reached; when the API is the one that failed, the Apps,
   Backups and Alerts sections are missing, so the API part of step 3 below fails too.

2. The app from outside, once with and once without the certificate check (this splits a TLS
   problem from an app problem). `/api/health` is the starter's route; an app from PREPARE-APP
   has its own (PREPARE-APP step 3). In the body, `"db":"none"` is a healthy answer for an app
   without a database (like `fixtures/static`), not a fault.

   ```
   . ./lib.sh; H="https://$(state_get APP_DOMAIN)/api/health"
   curl -s --max-time 10 -o /dev/null -w 'health %{http_code}\n' "$H"
   curl -sk --max-time 10 -o /dev/null -w 'health without certificate check %{http_code}\n' "$H"
   ```

3. The app in Coolify and its newest deployments:

   ```
   . ./lib.sh; A=$(state_get APP_UUID); echo "app $A: $(capi GET "/applications/$A" | jq -r .status)"
   capi GET "/deployments/applications/$A" | jq -r '.deployments[:3][] | "\(.status)\t\(.commit[0:8])\t\(.created_at)\t\(.deployment_uuid // "?")"'
   ```

4. The containers on the server (the app's container is named `<APP_UUID>-<digits>`, checked 2026-10-14 on a 4.3.23 server):

   ```
   . ./lib.sh; A=$(state_get APP_UUID)
   rssh "docker ps -a --filter name=$A --format '{{.Names}}\t{{.Status}}'; docker ps -a --filter name=coolify --format '{{.Names}}\t{{.Status}}'"
   ```

5. The app's runtime logs (the last 100 lines):

   ```
   . ./lib.sh; app_logs "$(state_get APP_UUID)" 100
   ```

   Logs can hold personal data or secrets the app printed. Read them yourself and quote only
   the lines that explain the problem.

6. Disk:

   ```
   . ./lib.sh; rssh "df -h / | tail -1; docker system df"
   ```

7. DNS, from a public resolver:

   ```
   . ./lib.sh; D=$(state_get APP_DOMAIN)
   echo "A: $(dig +short A "$D" @1.1.1.1 | tr '\n' ' ')  AAAA: $(dig +short AAAA "$D" @1.1.1.1 | tr '\n' ' ')  server: $(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP)"
   ```

## 2. Which symptom

```text
status.sh exit 2 and "ssh ... server unreachable"          -> E  server unreachable
status.sh exit 2, ssh OK, "api ... unreachable"            -> E  (Coolify itself is down)
status.sh exit 2, "token rejected" or "config missing"     -> not an outage: phase 04 step 3 (token), then triage again
newest deployment "failed"                                 -> B  deploy failed
health 000, without certificate check 200 (or 3xx/5xx)     -> D  certificate error
health 000 both ways, DNS A record is not the server IP    -> D  (DNS; the certificate follows it)
health 000 both ways, DNS right, coolify-proxy not "Up"    -> C  (the proxy row)
health 502, 503 or 504                                     -> C  502/503/504
health 404 and the app is not "running"                    -> A  site down
app "exited", "restarting" or "running:unhealthy"          -> A  site down
disk above 95 % in status.sh or step 6                     -> C  (the disk row), then the symptom it caused
everything 200 and running, the user still sees an error   -> ask for the URL and the exact message; it may be
                                                              the app's own bug: ROLLBACK.md if it came with a deploy
```

More than one matches: take the first from the top. A server that does not answer explains
everything below it.

## 3. Symptoms

### A. Site down

The app is not running, or runs and answers with errors.

Run:

```
. ./lib.sh; A=$(state_get APP_UUID)
rssh "for c in \$(docker ps -aq --filter name=$A); do docker inspect -f '{{.Name}} {{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' \$c; done"
rssh "c=\$(docker ps -aq --filter name=$A | head -1); [ -n \"\$c\" ] && docker logs --tail 60 \$c 2>&1"
```

`app_logs` reads the running container only; the second line reads the newest container even
when it has stopped. With a database in the state, also:
`. ./lib.sh; capi GET "/databases/$(state_get DB_UUID)" | jq -r .status`.

Read it:

| You see | Meaning |
|---------|---------|
| no container at all | never deployed, or removed; the deployments list says which |
| `exited exit=0` | stopped on purpose (the Coolify UI, `capi POST /applications/<uuid>/stop`, or a restore left it stopped) |
| `exited exit=137 oom=true` | killed for using too much memory |
| `exited exit=1` (or any other code), `restarting`, `restarts=` growing | the app crashes at start; the log tail names the reason |
| `running` and status `running:unhealthy` | the health route fails, usually the database (`db: migrate attempt`, `ECONNREFUSED`) |
| database status not `running:healthy` | the database is down; the app follows it |

Fix:

- Stopped on purpose: start it, with the user's yes: `capi POST "/applications/$A/start"`, the
  same call as `ROLLBACK.md` step 4.
- Crash that started with the last deploy: `ROLLBACK.md` (step 1 decides, step 2 rolls back).
- Out of memory: the `JavaScript heap out of memory` row in `references/troubleshooting.md`
  ("Build and deploy").
- Database down or `migrate` errors: the `db: migrate attempt` row in the same table; start the
  database in Coolify only after the user's yes.
- The data itself is wrong or gone: `ROLLBACK.md` step 4 (a deploy's dump) or `RESTORE.md` (an
  off-site backup). Look at what exists first: `db_backup_list "$(state_get DB_UUID)" | head -5`.

Stop, needs a human when: the database container does not start and its log shows corruption,
or getting the app back means choosing which data to lose.

### B. Deploy failed

Run (the deployment UUID from triage step 3):

```
. ./lib.sh; deploy_logs "<DEPLOYMENT_UUID>"
```

Read it: match the last lines against "Build and deploy" in `references/troubleshooting.md`.
A failed deploy leaves the previous container running, so check triage step 2 as well: health
`200` means users still get the old version and nothing is urgent.

Fix:

- A build error (lockfile, deploy key, `COPY failed`, memory): the matching row; fix the commit,
  deploy again with `deploy_and_wait` after the user's yes.
- Built, then the health check failed: the `ENV HOSTNAME=::` row and `app_logs` for the reason.
- The deploy `finished` but the app is broken: not this section; `ROLLBACK.md`.
- Twice the same error after a fix: stop and explain it to the user; do not loop.

Stop, needs a human when: the log shows nothing about the app (Coolify's own error, a helper
image that cannot be pulled), or the fix needs access the agent does not have (the GitHub repo
of someone else, a paid plan).

### C. 502, 503 or 504

The proxy (Traefik in `coolify-proxy`) answers, but not the app.

Run:

```
. ./lib.sh; A=$(state_get APP_UUID); curl -s --max-time 10 -D - -o /dev/null "https://$(state_get APP_DOMAIN)/" | head -5
capi GET "/applications/$A" | jq -r '"status \(.status)  ports_exposes \(.ports_exposes)"'
rssh "for c in \$(docker ps -q --filter name=$A); do docker inspect -f '{{.Name}} {{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' \$c; done"
rssh "docker ps -a --filter name=coolify-proxy --format '{{.Status}}'; docker logs --tail 30 coolify-proxy 2>&1; df -h / | tail -1"
```

Then `app_logs "$A"` and look for the port the app says it listens on.

Read it:

| You see | Meaning |
|---------|---------|
| `502`, the app container missing or exited | nothing to forward to: section A |
| `502`, container up, `ports_exposes` differs from the port in the app log | Coolify routes to the wrong port |
| `502`, container up, port right, `coolify` missing from its networks | the proxy cannot reach the container |
| `503` or `504`, container `running:unhealthy` or slow to answer | the app is up but not healthy (database, long start) |
| proxy not `Up`, every domain on the server down | `coolify-proxy` stopped |
| disk at 100 % | the app or the database cannot write; fix the disk first |

Fix: the rows in "App down" in `references/troubleshooting.md` (502 container, 502 port,
502 network, 503/504, disk full, `coolify-proxy` not running). Changing `ports_exposes`,
redeploying, restarting the proxy and clearing disk space each need the user's yes; the disk
row says what is safe to clear.

Stop, needs a human when: the disk is above 95 % with nothing obvious to clear (no old images,
no build cache, no old dumps), or `coolify-proxy` does not stay up after a restart.

### D. Certificate error

The browser says "not secure", or `curl` gives `000` while `curl -k` gets an answer.

Run:

```
. ./lib.sh; D=$(state_get APP_DOMAIN)
openssl s_client -connect "$D:443" -servername "$D" </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -enddate
rssh "docker logs coolify-proxy 2>&1 | grep -i acme | tail -20"
```

and the DNS line from triage step 7.

Read it:

| You see | Meaning |
|---------|---------|
| A record is not the server IP, or there is an AAAA record | DNS points elsewhere; Let's Encrypt cannot validate |
| issuer `TRAEFIK DEFAULT CERT` | the proxy never got a certificate for this host |
| issuer Let's Encrypt, `notAfter` in the past | renewal failed; the acme lines say why |
| acme line with `rateLimited` or `too many` | Let's Encrypt's limit is hit; only waiting helps |
| Cloudflare error page or redirect loop | the Cloudflare proxy is on |

Fix: the "HTTPS / certificates" table in `references/troubleshooting.md`, then the wait loop of
`phases/04-domain.md` step 2 with this app's domain (Traefik retries on its own once DNS is
right). Never re-save the domain or redeploy to "kick" the certificate: each failed attempt
counts against Let's Encrypt's limits.

Stop, needs a human when: the acme log shows a rate limit (tell the user how long it lasts;
never re-save the domain), or the DNS lives at a registrar or account the agent cannot touch
(the user changes the record; give them the exact record: `A <host> <VPS_IP>`).

### E. Server unreachable

Run (from this machine; `hcloud` only for a Hetzner server, read-only `describe`):

```
. ./lib.sh; IP=$(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP)
rssh true && echo "ssh OK" || echo "ssh failed (exit $?)"
curl -s --max-time 10 -o /dev/null -w "http $IP: %{http_code}\n" "http://$IP" || true
[ "$(VPS_STATE=$VPS_SETUP_STATE state_get PROVIDER)" = hetzner ] &&
  hcloud server describe "$(VPS_STATE=$VPS_SETUP_STATE state_get SERVER_NAME)" -o format='{{.Status}}'
```

If ssh works but the Coolify API does not:

```
. ./lib.sh; rssh "docker ps -a --filter name=coolify --format '{{.Names}}\t{{.Status}}'; journalctl -u docker --since '-1h' --no-pager | tail -20; df -h / | tail -1"
```

Read it:

| You see | Meaning |
|---------|---------|
| `hcloud` says `off` | the server is powered off |
| `running`, ssh and http time out | firewall, network or a hung server |
| ssh `Permission denied` or `Host key verification failed` | the server answers; a key problem |
| ssh OK, `coolify` container not `Up` or restarting | Coolify itself is down; apps may still serve |
| ssh OK, disk at 100 % | Coolify's database cannot write |

Fix: the "SSH" table in `references/troubleshooting.md` (keys, host key, `hcloud firewall
describe vps-setup-fw` for port 22, the host firewall on another provider). Powering the server
on (`hcloud server poweron`) or changing the firewall only after the user's yes. Disk full:
section C. Another provider: its panel shows whether the server is on, and has the reset, the
rescue system and the out-of-band console (`references/providers.md`); the user does those.

Stop, needs a human when: the server needs the Hetzner Console or the rescue system (the user
logs in to the Console; phase 02 has the recovery), the server needs another provider's rescue
system or out-of-band console (the user logs in there, `references/providers.md`), Coolify itself does not start (`coolify` keeps restarting, its log shows a
database or migration error), or the server is gone for good (`REBUILD.md`: a new server, the data from the off-site backups).

## 4. Afterwards

- Tell the user what was wrong, what you changed (with their yes) and what proves it works now:
  the health route `200`, `./status.sh` exit `0` or the lines still `WARN` and why.
- If data was touched: which backup or dump is live and what was lost, as `ROLLBACK.md` and
  `RESTORE.md` say.
- A cause the tables did not cover: tell the user in plain words; it belongs in
  `references/troubleshooting.md` as a new row.

## Fixtures (not built yet)

How the test harness (roadmap R01, R05) will prove this runbook on a throwaway server: break one
thing, give the agent only "my app is down", check it reaches the right section and fix. Not run
yet; the steps are the plan.

```text
A  site down:        rssh "docker stop <app container>"
                     -> A, "exited exit=0", proposes start (capi POST /applications/<uuid>/start)
B  deploy failed:    push a commit with a broken Dockerfile
                     -> B, deploy_logs shows the error, health still 200 from the old container
C  502:              capi PATCH /applications/<uuid> '{"ports_exposes":"3999"}', then deploy
                     -> C, the ports_exposes row, proposes the app's real port
D  certificate:      point the A record away from the server (or remove the certificate)
                     -> D, the DNS / TRAEFIK DEFAULT CERT row, no domain re-save
E  unreachable:      a firewall rule dropping 22, or hcloud server poweroff
                     -> E, the SSH table or "powered off", asks before poweron
```

The runbook passes when each fixture ends in its section's fix (or its "needs a human" line)
and the app is healthy again. That is the R05 done criterion.
