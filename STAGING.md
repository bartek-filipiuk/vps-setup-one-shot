# STAGING: a staging copy of an app on the same server

You are an AI coding agent helping a user who wants to try changes before production sees them.
Staging is a second Coolify app on the same server: the same repo, built from the branch
`staging`, in the same project under the environment `staging`, with its **own empty Postgres**,
on `staging.<app-domain>`, closed to the public with HTTP basic auth. A push to `staging` deploys
staging; promotion is a merge of `staging` into `main`, which deploys production.

`SETUP_DIR` below is the directory that contains this file. Every command sources the helpers:
`. "$SETUP_DIR/lib.sh"`. Two state files are in play, both gitignored and mode `600`:

- **P**, production's state: `~/.config/vps-setup/state` for the starter from phase 05, or
  `<app repo>/.coolify.env` for an app set up with `PREPARE-APP.md`. Always as an absolute path.
- **S**, staging's state: `<APP_DIR>/.coolify.staging.env`, the same keys as P. Every helper
  works on it with `VPS_STATE=$S`; P gets one key more, `STAGING_APP_UUID`.

The blocks start with `P="<PROD_STATE>"`: put in the absolute path of P. All rules from
`$SETUP_DIR/SETUP.md` apply: secrets never through the chat, server commands only via `rssh`,
API only via `capi`, prove every step, ask before anything destructive. Additionally:

- **No production data in staging by default.** Staging starts empty and its migrations create
  the schema. Copying production data is step 12, opt-in, with its own warning.
- **No value of an environment variable, the webhook secret or the basic-auth password goes
  into a command line, the chat or a file in the repo.** The helpers read them from stdin.

**Not run on a real server yet.** `staging_init`, `app_env_keys`, `app_env_set`, `app_create`,
`app_basic_auth`, `apps_webhook_secret` and `staging_teardown` are tested against a fake Coolify
API only (`test/lib.test.sh`). The `GET` shapes of an application and its environment variables
were checked read-only on a live Coolify 4.3.23; the basic-auth `PATCH`, the deletes, a second app
on the same deploy key and one GitHub webhook serving two branches come from the 4.3.23 source
and docs and are marked `[verify]` in `references/coolify-api.md`. Nobody has promoted a
change with this file yet.

## 0. Preconditions

```
. "$SETUP_DIR/lib.sh"; capi GET /version && "$SETUP_DIR/status.sh" | grep -E '^(OK|WARN|FAIL) +app '
```

- Production must be deployed and healthy (`OK app <name>`). Staging copies its setup; a broken
  production is fixed first (`DOCTOR.md`).
- The second app and database share the server: about 300 MB of memory and a few GB of disk
  more. With less than 1 GB of memory free or the disk above 80 % (`status.sh`), say so first.
- Which P: the starter, or an app from `PREPARE-APP.md` (then work in that app's repo). P must
  have `APP_UUID`, `GH_REPO`, `KEY_UUID`, `APP_DOMAIN` and `PROJECT_UUID`; `staging_init` says
  which one is missing.
- The staging state must never be committed, and never baked into the image:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
git -C "$D" status --short | head; git -C "$D" check-ignore -q .coolify.staging.env && echo "gitignored" || echo "NOT ignored"
grep -qF '.coolify' "$D/.dockerignore" 2>/dev/null && grep '.coolify' "$D/.dockerignore" || echo "no .coolify line in .dockerignore"
```

`NOT ignored`: add a line `.coolify*.env` to the repo's `.gitignore` (and the same line to
`.dockerignore`), with the user's go-ahead; it is a change in their repo, committed on `main`
before step 2 so the branch has it too. Uncommitted changes: ask the user to commit or stash first.

## 1. The plan (read only), then the user's yes

`staging_init` writes S from P and calls nothing; the rest of this step only reads:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
staging_init "$P" "$S"
```

It prints the plan: the app `<name>-staging` from branch `staging` on
`https://staging.<APP_DOMAIN>`, in the project's `staging` environment, with the database
`<name>-staging-db`. Then check the domain, the branch and production's variables:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
domain_in_use "$(VPS_STATE="$S" state_get APP_DOMAIN)"; echo "exit $?"
gh api "repos/$(VPS_STATE="$S" state_get GH_REPO)/branches/staging" --jq '"branch staging exists at \(.commit.sha)"' 2>/dev/null || echo "no staging branch yet"
app_env_keys "$(VPS_STATE="$P" state_get APP_UUID)" | column -t -s "$(printf '\t')"
```

- `domain_in_use` exit 1 is free; exit 0 prints who has the name: the user picks another
  host, then `VPS_STATE="$S" state_set APP_DOMAIN <host>`; exit 2 means Coolify could not be read.
- `app_env_keys` lists names only (Coolify does not return values in the list). Per kind:
  `database`: staging's own `DATABASE_URL` (step 5), never production's. `secret`: a new random
  value when it is the app's own (session, auth or signing secrets), or, for a key of another
  service (Stripe, SMTP, an OAuth client secret), the user's **test-mode** value. `ask`: the
  user gives the staging value; URLs such as `NEXT_PUBLIC_SITE_URL` become
  `https://staging.<APP_DOMAIN>`. Outgoing mail from staging goes to a test inbox or nowhere.

Show the user the plan in one list: names, domain, branch, an empty database, each variable with
its kind and what it gets, the basic-auth user (`preview` unless they want another), and the
cost (step 0). Write it into `DEPLOY.md` (a `## Staging` section; for the starter
`~/.config/vps-setup/SERVER.md`) and wait for their yes.

## 2. The branch (you, push with the user's go-ahead)

Skip when step 1 found the branch. Otherwise it starts from `main`; nothing in the working tree
changes:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
git -C "$D" fetch -q origin && git -C "$D" push origin "refs/remotes/origin/main:refs/heads/staging" && echo "branch staging pushed"
```

## 3. The environment (you)

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; env_ensure "$(state_get PROJECT_UUID)" staging && project_ctx
```

Expect `<project uuid> staging`. A project that already had a `staging` environment (made in
the UI) is used as it is.

## 4. The database (you)

The same body as phase 05 step 3, with the staging state; the password reaches `jq` on stdin,
not as an argument. Skip when S already has a `DB_UUID` that `capi GET "/databases/<uuid>"` finds:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; read -r PU E < <(project_ctx) && [ "$E" = staging ] &&
B=$(openssl rand -hex 24 | jq -Rn --arg p "$PU" --arg e "$E" --arg s "$(coolify_server)" --arg n "$(state_get APP_NAME)-db" \
  '{project_uuid:$p, server_uuid:$s, environment_name:$e, name:$n,
    image:"postgres:17-alpine", postgres_user:"app", postgres_password:input, postgres_db:"app",
    is_public:false, instant_deploy:true}') &&
state_set DB_UUID "$(capi POST /databases/postgresql "$B" | jq -r .uuid)"; echo "db: $(state_get DB_UUID)"
```

Wait until it runs (up to two minutes):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; for _ in $(seq 1 12); do s=$(capi GET "/databases/$(state_get DB_UUID)" | jq -r .status); echo "$s"; case "$s" in running*) break;; esac; sleep 10; done
```

## 5. The application and its variables (you)

The same port, health path and base directory as production (in `DEPLOY.md`, or read them):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"
capi GET "/applications/$(VPS_STATE="$P" state_get APP_UUID)" | jq '{ports_exposes, health_check_path, base_directory, git_branch}'
```

Then the app, not deployed yet; `app_create` checks again that the domain is free and sends
nothing if it is not (`<BASE_DIR>` only when production has one other than `/`):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; app_create staging "<PORT>" "<HEALTH_PATH>"
```

Staging's own `DATABASE_URL`, refused when the uuid is production's:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; A=$(state_get APP_UUID); DB=$(state_get DB_UUID)
[ -n "$DB" ] && [ "$DB" != "$(VPS_STATE="$P" state_get DB_UUID)" ] &&
capi GET "/databases/$DB" | jq -r .internal_db_url | app_env_set "$A" DATABASE_URL
```

New random values for the app's own secrets from step 1 (the names the user agreed to, space
separated in `K`):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; A=$(state_get APP_UUID); K="<AUTH_SECRET SESSION_SECRET>"
[ -n "$A" ] && [ "$A" != "$(VPS_STATE="$P" state_get APP_UUID)" ] &&
for k in $K; do openssl rand -hex 32 | app_env_set "$A" "$k"; done
```

The rest: the user writes `.env.staging` in the app's repo in their own editor, `KEY=value` per
line, no quotes, only staging and test-mode values. Check it is gitignored
(`git check-ignore -q .env.staging`; `.env*` usually covers it), never `cat` it, then upload:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; A=$(state_get APP_UUID); D=$(state_get APP_DIR)
[ -n "$A" ] && [ "$A" != "$(VPS_STATE="$P" state_get APP_UUID)" ] &&
grep -Ev '^[[:space:]]*(#|$)' "$D/.env.staging" | while IFS='=' read -r k v; do printf '%s' "$v" | app_env_set "$A" "$k"; done
```

Then the user deletes the file. Compare the names (no output means none is missing):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
diff <(app_env_keys "$(VPS_STATE="$P" state_get APP_UUID)" | cut -f1) <(app_env_keys "$(VPS_STATE="$S" state_get APP_UUID)" | cut -f1)
```

Build-time variables (`build_time yes` in production) are marked in the UI, as in
`PREPARE-APP.md` step 5: the staging app → **Environment Variables** → the variable → the
build-time option → Save. Ask the user to do it and confirm.

## 6. Not public: basic auth (the user, in their own terminal)

The password exists only in the user's terminal and their password manager: not in the chat,
not in a state file. The user runs this in a terminal of their own (not through you, and not
with Claude Code's `!`, whose output lands in the chat), with the staging `APP_UUID` you give
them:

```
cd "<SETUP_DIR>" && . ./lib.sh && A="<STAGING_APP_UUID>" && PW=$(openssl rand -hex 16) &&
printf '%s' "$PW" | app_basic_auth "$A" preview && echo "staging login: preview / $PW (into your password manager now)" && unset PW
```

Expect `basic auth on for <uuid>, user preview`. If it prints `Coolify refused the basic-auth
fields`, the user does it in the UI: the staging app → **Advanced** → **HTTP Basic Auth**, user
`preview`, a password from their password manager, Save. Coolify applies it with the next
deploy [verify], so this comes before step 8. `app_basic_auth "$A" off` turns it off again.

## 7. DNS (you or the user)

As `PREPARE-APP.md` step 5: an **A** record for the staging host pointing to the server IP, no
AAAA, DNS only. With `DNS_PROVIDER=cloudflare` you create it; then the gate before the first
deploy:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
H=$(VPS_STATE="$S" state_get APP_DOMAIN); IP=$(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP)
if [ "$(VPS_STATE=$VPS_SETUP_STATE state_get DNS_PROVIDER)" = cloudflare ]; then dns_set_a "$H" "$IP"; echo "exit $?"; fi
echo "dns: $(dig +short A "$H" @1.1.1.1 | paste -sd ' ' -), server: $IP"
```

The two must match (exit codes of `dns_set_a` as in phase 01, step 4). Otherwise the user adds
the record at their DNS provider, and you check again.

## 8. First deploy (you, 3-6 minutes)

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; deploy_and_wait "$(state_get APP_UUID)"
```

With S it dumps staging's (empty) database, never production's. On `failed`, read the log tail
and `references/troubleshooting.md`, as in phase 05 step 5. Then HTTPS, and the door closed:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
H=$(VPS_STATE="$S" state_get APP_DOMAIN)
for i in $(seq 1 18); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$H/"); echo "try $i: $c"; [ "$c" = 401 ] && break; sleep 10; done
```

- `401`: up over valid HTTPS and closed. The user checks the inside in their own terminal (curl
  asks for the password, nothing on the command line): `curl -su preview https://<staging host>/api/health`
  (their health path) must show `"db":"ok"`; then they click through the app in the browser.
- `200` without a login: **staging is public**. Stop, tell the user, and fix step 6 before
  anything else (the UI path, then deploy again).
- `000` after three minutes: certificate or DNS, `DOCTOR.md` section 2.

## 9. Push-to-deploy for `staging` (you)

Production's GitHub webhook serves staging too: Coolify's manual endpoint deploys every app of
the repo whose branch is the pushed one and whose secret signs the delivery [verify]. Coolify does
not give the secret back, so it is rotated: one new value onto production, staging and the
hook, back to back (a push in between is rejected and simply not deployed). Only when P has
`WEBHOOK=github`:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; W=$(openssl rand -hex 24) &&
printf '%s' "$W" | apps_webhook_secret "$(state_get APP_UUID)" "$(VPS_STATE="$P" state_get APP_UUID)" &&
printf '%s' "$W" | jq -Rs '{secret:.}' | gh api -X PATCH "repos/$(state_get GH_REPO)/hooks/$(state_get HOOK_ID)/config" --input - >/dev/null &&
echo "one secret on production, staging and the hook" && unset W
```

Staging goes first: if it refuses, production and the hook still share the old secret and
nothing else changed; run the block again. `apps_webhook_secret` stops at the first app that
refuses and says which ones have the new value. If staging got it and production refused, or
the hook PATCH failed after both apps got it, production's push-to-deploy is broken until
production and the hook agree. In the same shell (`W` is still set; it is unset only on
success), repeat with the same value:
`printf '%s' "$W" | apps_webhook_secret <PROD_APP_UUID>`, then
`printf '%s' "$W" | jq -Rs '{secret:.}' | gh api -X PATCH "repos/<GH_REPO>/hooks/<HOOK_ID>/config" --input -`.
If that shell is gone, run the whole block again (a fresh value for all three). Test with a push to `staging`
only (an empty commit made without touching the working tree), and note production's newest
deployment first:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; D=$(state_get APP_DIR); before=$(capi GET "/deployments/applications/$(VPS_STATE="$P" state_get APP_UUID)" | jq -r '.deployments[0].deployment_uuid // "none"')
git -C "$D" fetch -q origin && c=$(git -C "$D" commit-tree -p origin/staging -m "Test push-to-deploy (staging)" "origin/staging^{tree}") &&
git -C "$D" push -q origin "$c:refs/heads/staging" && sleep 20 &&
gh api "repos/$(state_get GH_REPO)/hooks/$(state_get HOOK_ID)/deliveries" --jq '[.[] | select(.event=="push")][0] | "\(.status_code) \(.delivered_at)"' &&
echo "staging: $(capi GET "/deployments/applications/$(state_get APP_UUID)" | jq -r '.deployments[0] | "\(.status) \(.commit)"')" &&
echo "production newest: $(capi GET "/deployments/applications/$(VPS_STATE="$P" state_get APP_UUID)" | jq -r '.deployments[0].deployment_uuid // "none"') (before: $before)"
```

Expect `200`, a staging deployment of commit `$c` and production's newest deployment unchanged.
Then `VPS_STATE="$S" state_set WEBHOOK github`. If production deployed too, or the delivery is
not `200` and you cannot fix it: do not improvise. Tell the user; staging then deploys by hand
(`VPS_STATE="$S" state_set WEBHOOK none`). With `WEBHOOK=none` in P, staging is `none` as well:
every deploy is the step 8 command.

## 10. Record it (you)

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE="$P" state_set STAGING_APP_UUID "$(VPS_STATE="$S" state_get APP_UUID)" && projects_md
```

Finish the `## Staging` section of `DEPLOY.md` (for the starter: `SERVER.md`): the URL, the
branch, the basic-auth user (never the password; where the user keeps it), how it deploys (push
to `staging`, or step 8), the variables whose staging value differs (names only), **"no
production data"**, how to promote (step 11) and how to remove it (step 13). Commit `DEPLOY.md`
with the user's go-ahead. `status.sh` now lists the app under `project <name> / staging`.

## 11. Promotion: merge `staging` into `main`

Promotion is a merge, never a second way to deploy. When staging works and the user says so,
show what goes over (read only):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
git -C "$D" fetch -q origin && git -C "$D" log --oneline origin/main..origin/staging && git -C "$D" diff --stat origin/main...origin/staging
```

A migration in it follows the expand-then-contract rule (`PREPARE-APP.md` step 3): a contract
step goes over only after the expand step has been live and quiet in production.

With `WEBHOOK=github` in P the push to `main` deploys production without `deploy_and_wait`, so
the rollback point and the dump come first, from P:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P; A=$(state_get APP_UUID); DB=$(state_get DB_UUID)
prev=$(rollback_point "$A") && state_set ROLLBACK_COMMIT "$prev" && echo "rollback point: ${prev:-none}" &&
if [ -n "$DB" ]; then d=$(db_dump "$DB") && state_set LAST_DUMP "${d%% *}" && echo "database dump: ${d%% *}"; fi
```

Then the merge, on `main` in the app's repo (clean working tree), and the push with the user's
go-ahead:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
git -C "$D" switch -q main && git -C "$D" pull -q --ff-only && git -C "$D" merge --no-ff -m "Promote staging to production" origin/staging &&
git -C "$D" log --oneline -1
```

A conflict: stop, show it to the user, never resolve it by guessing. After the push
(`git -C "$D" push origin main`), watch production's deployment in the Coolify UI or with
`capi GET "/deployments/applications/<APP_UUID>"`, then the health route as in phase 05 step 5.
With `WEBHOOK=none` in P, deploy it instead: `VPS_STATE="$P" deploy_and_wait "<APP_UUID>"` (it
takes the dump itself). A bad version goes back with `ROLLBACK.md` and P. A fix made directly on
`main` is merged into `staging` afterwards, so staging does not fall behind.

## 12. Optional: production data in staging (opt-in)

**A copy of production's database is personal data in a second place**: the same users,
emails and orders, with the same obligations (GDPR, the client's contract). Basic auth does not
change that; it is still a copy. Do this only after the user says yes to exactly this, in their
own words, after you said the above. Better: seed data or an anonymised dump the app's own
tooling makes. Before the copy, staging must not reach real people: its mail goes to a test
inbox or nowhere, payments in test mode, no cron that writes to other systems.

Stop staging, then dump production and restore the dump into staging's database:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
VPS_STATE=$S; A=$(state_get APP_UUID)
capi POST "/applications/$A/stop" >/dev/null && sleep 5 && echo "staging: $(capi GET "/applications/$A" | jq -r .status)"
```

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
PD=$(VPS_STATE="$P" state_get DB_UUID); VPS_STATE=$S; SD=$(state_get DB_UUID)
[ -n "$PD" ] && [ -n "$SD" ] && [ "$PD" != "$SD" ] && d=$(db_dump "$PD") &&
RESTORE_FROM_DB=$PD RESTORE_WIPE=yes db_restore "$SD" "${d%% *}" &&
capi POST "/applications/$(state_get APP_UUID)/start" >/dev/null && echo "staging started with the copy"
```

`db_restore` refuses while staging runs, and the target is always staging's own database.
Write into `DEPLOY.md` that staging holds a copy from that day, and remove it when it is no
longer needed (step 13, or run the restore of an empty seed).

## 13. Remove staging (after the user's yes)

Without `--yes` it only says what it would delete and sends nothing:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; S="$(VPS_STATE="$P" state_get APP_DIR)/.coolify.staging.env"
staging_teardown "$S"
```

Tell the user that the staging app and its database go with their volumes (all staging data),
then, on their yes, the same with `--yes` at the end. It refuses a file `staging_init` did not
write and any uuid that is production's. It leaves the DNS record (remove it at the DNS provider,
or in Cloudflare, if it should go), the `staging` branch (`git push origin --delete staging`, on
the user's yes) and the GitHub hook, which production still uses with the shared secret. Then
`projects_md`, and remove the `## Staging` section from `DEPLOY.md`. `staging_init` can start
again later with the same files.
