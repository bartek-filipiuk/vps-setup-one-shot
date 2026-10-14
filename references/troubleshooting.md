# Troubleshooting

Find the symptom or log line, apply the fix, re-run the check. If nothing matches, read the full
log, explain the error to the user in plain words, and decide together. Do not loop.

## SSH

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Host key verification failed` | a new server reused an IP you connected to before | `ssh-keygen -R <ip>`, retry |
| `Permission denied (publickey)` | key not on the server, or passphrase key not loaded | `ssh-add`; check the key chosen in phase 00 was the one added at server creation |
| `Connection timed out` | server still booting, or firewall without port 22 | wait 30 s; `hcloud firewall describe vps-setup-fw` |
| locked out after phase 02 | hardening applied before key login worked | phase 02 recovery: Hetzner Rescue → reset root password → Console |

## Coolify install and panel

| Symptom | Cause | Fix |
|---------|-------|-----|
| install script exits early | apt lock (unattended-upgrades running) | wait 2 minutes, run it again; it is safe to re-run |
| tunnel: `bind: Address already in use` | local 8000/6001/6002 taken | stop the local process using it |
| panel shows "realtime connection lost" via the tunnel | 6001 not forwarded | include all three `-L` forwards |
| "realtime connection lost" stays after the HTTPS domain is set | the browser still has the tunnel-era page open, or the proxy has not reloaded | hard-reload the panel on its domain; the docs say 6001/6002 are only needed for direct-IP access (coolify.io/docs/core/infrastructure/servers/firewall) |
| `401` from the API | wrong or truncated token | create a new token, write it again (phase 04 step 3) |
| API says it is disabled | API access off | Settings → Advanced → API Access |

## HTTPS / certificates

Never fix these by redeploying or re-saving the domain; Let's Encrypt limits failed attempts.

| Symptom | Cause | Fix |
|---------|-------|-----|
| `curl` code `000`, browser "not secure" | DNS not pointing at the server yet | `dig +short A <host> @1.1.1.1` must equal VPS_IP; wait |
| works on some networks, not others | stale AAAA record | delete the AAAA record for that host |
| redirect loop or Cloudflare error page | Cloudflare proxy (orange cloud) on | set the record to **DNS only** |
| still `000` after 10 minutes with correct DNS | proxy could not get a cert | `rssh "docker logs coolify-proxy 2>&1 | grep -i acme | tail -20"` and read the reason |
| panel unreachable after setting the instance domain | domain set before DNS resolved | reach it through the tunnel (phase 03 step 2), fix DNS or clear the domain field |

## Build and deploy (from `deploy_logs`)

| Log line | Cause | Fix |
|----------|-------|-----|
| `Permission denied (publickey)` / `Could not read from remote repository` | deploy key missing or wrong repo | `gh repo deploy-key list --repo <repo>`; redo phase 05 step 2 |
| `COPY failed` / `not found` for app files | app created via the inline-Dockerfile endpoint | recreate with `/applications/private-deploy-key` |
| `npm ci` complains the lockfile is out of sync | `package-lock.json` not committed or stale | `npm install`, commit the lockfile, push |
| `JavaScript heap out of memory` / build killed | not enough RAM | check swap (`rssh free -h`); bigger server type |
| deploy `failed` after a successful build, health check errors | app not listening on `::`/`localhost`, or the health route returns 503 | `ENV HOSTNAME=::` in the Dockerfile; read runtime logs |
| `db: migrate attempt N/10 failed` in runtime logs | database not running or wrong `DATABASE_URL` | `capi GET /databases/<uuid>`; check the env var points at `internal_db_url` |
| `there appears to be PostgreSQL data in: /var/lib/postgresql/data` | Postgres 18 image | recreate the database with `postgres:17-alpine` |
| `function uuidv7() does not exist` | app expects Postgres 18 | add a plpgsql `uuidv7()` once, or generate UUIDs in the app |

## App down (`DOCTOR.md`)

Read-only checks first; every fix here needs the user's yes.

| Symptom | Cause | Fix |
|---------|-------|-----|
| `502 Bad Gateway` from Traefik (plain text, not the app's page) | the app container exited or keeps restarting | `rssh "docker ps -a --filter name=<APP_UUID>"`, then `app_logs <APP_UUID>` or `rssh "docker logs --tail 100 <container>"`; fix the cause the log names, then deploy again (`DOCTOR.md` B) |
| `502` while the container is `Up` | Coolify routes to `ports_exposes`, the app listens on another port | `capi GET /applications/<APP_UUID> \| jq -r .ports_exposes` must be the port in the app's log line ("listening on ..."); `capi PATCH /applications/<APP_UUID> '{"ports_exposes":"<port>"}'`, then deploy again |
| `502` while the container is `Up` and the port is right | the container is not on the `coolify` Docker network, so the proxy cannot reach it | `rssh "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' <container>"` must list `coolify`; a deploy through Coolify attaches it again **[verify]** |
| `503` / `504` from Traefik | the app is up but unhealthy or too slow to answer (database down, long start) | `app_logs <APP_UUID>`; the database: `capi GET /databases/<DB_UUID> \| jq -r .status`; see "Build and deploy" for the `migrate` and health check rows |
| deploys or dumps fail with `no space left on device`, `status.sh` disk FAIL | disk full: build cache, old images, dumps | `rssh "df -h /; docker system df; du -sh /root/db-dumps/* 2>/dev/null"`. Safe to clear with the user's yes: unused images (`rssh "docker image prune -a -f"`; a rollback can then only rebuild, `ROLLBACK.md` step 2) and build cache (`rssh "docker builder prune -f"`); dumps in `/root/db-dumps/` beyond the newest few (`deploy_and_wait` keeps ten). Never volumes, never `docker system prune --volumes` |
| every domain on the server down, the panel too, `curl` code `000` or `connection refused` on 443 | `coolify-proxy` (Traefik) not running | `rssh "docker ps -a --filter name=coolify-proxy; docker logs --tail 50 coolify-proxy"`; with the user's yes: Coolify UI → **Servers** → localhost → **Proxy** → **Restart** **[verify]** (panel through the tunnel, phase 03 step 2), or `rssh "docker start coolify-proxy"`. A log line about port 80 or 443 in use: something else took the port, stop it first |

## Webhook

| Symptom | Cause | Fix |
|---------|-------|-----|
| delivery `401`/`403` | secret mismatch | PATCH the secret again and update the hook's secret to the same value |
| delivery `404` | wrong URL or this Coolify version has no manual GitHub webhook | check `COOLIFY_URL`; otherwise `WEBHOOK=none` (phase 05 step 6) |
| delivery `200` but no deploy | pushed a branch other than `main` | the app deploys `git_branch` only |
