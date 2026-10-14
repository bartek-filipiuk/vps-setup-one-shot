# RESTORE: bring a database back from an off-site backup

You are an AI coding agent helping a user whose data is gone or wrong and who wants it back from
a backup in their S3 bucket (phase 06 step 1). Work from the repo root of `vps-setup-one-shot`
(or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`); every command starts with
`. ./lib.sh` and, for an app set up through PREPARE-APP, `VPS_STATE=.coolify.env` in that app's
repo. Rules from `SETUP.md` apply: API only via `capi`, server commands only via `rssh`, nothing
destructive without the user's yes, prove every step.

**Not run on a real server yet.** The functions are tested against a fake Coolify API, a stubbed
`ssh` and a fake `docker` only (`test/lib.test.sh`). `GET /s3-storages` was checked on a live
Coolify 4.3.23; the other S3 and backup calls come from the 4.3.23 source and are marked
`[verify]` in `references/coolify-api.md`.

Which runbook:

| Situation | Runbook |
|-----------|---------|
| a deploy just broke the app or a migration broke the data | `ROLLBACK.md` (the dump `deploy_and_wait` took is newer than any nightly backup) |
| data deleted or damaged some time ago, or the dumps in `/root/db-dumps/` are gone | this file |
| the server itself is gone | a new server first (phases 01–05), then this file; the full path is roadmap item R15 |

This restores **into an existing Coolify Postgres** (`DB_UUID` in the state). Everything written
after the chosen backup is lost.

## 1. List the backups (read only)

```
. ./lib.sh; D=$(state_get DB_UUID); db_backup_list "$D" | head -15
```

Columns: schedule, execution, `created_at`, status, size in bytes, S3 state, filename. Newest
first. S3 state:

- `uploaded`: Coolify reported the copy in the bucket.
- `unreported`: this Coolify does not report uploads and the run's message has no upload error.
  Most likely in the bucket; step 3 proves it.
- `upload-failed`, `not-uploaded`: not in the bucket. `local`: a schedule without S3. `-`: the
  run itself failed.

Read it with the user and agree on one row: the newest `uploaded` (or `unreported`) run from
**before** the data went wrong. Ask when that was; do not guess. Write down its filename and size.

## 2. Stop the app

Say this before anything changes: the database goes back to `<created_at of the row>`; everything
written since (signups, orders) is lost. Get an explicit yes. If the app wrote important rows
since, export them first (`rssh "docker exec <container> psql -U <user> -d <db> -c 'copy ...'"`)
and plan to re-insert them.

```
. ./lib.sh; A=$(state_get APP_UUID)
capi POST "/applications/$A/stop" >/dev/null && sleep 5 && echo "app: $(capi GET "/applications/$A" | jq -r .status)"
```

Expect `exited:...`.

## 3. Download the backup onto the server

Put the filename from step 1 into the command:

```
. ./lib.sh; D=$(state_get DB_UUID); F="<FILENAME>"; db_fetch_from_s3 "$D" "$F"
```

Expect one line, `/root/db-dumps/<DB_UUID>/s3-<name> <bytes>`, with the same size as in the
list. It runs `mc` in a throwaway container on the server; the S3 keys come from
`~/.config/vps-setup/s3.env` on this machine over the ssh connection's input, never on a command
line. Errors:

- `no S3 credentials` or `refusing ... mode`: the user writes `s3.env` again with the command
  from phase 06 step 1a (`chmod 600` fixes the mode).
- `download of s3/... failed`: the object is not in the bucket (the run's upload failed: pick
  another row) or the keys are wrong (Hetzner Console → **Security** → **S3 credentials**).

## 4. Restore

```
. ./lib.sh; A=$(state_get APP_UUID); D=$(state_get DB_UUID); P="<PATH FROM STEP 3>"; db_restore "$D" "$P" &&
capi POST "/applications/$A/start" >/dev/null && sleep 15 && echo "app: $(capi GET "/applications/$A" | jq -r .status)"
```

`db_restore` refuses while the app is `running*`. It is all or nothing (`pg_restore
--single-transaction --clean --if-exists`): on an error nothing changes and it prints why. What
`--clean` leaves behind (tables the backup does not know) and the `RESTORE_WIPE=yes` clean slate
are explained in `ROLLBACK.md` step 4; the same rules apply here, including the explicit yes for
a wipe.

Coolify's Postgres backups are `pg_dump --format=custom`, which `pg_restore` reads **[verify]**.
If `pg_restore` says the input is a text format dump, the schedule was set to dump all databases
(`dump_all`); stop and tell the user, that case is not covered here.

## 5. Check

Check the data the way phase 05 step 7 does, with the table that matters to this app:

```
. ./lib.sh; rssh "docker exec \$(docker ps -q -f name=$(state_get DB_UUID)) psql -U app -d app -tAc 'select count(*) from waitlist'"
curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"; echo
```

(`app`/`app` are the starter's user and database; an app from PREPARE-APP has its own, see
`capi GET /databases/<DB_UUID> | jq '{postgres_user, postgres_db}'`.) Expect the count the user
remembers for that time, the app `running:healthy` and the health route `200` with `"db":"ok"`.
Then the user clicks through the app's main flow.

## 6. Afterwards

- Tell the user which backup is live now (its `created_at`), and what was lost, if anything.
- The downloaded file stays in `/root/db-dumps/<DB_UUID>/` (`deploy_and_wait`'s retention prunes
  only `*.dump`, not `s3-*` files). Delete it when the user is happy:
  `rssh "rm /root/db-dumps/<DB_UUID>/s3-<name>"`.
- `./status.sh`: the `off-site` line should still be OK; the next scheduled backup copies the
  restored state.

## Drill (not built yet)

How the test harness (roadmap R01, R04) will prove this runbook on a throwaway server. Not run
yet; the steps are the plan.

```text
1. Insert a marker row:      insert into waitlist (email) values ('drill-<run id>@example.invalid')
2. Back up now:              db_backup_now <DB_UUID> <BACKUP_UUID>   -> success, S3: uploaded
3. Destroy:                  delete from waitlist   (count is 0)
4. Restore from S3:          app stop, db_fetch_from_s3 <DB_UUID> <newest filename>,
                             db_restore <DB_UUID> <path>, app start
5. Check:                    select count(*) from waitlist where email = 'drill-<run id>@example.invalid'   -> 1
                             status.sh -> "off-site <db>" OK
```

The drill passes when the marker row is back and the app is healthy. That is the R04 done
criterion.
