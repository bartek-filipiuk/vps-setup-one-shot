# WORKER: cron and a job queue as a second app from the same repo

You are an AI coding agent helping a user whose app needs background work: something on a
schedule (a nightly report, a cleanup) or slow work the web request should not wait for (mail,
an import, a webhook to another service). The worker is a **second Coolify app from the same
repo**: the same GitHub repo, deploy key, project and environment as the web app, built from
its own directory `worker/` (Coolify's base directory), with **no domain**, using the **web
app's own Postgres**. The web app enqueues a job with one SQL insert; the worker runs the jobs
and its schedules. The code is `starter-worker/` of this repo (`starter-worker/README.md`): Node
22, one dependency (`pg`), a `jobs` and a `cron_runs` table it creates itself.

`SETUP_DIR` below is the directory that contains this file. Every command sources the helpers:
`. "$SETUP_DIR/lib.sh"`. One state file is in play, **P**, the web app's state:
`~/.config/vps-setup/state` for the starter from phase 05, or `<app repo>/.coolify.env` for an
app set up with `PREPARE-APP.md`, always as an absolute path. The worker adds two keys to it:
`WORKER_APP_UUID` and `WORKER_BASE_DIR`. The blocks start with `P="<PROD_STATE>"`: put in the
absolute path of P.

All rules from `$SETUP_DIR/SETUP.md` apply: secrets never through the chat, server commands only
via `rssh`, API only via `capi`, prove every step, ask before anything destructive. Additionally:
**the database URL and the webhook secret never go into a command line, the chat or a file in
the repo**; the helpers read them from stdin.

**Not run on a real server yet.** `worker_create`, `worker_env_db`, `worker_enqueue`,
`worker_jobs` and `worker_teardown` are tested against a fake Coolify API and a stubbed `ssh`
only (`test/lib.test.sh`); the worker itself is built and checked with Docker and a real
Postgres in CI (`test/fixtures.sh starter-worker`: its health route, a job through the queue,
the cron slots, the database stopped). An app without a domain (`autogenerate_domain:false`),
the Dockerfile's `HEALTHCHECK` deciding the status, and one GitHub webhook deploying two apps of
one branch come from the Coolify 4.3.23 source and are marked `[verify]` in
`references/coolify-api.md`.

## 0. Preconditions

```
. "$SETUP_DIR/lib.sh"; capi GET /version && "$SETUP_DIR/status.sh" | grep -E '^(OK|WARN|FAIL) +app '
```

- The web app must be deployed and healthy (`OK app <name>`); a broken one is fixed first
  (`DOCTOR.md`).
- It must use a Coolify Postgres from this guide (`DB_UUID` in P). An app without one, or with
  another database, is not supported here: say so and stop.
- The worker shares the server: about 100 MB of memory and 200 MB of disk for the image more.
  With less than 1 GB of memory free or the disk above 80 % (`status.sh`), say so first.

What P has, and whether the repo is ready (no output after the keys means a clean tree):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P
for k in APP_UUID APP_NAME GH_REPO KEY_UUID DB_UUID APP_DIR WEBHOOK STAGING_APP_UUID WORKER_APP_UUID; do printf '%s=%s\n' "$k" "$(state_get "$k")"; done
D=$(state_get APP_DIR); git -C "$D" status --short | head; if test -e "$D/worker"; then echo "worker/ EXISTS in $D"; fi
```

`APP_UUID`, `APP_NAME`, `GH_REPO`, `KEY_UUID`, `DB_UUID` and `APP_DIR` must be set. A
`WORKER_APP_UUID` means a worker exists: skip to the step that is missing. Uncommitted changes:
ask the user to commit or stash first. An existing `worker/` directory that is not this worker:
ask the user for another directory name and use it instead of `worker` below (and as the base
directory in step 4).

## 1. The plan (read only), then the user's yes

Show the user, in one list:

- the app `<APP_NAME>-worker` in the same project and environment as the web app, from the same
  repo and branch, built from `/worker`, **no domain** (nothing of it is reachable from outside);
- the same database: two new tables, `jobs` and `cron_runs`, next to the app's own; the dump
  before every deploy and the backups cover them;
- what runs: the example schedules (`heartbeat` every 5 minutes, `prune` daily, which deletes
  only finished jobs older than 14 days) and the job kinds `echo` and `prune`; their own job
  kinds come later (`worker/README.md`);
- a push to the branch deploys both apps (step 6);
- the cost (step 0).

Write it into `DEPLOY.md` (a `## Worker` section; for the starter
`~/.config/vps-setup/SERVER.md`) and wait for their yes.

## 2. The code in the app's repo (you, push with the user's go-ahead)

The worker goes into the repo as `worker/`; the web app's image leaves it out:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
if test -e "$D/worker"; then echo "EXISTS: $D/worker, ask the user"; else
  cp -R "$SETUP_DIR/starter-worker" "$D/worker" && rm -rf "$D/worker/node_modules" &&
  { grep -qx 'worker' "$D/.dockerignore" 2>/dev/null || printf 'worker\n' >> "$D/.dockerignore"; } &&
  git -C "$D" add worker .dockerignore && git -C "$D" status --short
fi
git -C "$D" check-ignore -q worker/.env && echo "worker/.env gitignored" || echo "worker/.env NOT ignored"
```

`NOT ignored`: add `.env` (or `.env*` with `!.env.example`) to the repo's `.gitignore` in the
same commit. The landing's own repo (this one) keeps the worker at `starter-worker/`: there the
base directory is `/starter-worker`, nothing is copied.

With `WEBHOOK=github` in P the push deploys the web app too, without `deploy_and_wait`, so the
rollback point and the dump come first (as `STAGING.md` step 11):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P; A=$(state_get APP_UUID); DB=$(state_get DB_UUID)
prev=$(rollback_point "$A") && state_set ROLLBACK_COMMIT "$prev" && echo "rollback point: ${prev:-none}" &&
if [ -n "$DB" ]; then d=$(db_dump "$DB") && state_set LAST_DUMP "${d%% *}" && echo "database dump: ${d%% *}"; fi
```

Then the commit, on the app's branch, and the push with the user's go-ahead:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; D=$(VPS_STATE="$P" state_get APP_DIR)
git -C "$D" commit -q -m "Add the background worker (cron and job queue)" && git -C "$D" push -q origin HEAD && git -C "$D" log --oneline -1
```

The web app's redeploy changes nothing in it (its image does not contain `worker/`); check that
it is still `OK` with `status.sh` before going on.

## 3. Proof on your machine (you, optional, needs Docker)

The copy is the same code as `starter-worker/`, which CI builds and checks against a real
Postgres. To see it here first:

```
bash "$SETUP_DIR/test/fixtures.sh" starter-worker
```

Expect `ALL FIXTURES OK`. It creates only containers, images and a network named
`vps-fixture-starter-worker-<pid>` and removes them by name; nothing is pruned.

## 4. The app in Coolify (you)

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P
worker_create /worker && worker_env_db "$(state_get WORKER_APP_UUID)"
```

Expect `worker <name>-worker: <uuid> (created in ..., base directory /worker, no domain, not
deployed)`, the health check line and `set DATABASE_URL`. `worker_create` sends
`autogenerate_domain:false`: without it Coolify makes up a public `sslip.io` domain for an app
with none. A second run finds `WORKER_APP_UUID` and creates nothing. `worker_env_db` copies the
database's internal URL from Coolify to the worker through stdin; it is never printed. The web
app's other variables are not copied: a job that needs one (an SMTP password) gets it with
`app_env_set` (value on stdin), like `STAGING.md` step 5.

## 5. First deploy (you, 2-4 minutes)

`deploy_and_wait` dumps the shared database first. It also records `ROLLBACK_COMMIT` in P,
which belongs to the web app (`ROLLBACK.md`), so the block puts the web app's back afterwards:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P; keep=$(state_get ROLLBACK_COMMIT)
deploy_and_wait "$(state_get WORKER_APP_UUID)"; rc=$?; state_set ROLLBACK_COMMIT "$keep"; echo "deploy exit $rc"
```

On `failed`, read the log tail and `references/troubleshooting.md`, as in phase 05 step 5. Then
the worker's status, that it has no domain, and its tables (the first `heartbeat` and `prune`
run right after the start):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P; WK=$(state_get WORKER_APP_UUID)
sleep 20; capi GET "/applications/$WK" | jq -r '"status: \(.status), domain: \(.fqdn // "none")"' && worker_jobs
```

Expect `status: running:healthy`, `domain: none`, and `jobs done: 2` (or more). A domain other
than `none`: tell the user, remove it in the UI (the worker app → **General** → **Domains**,
empty, Save), and note it in `references/coolify-api.md`. `worker_jobs` saying there is no jobs
table: the worker has not started; `app_logs "$WK" 50` shows why (a wrong `DATABASE_URL` ends in
`migrate attempt 10/10 failed` and a restart).

A bad worker version goes back like the web app's, with `ROLLBACK.md` step 2 and the worker's
uuid: `rollback_and_wait <WORKER_APP_UUID> <commit>`, the commit of the worker's last good
deployment from its `rollback-images` list (`ROLLBACK_COMMIT` in P is the web app's). Its tables
are part of the web app's database: there is no separate restore.

## 6. Push-to-deploy for both apps (you)

The web app's GitHub webhook serves the worker too: Coolify's manual endpoint deploys every app
of the repo whose branch is the pushed one and whose secret signs the delivery [verify]. Coolify
does not give the secret back, so it is rotated: one new value onto the worker, the staging app
if there is one (`STAGING_APP_UUID`, it shares the hook), the web app last, and the hook, back to
back. Only when P has `WEBHOOK=github`:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P; STG=$(state_get STAGING_APP_UUID); W=$(openssl rand -hex 24) &&
printf '%s' "$W" | apps_webhook_secret "$(state_get WORKER_APP_UUID)" ${STG:+"$STG"} "$(state_get APP_UUID)" &&
printf '%s' "$W" | jq -Rs '{secret:.}' | gh api -X PATCH "repos/$(state_get GH_REPO)/hooks/$(state_get HOOK_ID)/config" --input - >/dev/null &&
echo "one secret on every app of the repo and the hook" && unset W
```

`apps_webhook_secret` stops at the first app that refuses and says which ones have the new
value. If the worker refused, nothing else changed: run the block again. If the web app refused
or the hook PATCH failed, the web app's push-to-deploy is broken until it and the hook agree: in
the same shell (`W` is still set) repeat
`printf '%s' "$W" | apps_webhook_secret <APP_UUID>` and the `gh api` line; if that shell is
gone, run the whole block again. From now on every rotation of this secret (`STAGING.md` step 9,
`HANDOVER.md` step 3, `VAULT.md` 6.6) uses this block, so no app of the repo is left behind.

The next push to the branch is the test. Note the newest deployment of both first, and after
the push compare (both must show the pushed commit):

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P
for a in "$(state_get APP_UUID)" "$(state_get WORKER_APP_UUID)"; do capi GET "/deployments/applications/$a" | jq -r --arg a "$a" '.deployments[0] | "\($a): \(.status) \(.commit)"'; done
```

If only the web app deployed: do not improvise. Tell the user; the worker then deploys with the
step 5 block after each push (write that into `DEPLOY.md`). With `WEBHOOK=none` in P that is the
way anyway.

## 7. Smoke test (you)

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; VPS_STATE=$P
worker_enqueue echo '{"hello":1}' && sleep 10 && worker_jobs && app_logs "$(state_get WORKER_APP_UUID)" 30 | grep -E 'echo: |job [0-9]+ '
```

Expect `enqueued job <id> echo`, one more `done` job, and the log lines `echo: {"hello":1}` and
`job <id> echo: done`. `jobs failed` above 0 later: `app_logs` shows the error of each attempt;
the row keeps it in `last_error`.

## 8. Record it (you)

```
. "$SETUP_DIR/lib.sh"; projects_md
```

Finish the `## Worker` section of `DEPLOY.md` (for the starter: `SERVER.md`): the app's name, no
domain, the base directory, the tables in the app's database, how it deploys (push, or step 5),
the schedules and job kinds, how the web app enqueues (below), and how to remove it (step 10).
Commit `DEPLOY.md` with the user's go-ahead. `status.sh` now lists the worker next to the web
app, without a certificate line.

## 9. Enqueue from the web app

Show the user the one insert their web app makes, in its own code, with its own database
connection (it already has `DATABASE_URL`):

```sql
insert into jobs (kind, payload) values ($1, $2::jsonb);
```

The web app never runs jobs itself, and never puts a secret into a payload (it is stored as
plain JSON in the database and its backups). A new job kind is a handler in
`worker/src/jobs.js`, a schedule an entry in `worker/src/cron.js` (`worker/README.md`); both
ship with the next push.

## 10. Remove the worker (after the user's yes)

Without `--yes` it only says what it would delete and sends nothing:

```
. "$SETUP_DIR/lib.sh"; P="<PROD_STATE>"; worker_teardown "$P"
```

Tell the user that the worker app goes and queued jobs stop running, then, on their yes, the
same with `--yes` at the end. It refuses the web app's and the staging app's uuid. It leaves the
`jobs` and `cron_runs` tables in the web app's database (drop them only on the user's yes, after
the web app no longer inserts), the `worker/` directory in the repo (remove it in a commit if it
should go) and the GitHub hook, which the web app still uses. Then `projects_md`, and remove the
`## Worker` section from `DEPLOY.md`.
