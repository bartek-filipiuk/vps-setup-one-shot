# Troubleshooting

Find the symptom or log line, apply the fix, re-run the check. If nothing matches, read the full
log, explain the error to the user in plain words, and decide together. Do not loop.

## SSH

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Host key verification failed` | a new server reused an IP you connected to before | `ssh-keygen -R <ip>`, retry |
| `Permission denied (publickey)` | key not on the server, or passphrase key not loaded | `ssh-add`; check the key chosen in phase 00 was the one added at server creation |
| `Connection timed out` | server still booting, or firewall without port 22 | wait 30 s; `hcloud firewall describe vps-setup-fw` |
| locked out after phase 02 | hardening applied before key login worked | phase 02 recovery: Hetzner Rescue → reset root password → Console; another provider: its rescue or console (`references/providers.md`) |
| `Connection timed out` right after `hostfw_apply` (another provider) | the trial's rules cut the way in | wait until the time it printed (5 minutes): the rules remove themselves; then `rssh 'echo back'` and read `hostfw_status` |
| timed out later, another provider, the panel says the server is on | host firewall, network | the provider's out-of-band console (`references/providers.md`), log in, `/usr/local/sbin/vps-hostfw status`; `/usr/local/sbin/vps-hostfw off` removes only its own rules |
| `hostfw_apply`: `refusing` | a check before any change: sshd port not in the list, unclear default route, Docker's nftables backend, a pending trial | the message names it; phase 02 step 4 |

## Coolify install and panel

| Symptom | Cause | Fix |
|---------|-------|-----|
| install script exits early | apt lock (unattended-upgrades running) | wait 2 minutes, run it again; it is safe to re-run |
| `upgrade.sh` (`UPGRADE.md` A step 3) stops with `no space left on device` or a failed image pull | disk full: old images, build cache, dumps | `rssh "df -h /; docker system df"`; free space as in "App down" (disk full row) with the user's yes, then run step 3 again |
| `upgrade.sh` or `apt-get` says `Could not get lock /var/lib/dpkg/lock-frontend` | `unattended-upgrades` is installing updates | wait 2 minutes (`rssh "pgrep -a unattended"` shows it), run it again; never delete the lock file |
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
| `502` while the container is `Up` and the port is right | the container is not on the `coolify` Docker network, so the proxy cannot reach it | `rssh "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' <container>"` must list `coolify` (the network a running app is on, checked 2026-10-14 on 4.3.23); a deploy through Coolify attaches it again **[verify]** |
| `503` / `504` from Traefik | the app is up but unhealthy or too slow to answer (database down, long start) | `app_logs <APP_UUID>`; the database: `capi GET /databases/<DB_UUID> \| jq -r .status`; see "Build and deploy" for the `migrate` and health check rows |
| deploys or dumps fail with `no space left on device`, `status.sh` disk FAIL | disk full: build cache, old images, dumps | `rssh "df -h /; docker system df; du -sh /root/db-dumps/* 2>/dev/null"`. Safe to clear with the user's yes: unused images (`rssh "docker image prune -a -f"`; a rollback can then only rebuild, `ROLLBACK.md` step 2) and build cache (`rssh "docker builder prune -f"`); dumps in `/root/db-dumps/` beyond the newest few (`deploy_and_wait` keeps ten). Never volumes, never `docker system prune --volumes` |
| every domain on the server down, the panel too, `curl` code `000` or `connection refused` on 443 | `coolify-proxy` (Traefik) not running | `rssh "docker ps -a --filter name=coolify-proxy; docker logs --tail 50 coolify-proxy"`; with the user's yes: Coolify UI → **Servers** → localhost → **Proxy** → **Restart** **[verify]** (panel through the tunnel, phase 03 step 2). A log line about port 80 or 443 in use: something else took the port, stop it first |

## Webhook

| Symptom | Cause | Fix |
|---------|-------|-----|
| delivery `401`/`403` | secret mismatch | PATCH the secret again and update the hook's secret to the same value |
| delivery `404` | wrong URL or this Coolify version has no manual GitHub webhook | check `COOLIFY_URL`; otherwise `WEBHOOK=none` (phase 05 step 6) |
| delivery `200` but no deploy | pushed a branch other than `main` | the app deploys `git_branch` only |

## Mail and sign-in (`AUTH.md`, `starter-auth/`)

`app_logs <APP_UUID> 100` shows the lines below; the app never logs a password, a token or a link
(except with `MAIL_LOG=1`).

| Symptom or log line | Cause | Fix |
|---------------------|-------|-----|
| deploy `failed`, log `config: SMTP_URL is not set` | the SMTP step was skipped | `AUTH.md` step 5, then deploy again |
| `config: MAIL_FROM is not set` / `config: SITE_URL is not set` | a variable is missing | `AUTH.md` step 4's variables block, then deploy again |
| `config: SMTP_URL is not a URL` or `... has a broken %-escape` | a character in the password was not percent-encoded | `AUTH.md` step 5 again (it encodes the login and password) |
| `auth: sign-in request failed: Invalid login: 535 ...` (`EAUTH`) | wrong SMTP login or password (often the account password instead of the generated SMTP one) | a new SMTP password at the provider, `AUTH.md` step 5, redeploy |
| `auth: sign-in request failed: ... ETIMEDOUT` / `Connection timeout` | the port is blocked or the host is wrong; Hetzner blocks outgoing 25 and 465 on new Cloud servers [verify] | use the provider's port 587 (`smtp://`, STARTTLS) in step 5; check the host on the provider's SMTP page |
| `auth: sign-in request failed: Error upgrading connection with STARTTLS` | the server on that port does not offer STARTTLS, and the app refuses to send the password unencrypted | the provider's TLS port instead (465 off Hetzner, or their other submission port) |
| `... 550` / `553` `sender address rejected` / `not verified` | `MAIL_FROM` is not an address or domain the provider verified | verify it at the provider, or set `MAIL_FROM` to a verified one (step 4), redeploy |
| `mail: sent <id>` but nothing in the inbox | spam filtering, or the provider held it | the spam folder, the provider's log for that message id, then `AUTH.md` step 9 (SPF, DKIM, DMARC) |
| the page says the link "was already used or has expired" right away | opened after 15 minutes, used once already, or a newer link was asked for and the old one used | ask for a new link; opening the link never uses it, only **Continue** does |
| `Forbidden: this form must be sent from the site itself.` (403) | `SITE_URL` is not exactly the address in the browser (`http` vs `https`, `www.`, another domain) | set `SITE_URL` to `https://<APP_DOMAIN>` (step 4), redeploy |
| everyone gets "Too many tries from your network" | all requests carry the same last `X-Forwarded-For` entry: a proxy in front of Coolify's (the Cloudflare orange cloud) | DNS only on Cloudflare, as the setup requires; the limit is 20 requests per 15 minutes per IP |
| a log line `mail: MAIL_LOG=1, nothing is sent` on the server | `MAIL_LOG` is set on a server: links are in the log | remove `MAIL_LOG` in Coolify, deploy again, delete all sessions (`AUTH.md` step 10) |
