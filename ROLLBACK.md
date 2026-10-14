# ROLLBACK: go back to the version that worked

You are an AI coding agent helping a user whose last deploy went wrong. Work from the repo root
of `vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`); every
command starts with `. ./lib.sh` and, for an app set up through PREPARE-APP, `VPS_STATE=.coolify.env`
in that app's repo. Rules from `SETUP.md` apply: API only via `capi`, server commands only via
`rssh`, nothing destructive without the user's yes, prove every step.

**Not run on a real server yet.** The functions are tested against a fake Coolify API only
(`test/lib.test.sh`); the API shapes used are checked against Coolify 4.3.23 where marked so in
`references/coolify-api.md`.

## What `deploy_and_wait` left you

Every deploy through `deploy_and_wait` prints, before touching anything:

```text
rollback point: commit <sha> (image on the server)
database dump: /root/db-dumps/<DB_UUID>/<UTC time>.dump
```

and records both in the state file: `state_get ROLLBACK_COMMIT`, `state_get LAST_DUMP`. The
rollback point is the commit of the last **finished** deployment, which is what was running
before this deploy. The dump is a `pg_dump` in custom format, taken on the server before the
deploy started; the newest ten per database are kept.

Two different problems, two different fixes:

| Symptom | What happened | Fix |
|---------|---------------|-----|
| `deploy_and_wait` printed `failed` | the build or the health check failed; Coolify kept the old container running | usually nothing to roll back: verify (step 1), fix the cause, deploy again |
| deploy `finished`, the app is wrong (errors, broken pages) | the new image runs and misbehaves, the data is intact | step 2 (roll back the image), then step 3 |
| deploy `finished`, data is missing or wrong | a migration changed or dropped data | steps 2, 3, then 4 (restore the dump); rows written since the dump are lost |

## 1. Verify first (read only)

```
. ./lib.sh; A=$(state_get APP_UUID); echo "app $A: $(capi GET "/applications/$A" | jq -r .status)"
capi GET "/deployments/applications/$A" | jq -r '.deployments[:5][] | "\(.status)\t\(.commit[0:8])\trollback=\(.rollback)\t\(.finished_at // "running")"'
echo "rollback point: $(state_get ROLLBACK_COMMIT)   dump: $(state_get LAST_DUMP)"
curl -s --max-time 10 -o /dev/null -w 'health %{http_code}\n' "https://$(state_get APP_DOMAIN)/api/health"
```

Read it with the user:

- Newest deployment `failed` and the app `running:healthy` with health `200`: the old version is
  still serving. Do not roll back. Fix the commit (the log tail `deploy_and_wait` printed, plus
  `references/troubleshooting.md`) and deploy again.
- Newest deployment `finished` and the app misbehaves: continue with step 2. Write down the
  current commit (the first line) as well; it is what you roll back **from**.
- No `ROLLBACK_COMMIT` in the state (deployed from the Coolify UI or by a push, not through
  `deploy_and_wait`): take the commit of the newest `finished` deployment **before** the bad one
  from the list above. Older than that only if the user says that version was good.

## 2. Roll back the image

Coolify keeps the images it built, tagged with the commit. A rollback redeploys one of them
without a rebuild (the same thing as Coolify → app → **Rollback** in the UI).

```
. ./lib.sh; A=$(state_get APP_UUID)
capi GET "/applications/$A/rollback-images" | jq -r '.images[] | "\(.tag[0:8])\t\(.created_at)"'
```

The rollback point must be in that list. If it is, with the user's yes:

```
. ./lib.sh; A=$(state_get APP_UUID); C=$(state_get ROLLBACK_COMMIT); rollback_and_wait "$A" "$C"
```

If the image is gone (Coolify's cleanup pruned it, or `deploy_and_wait` said "image not on the
server"), rebuild that commit instead: pin the app to it, deploy, unpin.

```
. ./lib.sh; A=$(state_get APP_UUID); C=$(state_get ROLLBACK_COMMIT)
capi PATCH "/applications/$A" "$(jq -n --arg c "$C" '{git_commit_sha:$c}')" >/dev/null && DEPLOY_SKIP_DUMP=1 deploy_and_wait "$A"
capi PATCH "/applications/$A" '{"git_commit_sha":"HEAD"}' >/dev/null && echo "app follows HEAD again"
```

`DEPLOY_SKIP_DUMP=1` because the dump from before the bad deploy is the one that matters; a new
dump now would capture the broken state. Run the second line even if the deploy fails,
otherwise the next push would build the old commit.

## 3. Check

```
. ./lib.sh; A=$(state_get APP_UUID); echo "app: $(capi GET "/applications/$A" | jq -r .status)"
capi GET "/deployments/applications/$A" | jq -r '.deployments[0] | "newest: \(.status) \(.commit[0:8]) rollback=\(.rollback)"'
curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"; echo
```

Expect `running:healthy`, the newest deployment `finished` with the rollback commit, and the
health route `200` with `"db":"ok"`. Then the user clicks through the app's main flow. If the
data is fine: stop here; a fix goes forward as a new commit, and the next push deploys HEAD as
usual (Coolify still follows the branch; a rollback does not pin it).

## 4. Only if a migration broke the data: restore the dump

This replaces the database with its state from before the deploy. Everything written since
(signups, orders) is lost. Say so, and get an explicit yes. If the app wrote important rows
since the dump, export them first (`rssh "docker exec <container> psql -U <user> -d <db> -c 'copy ...'"`)
and plan to re-insert them.

Stop the app so nothing writes during the restore, then restore, then start it:

```
. ./lib.sh; A=$(state_get APP_UUID); D=$(state_get DB_UUID)
rssh "ls -l /root/db-dumps/$D/"
capi POST "/applications/$A/stop" >/dev/null && sleep 5 && echo "app: $(capi GET "/applications/$A" | jq -r .status)"
```

Expect `exited:...`. The dump to restore is normally `state_get LAST_DUMP`; an older one from
the listing only if the user says so.

```
. ./lib.sh; A=$(state_get APP_UUID); D=$(state_get DB_UUID); db_restore "$D" "$(state_get LAST_DUMP)" &&
capi POST "/applications/$A/start" >/dev/null && sleep 15 && echo "app: $(capi GET "/applications/$A" | jq -r .status)"
```

`db_restore` is all or nothing (`pg_restore --single-transaction`): on an error nothing changes
and it prints why. The app's own migrations may run again on start; after step 2 that is the
old version's migrations, which the dump already contains, so they are no-ops.

Check the data the way phase 05 step 7 does, with the table that matters to this app:

```
. ./lib.sh; rssh "docker exec \$(docker ps -q -f name=$(state_get DB_UUID)) psql -U app -d app -tAc 'select count(*) from waitlist'"
```

(`app`/`app` are the starter's user and database; an app from PREPARE-APP has its own, see
`capi GET /databases/<DB_UUID> | jq '{postgres_user, postgres_db}'`.)

## 5. Afterwards

- Tell the user what runs now (commit), what data state it has (live, or restored from <time>),
  and what was lost, if anything.
- The broken commit is still on `main`. The fix is a new commit; a push deploys it, through the
  same dump-first path if they deploy with `deploy_and_wait`. Pushes trigger Coolify directly
  and skip the dump; for a risky change, deploy with `deploy_and_wait` instead of pushing.
- Migrations that cannot be rolled back are the reason for the expand/contract rule in
  `PREPARE-APP.md` step 3.
