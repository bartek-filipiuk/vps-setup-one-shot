# AUTH: sign-in by email link and transactional mail, a new app from starter-auth/

You are an AI coding agent helping a user who wants a new app with sign-in: people enter their
email address, get a link, click it and are signed in. No passwords. The code is
`starter-auth/` of this repo (`starter-auth/README.md`): the plumbing of the setup's starter
(Next.js 16, Postgres 17, the same Dockerfile and health route) with the sign-in, sessions and
rate limits in Postgres, and mail over SMTP from any provider the user picks. It becomes the
user's own private GitHub repo and a Coolify app on their server, through the same machinery as
phase 05.

`SETUP_DIR` below is the directory that contains this file. Every command sources the helpers:
`. "$SETUP_DIR/lib.sh"`. One state file is in play, **P**, the new app's
`<app repo>/.coolify.env` (gitignored, mode `600`), always as an absolute path; it is created
in step 2. The blocks start with `P="<APP_STATE>"`: put in the absolute path of P.

All rules from `$SETUP_DIR/SETUP.md` apply: secrets never through the chat, server commands only
via `rssh`, API only via `capi`, prove every step, ask before anything is created. Additionally:
**the SMTP password and the database URL never go into a command line, the chat or a file in
the repo**; `app_env_set` reads them from stdin, and the SMTP login is typed by the user in
their own terminal (step 5). **`MAIL_LOG=1` never goes onto a server**: it prints every sign-in
link to the app's log, and anyone who can read the log can then sign in as anyone.

Not in this file: sign-in for an existing app that did not start from `starter-auth/` (use it as
the model, `PREPARE-APP.md`), passwords, OAuth or passkeys, roles, deleting accounts from the UI,
and mail sent by the worker (`WORKER.md` step 9 shows the enqueue; a mail job is a handler there).

**Not run on a real server yet.** `starter-auth/` is built and checked with Docker and a real
Postgres in CI (`test/fixtures.sh starter-auth`: the health contract, then a whole sign-in with
the mail read from the container's log, single use, the session cookie, the protected page,
posts from another site refused, the per-address limit, sign-out, the database stopped), and its
logic by unit tests (`npm test` in `starter-auth/`). No sign-in mail has been sent through a real
SMTP provider by this guide, and no app has been deployed with this file. The Coolify calls are
the ones of phase 05 and `STAGING.md` (`app_create`, `app_env_set`), with their `[verify]` marks
in `references/coolify-api.md`.

## 0. Preconditions

```
. "$SETUP_DIR/lib.sh"; capi GET /version && gh auth status && "$SETUP_DIR/status.sh" | grep -E '^(OK|WARN|FAIL) +(disk|memory)'
```

- The API fails: the setup is incomplete. Tell the user to run `$SETUP_DIR/verify.sh`.
- The app and its database need about 300 MB of memory [verify] and a few GB of disk. With less than
  1 GB of memory free or the disk above 80 %, say so first.
- An SMTP provider: the user has one or picks one (Brevo, Postmark, Mailgun, Amazon SES, Resend,
  or the SMTP of their own mailbox for a first test). Free tiers are enough for sign-in mail.
  Nothing is bought by you. On their side they need: an SMTP login and password (the provider's
  "SMTP" or "SMTP & API" page; usually a generated password, not the account password), and the
  sender address or its domain verified there.
- Hetzner: its docs say outgoing ports 25 and 465 are blocked on new Cloud servers [verify];
  port 587 (STARTTLS) is not. So on Hetzner the provider's port 587 is the one to use.

Where it goes, read only (the default is a new project named after the app, in `production`):

```
. "$SETUP_DIR/lib.sh"; projects_inventory | column -t -s "$(printf '\t')"
```

```
. "$SETUP_DIR/lib.sh"; PR="<project>"; N="<app name>"; ST=production
H=$(app_domain_default "$PR" "$N" "$ST") && echo "default: $H"
domain_in_use "$H"; echo "exit $?"; test -e "$HOME/$N" && echo "EXISTS: $HOME/$N"
```

`domain_in_use` exit 1 means free; exit 0 prints who has it (pick another domain); exit 2 means
Coolify could not be read. A domain the user names wins. An existing `~/<app name>`: ask for
another name.

## 1. The plan (read only), then the user's yes

Show the user, in one list:

- a private GitHub repo `<app name>` from `starter-auth/`, in `~/<app name>`;
- the Coolify project and stage, the domain, a Postgres 17 database `<app name>-db`;
- the four tables the app creates at its start: `users`, `login_tokens`, `sessions`,
  `auth_rate`; what is stored: the addresses of people who signed in, hashes of links and
  sessions (never the links or sessions themselves), request counts per IP and address;
- the variables by name: `DATABASE_URL`, `SITE_URL` (`https://<domain>`), `MAIL_FROM` (the
  sender, like `My App <no-reply@<their domain>>`, verified at the provider), `SMTP_URL` (typed by
  the user, step 5); optional `APP_NAME`;
- what the app sends: one sign-in mail per request, at most five per address per 15 minutes;
- the deliverability DNS records the user adds at their DNS provider (step 9);
- the cost (step 0).

Wait for their yes. The plan goes into the repo's `DEPLOY.md` in step 2.

## 2. The repo (you, push with the user's go-ahead)

```
. "$SETUP_DIR/lib.sh"; N="<app name>"; DEST="$HOME/$N"
if test -e "$DEST"; then echo "EXISTS: $DEST, ask the user"; else
  cp -R "$SETUP_DIR/starter-auth" "$DEST" && rm -rf "$DEST/node_modules" "$DEST/.next" "$DEST/next-env.d.ts" &&
  ( cd "$DEST" && git init -q -b main && git add -A && git commit -q -m "Initial commit from vps-setup-one-shot starter-auth" &&
    gh repo create "$N" --private --source . --push ) &&
  VPS_STATE="$DEST/.coolify.env" && state_set APP_DIR "$DEST" && state_set APP_NAME "$N" &&
  state_set GH_REPO "$(gh repo view "$N" --json nameWithOwner -q .nameWithOwner)" && echo "repo: $(state_get GH_REPO), P=$VPS_STATE" &&
  git -C "$DEST" check-ignore -q .coolify.env && echo ".coolify.env gitignored"
fi
```

The `cd` runs in a subshell on purpose. From now on P is `$HOME/<app name>/.coolify.env`.
Record the approved domain, then write the plan from step 1 into `$HOME/<app name>/DEPLOY.md`
(names only, never values) and commit it with the user's go-ahead:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; state_set APP_DOMAIN "<domain from the plan>" && state_get APP_DOMAIN
```

## 3. Proof on your machine (you, optional, needs Docker)

The copy is the same code CI builds and signs in with:

```
bash "$SETUP_DIR/test/fixtures.sh" starter-auth
```

Expect `ALL FIXTURES OK`. It runs with `MAIL_LOG=1` (nothing is sent) and creates only
containers, images and a network named `vps-fixture-starter-auth-<pid>`, removed by name;
nothing is pruned.

## 4. Coolify: key, project, database, app, variables (you)

The deploy key, as phase 05 step 2, into P:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; K=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -C "coolify-$(state_get APP_NAME)" -f "$K/key" &&
gh repo deploy-key add "$K/key.pub" --repo "$(state_get GH_REPO)" --title coolify &&
U=$(capi POST /security/keys "$(jq -n --arg n "$(state_get APP_NAME)-deploy" --rawfile k "$K/key" '{name:$n, private_key:$k}')" | jq -r .uuid) &&
[ -n "$U" ] && [ "$U" != null ] && state_set KEY_UUID "$U" && rm -rf "$K" && echo "key: $U" || echo "FAILED, key kept in $K"
```

The project and stage from the plan (`project_ensure` finds or creates it; several projects of
that name: ask the user which, as in `PREPARE-APP.md` step 5):

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P
project_ensure "<project from the plan>" "<one line: what the app is>" && env_ensure "$(state_get PROJECT_UUID)" "<stage from the plan>" && project_ctx
```

The database, the body of phase 05 step 3 (the password reaches `jq` on stdin, never printed);
skip when P already has a `DB_UUID` that `capi GET "/databases/<uuid>"` finds:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; read -r PU E < <(project_ctx) &&
B=$(openssl rand -hex 24 | jq -Rn --arg p "$PU" --arg e "$E" --arg s "$(coolify_server)" --arg n "$(state_get APP_NAME)-db" \
  '{project_uuid:$p, server_uuid:$s, environment_name:$e, name:$n,
    image:"postgres:17-alpine", postgres_user:"app", postgres_password:input, postgres_db:"app",
    is_public:false, instant_deploy:true}') &&
state_set DB_UUID "$(capi POST /databases/postgresql "$B" | jq -r .uuid)"; echo "db: $(state_get DB_UUID)"
```

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; for _ in $(seq 1 12); do s=$(capi GET "/databases/$(state_get DB_UUID)" | jq -r .status); echo "$s"; case "$s" in running*) break;; esac; sleep 10; done
```

The app, not deployed yet; `app_create` checks again that the domain is free and sends nothing
if it is not:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; app_create main 3000 /api/health
```

The variables that are not the user's secret, each on stdin (`DATABASE_URL` holds the database
password and is never printed). `F` is the sender from the plan:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; A=$(state_get APP_UUID); F="<MAIL_FROM from the plan>"
capi GET "/databases/$(state_get DB_UUID)" | jq -r .internal_db_url | app_env_set "$A" DATABASE_URL &&
printf 'https://%s' "$(state_get APP_DOMAIN)" | app_env_set "$A" SITE_URL &&
printf '%s' "$F" | app_env_set "$A" MAIL_FROM
```

Expect `set DATABASE_URL`, `set SITE_URL`, `set MAIL_FROM`. `SITE_URL` must be exactly the
address people open (`https://`, no `www.` unless the domain has it): every form is checked
against it, and `https://` is what marks the session cookie `Secure`.

DNS: an A record for the domain pointing to the server IP (no AAAA, DNS only on Cloudflare),
added by the user, or by you with `DNS_PROVIDER=cloudflare` in `~/.config/vps-setup/state`:
`dns_set_a "$(state_get APP_DOMAIN)" "$(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP)"` (exit
codes as in phase 01 step 4). Before the first deploy this must print the server IP:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; dig +short A "$(state_get APP_DOMAIN)" @1.1.1.1; VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP
```

## 5. The SMTP credentials (the user, in their own terminal)

The SMTP password exists only in the user's terminal, their password manager and Coolify. The
user runs this in a terminal of their own (not through you, and not with Claude Code's `!`,
whose output lands in the chat), with the two paths you give them. It asks for the provider's
SMTP host, port (587, or 465 off Hetzner), login and password (not shown while typed), builds
`SMTP_URL` with the login and password percent-encoded, and sends it to Coolify on stdin:

```
SETUP_DIR="<SETUP_DIR>"; . "$SETUP_DIR/lib.sh"; VPS_STATE="<APP_STATE>"
printf 'SMTP host: ' && read -r HOST && printf 'port (587 or 465): ' && read -r PORT && printf 'login: ' && read -r LOGIN &&
printf 'password: ' && read -rs PW && echo && case $PORT in 465) SCHEME=smtps ;; *) SCHEME=smtp ;; esac &&
printf '%s://%s:%s@%s:%s' "$SCHEME" "$(printf '%s' "$LOGIN" | jq -Rr @uri)" "$(printf '%s' "$PW" | jq -Rr @uri)" "$HOST" "$PORT" |
  app_env_set "$(state_get APP_UUID)" SMTP_URL; unset PW
```

They tell you only `set SMTP_URL`. Port 587 means STARTTLS, which the app requires (it refuses
to send the password unencrypted); 465 is TLS from the start. Then confirm the four names, with
no values (Coolify returns none in the list):

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; app_env_keys "$(state_get APP_UUID)" | cut -f1
```

`DATABASE_URL`, `SITE_URL`, `MAIL_FROM` and `SMTP_URL` must be there, `MAIL_LOG` must not.

## 6. First deploy (you, 3-6 minutes)

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; deploy_and_wait "$(state_get APP_UUID)"
```

Then wait for HTTPS and the database (the first certificate takes up to about three minutes):

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; for i in $(seq 1 18); do r=$(curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"); echo "try $i: ${r:-no valid https yet}"; case "$r" in *'"db":"ok"'*) break;; esac; sleep 10; done
```

On `failed`, read the log tail and `references/troubleshooting.md` (the Mail table for this app).
A start that stops right away logs why: `config: SMTP_URL is not set` (step 5 was skipped),
`config: MAIL_FROM is not set`, `config: SITE_URL is not set`, `config: SMTP_URL is not a URL`
(the value is never printed). The start line `mail: smtp <host>:<port> (...)` shows what the app
will use, without the login or password:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; app_logs "$(state_get APP_UUID)" 50 | grep -E 'config: |mail: |db: '
```

A line with `MAIL_LOG=1` here means the variable is on the server: remove it in Coolify (the
app → **Environment Variables**), deploy again, and sign everyone out (step 10).

## 7. Smoke test with the user

They open `https://<domain>`, enter their own address, press **Send me a link**, open the mail,
click the link, press **Continue**, and see **Your account** with their address. You prove it:

```
. "$SETUP_DIR/lib.sh"; P="<APP_STATE>"; VPS_STATE=$P; app_logs "$(state_get APP_UUID)" 100 | grep -E 'auth: |mail: sent'
rssh "docker exec \$(docker ps -q -f name=$(state_get DB_UUID)) psql -U app -d app -tAc 'select count(*) from users'"
```

Expect `auth: link requested`, `mail: sent <id>`, `auth: signed in user 1` and a count of 1.
`auth: sign-in request failed: ...` names the SMTP error; the page said "couldn't send the
mail". The mail sent but not in the inbox: the spam folder, the provider's log, then step 9.
Match errors against the Mail table in `references/troubleshooting.md`.

## 8. Push-to-deploy and the record (you)

The GitHub webhook, the block of phase 05 step 6 with the state in P (`. "$SETUP_DIR/lib.sh";
P="<APP_STATE>"; VPS_STATE=$P` in front of it, `$SETUP_DIR/lib.sh` for `./lib.sh`), its test
push and `state_set WEBHOOK github` (or `none`, as there). Then the per-project keys are already
in P (`app_create` wrote `COOLIFY_APP_UUID`, `COOLIFY_PROJECT_UUID`, `COOLIFY_DOMAIN`), and the
server's list of projects:

```
. "$SETUP_DIR/lib.sh"; projects_md
```

Finish `DEPLOY.md`: URL, how deploys happen, the variable names (never values), where the data
lives (the four tables), backups (the same choice as phase 06, for this database), rollback
(`ROLLBACK.md`), the SMTP provider and where its password is rotated (step 10). Commit it with
the user's go-ahead.

## 9. Deliverability DNS (the user, docs only)

Mail from a domain without these records lands in spam or is refused. The provider's domain
page lists the exact records for the sender's domain; the user copies them into their DNS
provider (`dns_set_a` writes A records only, by design, and you never guess these values):

- **SPF**: one TXT record on the domain, `v=spf1 include:<the provider's value> ~all`. A domain
  has only one SPF record: an existing one gets the `include:` added, not a second record.
- **DKIM**: the CNAME or TXT records the provider shows (names like
  `<selector>._domainkey.<domain>`), copied exactly.
- **DMARC**: a TXT record on `_dmarc.<domain>`, `v=DMARC1; p=none` to start, stricter later.

Check what the world sees, then ask the provider's page to verify the domain:

```
D="<sender domain>"; dig +short TXT "$D" @1.1.1.1; dig +short TXT "_dmarc.$D" @1.1.1.1
```

Also off at the provider for this stream: click tracking (it rewrites the sign-in link through
the provider's servers).

## 10. Later

- **Rotate the SMTP password**: a new one at the provider, then the step 5 block again, a
  redeploy (`deploy_and_wait`), the old one revoked (`VAULT.md` 6.11).
- **Sign everyone out** (a leaked log from a `MAIL_LOG=1` run, a lost laptop): delete the
  sessions; nothing else changes, people sign in again with a new link:
  `rssh "docker exec \$(docker ps -q -f name=<DB_UUID>) psql -U app -d app -c 'delete from sessions'"`
  with the user's yes.
- **A staging copy** (`STAGING.md`): its own `SITE_URL` (`https://staging.<domain>`), and for
  mail the provider's test mode or a sandbox. `MAIL_LOG=1` does not work there: the app refuses
  to start with it when `SITE_URL` is `https://`.
- **Slow mail through the worker** (`WORKER.md`): a job kind that sends, enqueued by the app.
- **A page behind sign-in**: `starter-auth/README.md` ("A page behind sign-in"), in the app's
  repo as `README.md`.
- **Removing the app**: the Coolify UI (the app, then its database separately, after a dump);
  nothing in this file deletes. Then `projects_md`.
