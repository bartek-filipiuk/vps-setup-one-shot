# REBUILD: a new server from nothing, with the data back

You are an AI coding agent helping a user whose server is gone for good: deleted, its disk lost,
the provider account closed, or broken past what `DOCTOR.md` can fix. Or they move on purpose
to a new server (a new Ubuntu release, another Hetzner project). Work from the repo root of
`vps-setup-one-shot`; every command starts with `. ./lib.sh` and, for an app set up through
PREPARE-APP, `VPS_STATE=.coolify.env` in that app's repo. Rules from `SETUP.md` apply: API only
via `capi`, server commands only via `rssh`, nothing destructive without the user's yes, prove
every step.

**Not run on a real server yet.** `s3_backup_list` and `rebuild_inventory` are tested against a
fake Coolify API, a stubbed `ssh` and a fake `docker` only (`test/lib.test.sh`). No server has
been rebuilt with this file. Where the backups sit in the bucket and what `mc ls` prints come
from the Coolify 4.3.23 source and the `mc` documentation and are marked `[verify]` here and in
`references/coolify-api.md`.

This file adds no new way to set things up. It runs the phases again on a new server and puts
back only what lived in the databases. The phases do the work; this file says in which order,
what to clear first and what cannot come back.

## What survives and what does not

| Survives (on the user's machine or outside the server) | Gone with the server |
|--------------------------------------------------------|----------------------|
| `~/.config/vps-setup/state` (domains, app name, repo, bucket name, choices) | Coolify's database: apps, projects, environment variable values, deploy keys, the webhook secret, the S3 storage entry, notification settings, the admin login |
| `~/.config/vps-setup/s3.env`, `notify.env`, `cloudflare.env` | the API token in `~/.config/coolify/config` (it opens nothing now) |
| `~/.config/vps-setup/SERVER.md` (old IP and UUIDs, for reference) | `/root/db-dumps/` (the dumps `deploy_and_wait` took) |
| each app's `.coolify.env` (UUIDs only) and its `DEPLOY.md` | the volumes of services (n8n, Uptime Kuma, Forgejo) |
| the git repos on GitHub | Hetzner server backups, when the server was deleted: they belong to the server **[verify]** |
| the S3 bucket with the database backups (phase 06 step 1) | |
| the DNS records (they point at the old IP until step 2) | |

Without backups in the bucket there is nothing to restore: the apps come back from git with
empty databases. Say that before anything else if `state_get BACKUPS` does not contain `s3`.

### Why not Coolify's own instance backup

Coolify can back up its own database (**Settings** → **Backup**). Restoring it on a new server
needs the old `APP_KEY` from `/data/coolify/source/.env`, with which Coolify encrypts environment
values, keys and passwords, and the old `/data/coolify/ssh/keys/` (Coolify docs). This guide
never saved either, so after a lost server the restored secrets could not be read. So there is
one way: a fresh Coolify through the phases, and the data from the database backups.

## 0. Inventory and the user's yes (read only, then the user decides)

The old server is still running (a planned move)? Do this first, on it, while the old state is
in place: stop each app (`RESTORE.md` step 2 shows how) and run one backup now
(`db_backup_now`, phase 06 step 1b), so the newest backup has every row. The DNS switch in step
2 is then the cut-over.

```
. ./lib.sh; rebuild_inventory; ls -l ~/.config/vps-setup/ ~/.config/coolify/
```

It prints the keys that survive, the keys that belonged to the old server (with the old
database uuid; its backups in the bucket are named after it), and the exact commands that keep
a copy of the state and clear the old keys. It changes nothing. Ask the user which apps from
`PREPARE-APP.md` ran on the server (their repos are on this machine); each gets the same in
step 7. Tell them now what they will have to type again in step 7: every environment variable
value of those apps that is not generated (API keys, SMTP passwords), from their password
manager or the providers' dashboards. Coolify's copy is gone.

Then the yes: a new server costs money (phase 01 shows the types and prices). Say what is lost
for sure: everything written after the newest backup in the bucket, the service volumes, and the
`/root/db-dumps/` files. Wait for an explicit yes.

After the yes, run the commands `rebuild_inventory` printed, exactly as printed: a `cp -p` of the
state to `state.before-rebuild-<DATE>`, one `state_set <KEY> ''` per old key, and the `mv` of
`~/.config/coolify/config` aside. The keys must be cleared: while `ADMIN_REGISTERED`, `APP_UUID`,
`WEBHOOK` or `HANDOVER_DONE` are set, `verify.sh` counts phases 03, 05 and 06 as done, and while
`HOOK_ID` is set phase 05 step 6 creates no webhook. Then:

```
. ./lib.sh; ./verify.sh; echo "old database: $(VPS_STATE="$VPS_SETUP_STATE.before-rebuild-<DATE>" state_get DB_UUID)"
```

Expect `NEXT: phases/01-server.md` and the old database uuid. Hetzner with `SERVER_EXISTS=1` in
the state: that path takes an existing server; when the agent creates the new one, run
`state_set SERVER_EXISTS ''` (phase 00 then asks for `HCLOUD_LOCATION` if it is missing).

## 1. GitHub: the old webhook and deploy key (user's yes)

The old server's webhook and read-only deploy key are still on the starter's repo. Show them
(read only):

```
. ./lib.sh; R=$(state_get GH_REPO)
gh api "repos/$R/hooks" --jq '.[] | [.id, .config.url, (.last_response.code // "-")] | @tsv'
gh repo deploy-key list --repo "$R"
```

The old hook is the id in `VPS_STATE="$VPS_SETUP_STATE.before-rebuild-<DATE>" state_get HOOK_ID`.
Its URL will reach the new Coolify once DNS moves, but with the old secret, so every push
delivers a failing call. The old deploy key's private half was on the lost server's disk: whoever
has that disk can read the repo. Removing both is a change on the user's GitHub, so say that and
wait for their yes:

```
. ./lib.sh; R=$(state_get GH_REPO); gh api -X DELETE "repos/$R/hooks/<OLD_HOOK_ID>" && gh repo deploy-key delete "<OLD_KEY_ID>" --repo "$R" && echo removed
```

`<OLD_KEY_ID>` is the id of the key titled `coolify` in the list. The same for each app repo from
step 7, with that app's `GH_REPO` and its hook id from its `.coolify.env` copy.

## 2. New server, Coolify, panel domain: phases 01 to 04

Run them as written; `./verify.sh` leads. What differs on a rebuild:

- Phase 01, Hetzner: reuse the `vps-setup` ssh key and the `vps-setup-fw` firewall (the phase
  says so). If `hcloud server list` still shows the old server, `coolify-1` is taken: record
  `state_set SERVER_NAME coolify-2` instead. The old one is step 10.
- Phase 01 step 4, DNS: with `DNS_PROVIDER=cloudflare`, `dns_set_a` prints
  `A updated <old IP> -> <new IP>`. Run it also for every app domain (each app's `.coolify.env`
  has `COOLIFY_DOMAIN`) and every service domain. Any other DNS provider: the user changes the
  existing A records to the new IP, the same list of names.
- Phase 03: a new Coolify with a new admin account; the old login does not exist any more.
- Phase 04: a new API token, a new server uuid. The old config is already moved aside.

## 3. The starter's database and app, not deployed: phase 05 steps 2 to 4

Skip step 1: `APP_DIR` and `GH_REPO` survived and the repo is on GitHub
(`gh repo view "$(state_get GH_REPO)"`). Steps 2 to 4 create a new deploy key, the project, the
Postgres and the app with its `DATABASE_URL`. The app is created with `instant_deploy:false`, so
nothing runs yet; that matters for step 5. Do not run step 5 of phase 05 yet.

Same Postgres major as before: phase 05 creates `postgres:17-alpine`. If the old database had
been moved to 18 (`PG_UPGRADE_NEW` in the state copy, `UPGRADE.md` C), create the new one with
`postgres:18-alpine`: `pg_restore` does not read a dump made by a newer `pg_dump`.

```
. ./lib.sh; echo "db $(state_get DB_UUID) app $(state_get APP_UUID): $(capi GET "/applications/$(state_get APP_UUID)" | jq -r .status)"
```

Expect both uuids and a status that does not start with `running` (a never deployed app
**[verify]**).

## 4. The bucket: phase 06 step 1b, the storage only

`s3.env` and `S3_BUCKET` survived. The location (`fsn1`, `nbg1`, `hel1`) is not in the state:
the user reads it in the Hetzner Console (**Object Storage** → the bucket) **[verify]**.

```
. ./lib.sh; L="<LOCATION>"; s3_storage_create vps-setup-backups "https://$L.your-objectstorage.com" "$(state_get S3_BUCKET)" "$L"
```

Expect `S3 storage ... valid`; it records `S3_STORAGE_UUID`, which the next step needs. Do not
attach the schedule yet (step 8).

## 5. The newest backup into the new database

List what is in the bucket for the old database (read only). Coolify on the new server knows
none of the old runs, so this reads the bucket itself:

```
. ./lib.sh; O=$(VPS_STATE="$VPS_SETUP_STATE.before-rebuild-<DATE>" state_get DB_UUID); s3_backup_list "$O" | head -10
```

Columns: old database uuid, `last_modified`, size in bytes, key. Newest first. Agree with the
user on one row: the newest, unless the data was already wrong before the server was lost (then
ask when, as in `RESTORE.md` step 1). Write down its time and size. Errors:

- `no backups for database <uuid> ... (backups there are of: ...)`: the uuid is not the one the
  backups were made for (after `UPGRADE.md` C it is `PG_UPGRADE_NEW` of the copy). Show the list
  to the user; never pick another database's backups without their yes.
- `no backups in s3/...`: nothing to restore. The app comes back with an empty database.
- `listing of s3/... failed`: the key pair or the bucket is wrong (phase 06 step 1a, then step 4
  here again).

A key ending in `pg-dump-all-<time>.gz` comes from a schedule with `dump_all` on: a gzipped
`pg_dumpall` that `db_restore` cannot read. Stop and tell the user; that case is not covered here
(`RESTORE.md` step 4).

Download it into the **new** database's dump directory:

```
. ./lib.sh; D=$(state_get DB_UUID); K="<KEY FROM THE LIST>"; db_fetch_from_s3 "$D" "$K"
```

Expect `/root/db-dumps/<new DB_UUID>/s3-<name> <bytes>`, the same size as in the list. Then:

```
. ./lib.sh; D=$(state_get DB_UUID); P="<PATH FROM ABOVE>"; db_restore "$D" "$P"
```

The file lies under `DUMP_DIR/<new DB_UUID>/`, so `db_restore` takes it as this database's own
dump and needs no `RESTORE_FROM_DB`, although the backup was made of the old one. The app has
never run, so the guard for a running app passes too. Expect `restored ... into app`. A `text
format dump` or `not a valid archive` error: the schedule dumped all databases; `RESTORE.md` step 4 says to stop there.

## 6. Deploy, push-to-deploy, the data: phase 05 steps 5 to 8

Run them as written. `deploy_and_wait` first dumps the restored database (the first copy on the
new server), then deploys; migrations already in the backup do not run again. Step 6 creates a
new webhook with a new secret (`HOOK_ID` is empty now). Step 8 writes `.coolify.env` with the new
UUIDs.

The data check of step 7 is the honest limit of this file: the old server is gone, so there is
nothing to compare against. Check what can be checked and say so:

```
. ./lib.sh; rssh "docker exec \$(docker ps -q -f name=$(state_get DB_UUID)) psql -U app -d app -tAc 'select count(*) from waitlist'"
```

Compare the count with what the user remembers, tell them the backup's `last_modified` (every
row written after it is lost), and have them click through the main flow.

## 7. Every other app: PREPARE-APP step 5 and 6, one app at a time

In each app's repo, with `VPS_STATE=.coolify.env`:

1. `rebuild_inventory`, then the commands it prints (they start with `VPS_STATE=...`). The copy
   `.coolify.env.before-rebuild-<DATE>` is not covered by a `.coolify.env` line in `.gitignore`:
   never commit it (`git status` shows it); it holds UUIDs only.
2. `PREPARE-APP.md` step 5, up to creating the application; the repo is already deployable
   (steps 1 to 4 were done back then). The environment variable values are gone with Coolify:
   the user writes `.env.production` again from the names in `DEPLOY.md` or `.env.example`.
   Generated secrets (`openssl rand -hex 32`) get new values, so every session signed with the
   old one is invalid and users log in again. If the app encrypts stored data with such a secret,
   that data cannot be read without the old value: stop and tell the user. Build-time variables
   are marked in the UI again.
3. Step 5 of this file for the app's database (the old uuid from the app's
   `.coolify.env.before-rebuild-<DATE>`), before its first deploy.
4. `PREPARE-APP.md` step 6: deploy and check, with the app's own table for the row count.

## 8. Backups, alerts, services

Backups, phase 06 step 1b from the attach on (the storage exists since step 4):

```
. ./lib.sh; D=$(state_get DB_UUID)
db_backup_attach_s3 "$D" "$(state_get S3_STORAGE_UUID)" && db_backup_now "$D" "$(state_get BACKUP_UUID)" && db_backup_list "$D" | head -5
```

The same for each app's database, with `VPS_STATE=.coolify.env` and the storage from the setup
state: `"$(VPS_STATE=$VPS_SETUP_STATE state_get S3_STORAGE_UUID)"`. The old backups stay in the
bucket under the old uuid; the new schedule's retention counts only its own runs **[verify]**.
`BACKUPS` contains `hetzner`: enabling server backups on the new server costs 20% more, so only
on the user's yes (`hcloud server enable-backup "$(state_get SERVER_NAME)"`).

Alerts: `notify.env` survived, so phase 06 step 2b (`notify_setup discord`) and the test message
from the UI.

Services: `SERVICES.md` for each one the user had (the `SERVICE_<NAME>_UUID` keys in the state
copy give the names). Their volumes are gone: n8n, Uptime Kuma and Forgejo start empty, because
`lib.sh` drives no volume backups. A database inside a service (Umami) backed up from the UI has
its files in the bucket too, but restoring into a service's database is not covered
(`SERVICES.md` step 5); that needs a human.

## 9. Check and the new SERVER.md

Phase 06 step 3 writes `SERVER.md` again with the new IP and UUIDs (the command overwrites the old
one), step 4 records `HANDOVER_DONE=1`. Then:

```
./verify.sh; ./status.sh; echo "status exit $?"
```

Expect `ALL DONE` and `status exit 0`. Tell the user: which backup is live in each database (its
`last_modified`), what was lost (rows after it, service volumes), which secrets are new (deploy
keys, webhook secrets, generated app secrets, the API token).

## 10. The old server

Only after step 9 is green, and only if the old server still exists (`hcloud server list`, or the
provider's panel): it is still billed. Deleting it is irreversible, so name it and wait for the
user's yes: `hcloud server delete "<OLD SERVER_NAME from the state copy>"`. Keep the `vps-setup-fw`
firewall and the `vps-setup` ssh key; the new server uses them.

Afterwards: `~/.config/coolify/config.before-rebuild-<DATE>` holds the old API token, which opens
nothing now; delete it (`rm`). Keep the state copies until the user is happy, then delete them
too. The old database's backups in the bucket are deleted by the user in the Hetzner Console
when they no longer need them.

## Drill (not built yet)

How the test harness (roadmap R01, R15) will prove this file on throwaway servers, once a quarter.
Not run yet; the steps are the plan.

```text
1. Full setup on server A (phases 00-06, S3 backups on), one PREPARE-APP app.
2. Insert a marker row into the starter's waitlist and the app's main table; db_backup_now both.
3. Delete server A (hcloud server delete), its dumps with it.
4. This file, steps 0-9, on server B: rebuild_inventory, phases 01-04, phase 05 steps 2-4,
   s3_storage_create, s3_backup_list <old uuid>, db_fetch_from_s3, db_restore, deploy.
5. Check: both marker rows present; verify.sh -> ALL DONE; status.sh exit 0;
   a push to main deploys through the new webhook.
```

The drill passes when server B passes `verify.sh` and `status.sh` with both marker rows back.
That is the R15 done criterion.
