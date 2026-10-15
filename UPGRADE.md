# UPGRADE: Coolify, Ubuntu and Postgres major versions

You are an AI coding agent helping a user keep their server current: a newer Coolify, Ubuntu
package updates with a reboot, or a Postgres database moved to a new major version. Work from
the repo root of `vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in
`PREPARE-APP.md`); every command starts with `. ./lib.sh` and, for an app set up through
PREPARE-APP, `VPS_STATE=.coolify.env` in that app's repo. Rules from `SETUP.md` apply: API only
via `capi`, server commands only via `rssh`, nothing destructive without the user's yes, prove
every step.

**Not run on a real server yet.** `db_major`, `pg_major_upgrade_plan`, the `RESTORE_FROM_DB`
guard of `db_restore` and the `status.sh` updates and postgres lines are tested against a fake
Coolify API, a stubbed `ssh` and a fake `docker` only (`test/lib.test.sh`,
`test/status.test.sh`). No Coolify, Ubuntu or Postgres upgrade has been done with this file yet.
What comes from the Coolify 4.3.23 source rather than a live server is marked `[verify]` here
and in `references/coolify-api.md`.

Which section:

| `./status.sh` says | What is due | Section |
|--------------------|-------------|---------|
| `WARN version <installed>, latest release <newer> (minor or major update behind ...)` | a newer Coolify | A |
| `WARN updates ... security ...` or `... reboot pending N days` | Ubuntu packages, a reboot | B |
| `WARN reboot required ...` alone | a reboot (the updates are in) | B, step 3 |
| `WARN postgres <name> 16 (...), major upgrade due` | a Postgres major version | C |

A patch release of Coolify (4.3.23 → 4.3.30) is `OK` in `status.sh`: upgrade it when the user
asks, or together with the next minor. One upgrade at a time: finish and check one section
before starting another.

## A. Coolify

Facts first. Coolify has **no API call** to upgrade itself or to read its update settings
(4.3.23 source: the only settings route is `/settings/email`). The **Upgrade** button in the UI
and Coolify's own auto-update both run `/data/coolify/source/upgrade.sh <version>` on the
server; by hand it is `curl -fsSL https://cdn.coollabs.io/coolify/upgrade.sh | bash -s <version>`,
and it refuses a downgrade. Phase 03 installs whatever is newest, without a pin; the version this
guide is tested with is the one in `references/coolify-api.md` (4.3.23). Everything newer is
untested until a run proves it, which is why step 2 reads the release notes.

### 1. Before (read only, plus a dump and a backup)

```
./status.sh | grep -E '^(OK|WARN|FAIL) +(version|backup|off-site|app) '
. ./lib.sh; capi GET /deployments | jq -r 'if type == "array" then "deployments running or queued: \(length)" else "could not read" end'
```

Go on only when: the `off-site` line of every database is `OK` (a backup in S3 from the last
day; otherwise fix that first, `RESTORE.md`), and no deployment is running or queued
(`GET /deployments` lists the ones in progress **[verify]**; wait for them to finish).

Dump the app's database on the server, as before a risky deploy:

```
. ./lib.sh; D=$(state_get DB_UUID); db_dump "$D"
```

Expect `/root/db-dumps/<DB_UUID>/<time>.dump <bytes>`.

Then the user, in the Coolify UI (the API has neither):

- **Settings** → **Backup**: **Backup Now**, and wait until the new backup shows as finished
  **[verify]**. That is Coolify's own database (projects, apps, settings, tokens), not your app's
  data; it is the only way back from a bad Coolify upgrade (step 5). If an S3 storage is
  attached there, the copy also goes off the server.
- **Settings** → **Updates**: note whether auto-update is on, and tell the user what it means:
  Coolify then upgrades itself on its own schedule, so the server may already run a version
  this guide has not tested. Turning it off is the user's call; this file does not change it.

### 2. Target and release notes (read only)

The newest version Coolify itself offers comes from `versions.json` (the same file its update
check reads); `status.sh` compares with the newest GitHub release instead, which can be a day
or two ahead.

```
. ./lib.sh; echo "installed: $(capi GET /version | tr -d '"')"
echo "newest offered: $(curl -fsS --max-time 10 https://cdn.coollabs.io/coolify/versions.json | jq -r '.coolify.v4.version')"
```

The target is the newest offered version unless the user picks an older one. Now every release
between the installed version and the target, from GitHub, and the lines in their notes that
mention an API path this guide uses (taken from `references/coolify-api.md`), an API change or a
breaking change:

```
. ./lib.sh; T="<TARGET>"; C=$(capi GET /version | tr -d '"'); RN=$(mktemp)
P=$(grep -oE '`(GET|POST|PATCH|PUT|DELETE)[^`]* /[a-z0-9-]+' references/coolify-api.md | grep -oE '/[a-z0-9-]+$' | sort -u | paste -sd'|' -)
curl -fsS --max-time 20 'https://api.github.com/repos/coollabsio/coolify/releases?per_page=100' |
  jq -r --arg c "$C" --arg t "$T" 'def v: ltrimstr("v") | split("-")[0] | split(".") | map(tonumber? // 0);
    .[] | select(.draft | not) | select((.tag_name | v) > ($c | v) and (.tag_name | v) <= ($t | v))
    | "=== \(.tag_name) \(.published_at[0:10])\(if .prerelease then " (pre-release)" else "" end)", (.body // "" | split("\n")[])' > "$RN"
echo "releases from $C to $T: $(grep -c '^=== ' "$RN")   notes: $RN"
grep -inE "^=== |breaking|deprecat|removed|migration|api|$P" "$RN" | head -80
```

Read the hits with the user. Stop and keep the installed version when a release changes or
removes an endpoint in `references/coolify-api.md`, changes how backups, notifications or
deploys work, or says to do something by hand before upgrading. Pre-releases are only listed;
never pick one as the target. Zero releases listed means the target is not newer or GitHub did
not answer: check the two versions again.

### 3. Upgrade (the user's yes)

Say this first: the Coolify panel and API are down for a few minutes while the new containers
start; the apps keep serving, because the proxy and the app containers are not restarted
**[verify]**. Get an explicit yes, then:

```
. ./lib.sh; T="<TARGET>"; [[ $T =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $T"; false; } &&
rssh "curl -fsSL https://cdn.coollabs.io/coolify/upgrade.sh | bash -s $T" 2>&1 | tail -30
```

Then wait until the API answers with the new version (up to five minutes):

```
. ./lib.sh; T="<TARGET>"; for i in $(seq 1 30); do v=$(capi GET /version 2>/dev/null | tr -d '"'); echo "try $i: ${v:-API not answering}"; [ "$v" = "$T" ] && break; sleep 10; done
```

If the script stops with an error, match it in `references/troubleshooting.md` ("Coolify
install and panel": disk full, apt lock) and run step 3 again; it is safe to re-run.

### 4. Check

```
./verify.sh | tail -3; ./status.sh; echo "status.sh exit $?"
. ./lib.sh; curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"; echo
```

Expect `verify.sh` at the same phase as before, `status.sh` with `OK version <TARGET> (latest)`
(or `latest release ...` when GitHub is ahead) and nothing new in `WARN` or `FAIL`, and the
health route `200` with `"db":"ok"`. Then the user opens the panel and an app page. Tell the
user the new version; if it is newer than the one in `references/coolify-api.md`, say that this
guide has not been tested on it yet.

### 5. If the new Coolify is broken: this needs a human

There is no automatic way back. A downgrade is refused by `upgrade.sh`, and Coolify's database
may already be migrated to the new version. The way back is the instance backup from step 1
(Coolify docs: restoring a Coolify instance from its backup), done by a person who reads the
docs for that version. A downgrade by reinstalling the old version is only an option when the
release notes from step 2 list no database migrations, and only when that person agrees. Your
apps and their databases are not touched by any of this; the dump from step 1 is on the server.

## B. Ubuntu

Phase 02 turned on `unattended-upgrades`: security updates install themselves every day. This
section covers what it leaves: the other package updates, a reboot for a new kernel, and a
reboot that has been waiting too long. `status.sh` reads `apt-check` on the server (from
`update-notifier-common`; present on an Ubuntu 24.04 machine checked on 2026-10-15, assumed on
Hetzner's image **[verify]**) and the age of `/var/run/reboot-required`.

### 1. Before (read only; a snapshot only on the user's yes)

```
. ./lib.sh; rssh 'cat /etc/os-release | grep PRETTY; uptime; /usr/lib/update-notifier/apt-check --human-readable; cat /var/run/reboot-required.pkgs 2>/dev/null; tail -5 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null'
```

Security updates still waiting a day after they were released mean `unattended-upgrades` did not
run or failed: its log above says why (most often a full disk or a held package).

Optional, costs money: a Hetzner snapshot of the whole server, the fastest way back if the
server does not come back after the reboot. Snapshots are billed per GB per month until they are
deleted. Only with the user's yes (Hetzner only):

```
. ./lib.sh; hcloud server create-image --type snapshot --description "before upgrade $(date -u +%F)" "$(state_get SERVER_NAME)"
```

### 2. Updates

The same line as phase 02:

```
. ./lib.sh; rssh 'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
O="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
apt-get update -q && apt-get -y -q $O upgrade
test -f /var/run/reboot-required && echo REBOOT-NEEDED || echo no-reboot'
```

`apt-get upgrade` installs updates but never removes packages or installs new ones; a package
listed as "kept back" waits for the next run or a person. An apt lock error means
`unattended-upgrades` is running: wait two minutes and run it again.

### 3. Reboot (in a window the user agreed to)

Every app and the panel are down during a reboot, usually one to two minutes. Agree on a time
with the user, then:

```
. ./lib.sh; rssh reboot; sleep 60; for i in $(seq 1 12); do rssh uptime && break; sleep 10; done
```

The ssh to `reboot` may report a closed connection; that is expected.

### 4. Check

```
./status.sh; echo "status.sh exit $?"
. ./lib.sh; curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"; echo
```

Expect `OK reboot not required`, `OK updates none pending` (or a few without security ones),
every app `running:healthy`, and the health route `200`. An app that did not come back: `DOCTOR.md`.
Delete the snapshot when the user is happy: `hcloud image list --type snapshot`, then
`hcloud image delete <id>`.

### Release upgrades (24.04 → 26.04): this needs a human

`do-release-upgrade` replaces most of the system, asks questions on the way and cannot be undone.
Docker, Coolify and the apps must be checked against the new release first. This file does not
do it. The path a person can take: a new server on the new release, the apps moved to it
(`REBUILD.md`, roadmap R15, once it exists), or the release upgrade with a snapshot, in a long
window.

## C. Postgres major version

A major version (17 → 18) cannot be switched in place: changing the image of an existing
database (`PATCH /databases/{uuid}` accepts `image` **[verify]**) gives the new server an old
data directory, which it refuses to start. **Never change the image to a new major.** A minor
version (17.2 → 17.6) comes with the image tag Coolify pulls and needs nothing from this file.

The one way: a new database next to the old one, the dump of the old one restored into it, the
app's `DATABASE_URL` switched over, the old one kept stopped for a way back. The app is down from
step 3 to step 5 (minutes; longer for a big database). Everything below uses the state keys
`PG_UPGRADE_OLD`, `PG_UPGRADE_NEW` and `PG_UPGRADE_DUMP`, so each step runs on its own.

Known risk on 18: Coolify mounts the data volume at `/var/lib/postgresql/data`, which the 18
image was seen refusing (`references/coolify-api.md`, Known quirks). If the new database does not
start (step 2), stop there: this needs a human, and nothing has changed for the app.

### 1. Plan (read only)

```
. ./lib.sh; pg_major_upgrade_plan "$(state_get DB_UUID)" 18
```

It prints the old database (uuid, name, image, user, database, major), the new one it plans
(`<name>-pg18`, `postgres:18-alpine`, same user and database name, a new password, the same
project and server, environment `production`), the app, and the steps. It refuses a target that
is not above the current major. Read it with the user, together with the downtime, and get an
explicit yes for the whole section. Then a dump while nothing has changed yet:

```
. ./lib.sh; db_dump "$(state_get DB_UUID)"
```

### 2. Create the new database (the user's yes from step 1)

```
. ./lib.sh; O=$(state_get DB_UUID); T=18; I=$(capi GET "/databases/$O") &&
B=$(jq -n --arg p "$(state_get PROJECT_UUID)" --arg s "$(coolify_server)" --arg t "$T" \
  --arg n "$(jq -r '.name' <<<"$I")-pg$T" --arg u "$(jq -r '.postgres_user // "postgres"' <<<"$I")" \
  --arg d "$(jq -r '.postgres_db // .postgres_user // "postgres"' <<<"$I")" --arg pw "$(openssl rand -hex 24)" \
  '{project_uuid:$p, server_uuid:$s, environment_name:"production", name:$n, image:"postgres:\($t)-alpine",
    postgres_user:$u, postgres_password:$pw, postgres_db:$d, is_public:false, instant_deploy:true}') &&
N=$(capi POST /databases/postgresql "$B" | jq -r '.uuid // empty') && [ -n "$N" ] &&
state_set PG_UPGRADE_OLD "$O" && state_set PG_UPGRADE_NEW "$N" && echo "new database: $N (old: $O)"
```

`image` is required in practice **[verify]**. A server with more than one Docker destination
also needs `destination_uuid` **[verify]**; on a 422, show the user Coolify's message and stop.
Wait until it runs, then prove its version:

```
. ./lib.sh; N=$(state_get PG_UPGRADE_NEW); for _ in $(seq 1 12); do s=$(capi GET "/databases/$N" | jq -r .status); echo "$s"; case "$s" in running:healthy) break;; esac; sleep 10; done
echo "major from the image: $(db_major "$N")"; rssh "docker exec \$(docker ps -q -f name=$N) postgres --version"
```

Expect `running:healthy`, `18` and `postgres (PostgreSQL) 18.x`. Not running after two minutes: read
`rssh "docker logs --tail 30 \$(docker ps -aq -f name=<NEW_UUID>)"`. The line `there appears to be
PostgreSQL data in` is the 18 volume quirk; any other error, too: stop, tell the user, this needs
a human. The new database is empty and unused; remove it in the UI with the user's yes.

### 3. Stop the app (downtime starts)

```
. ./lib.sh; A=$(state_get APP_UUID)
capi POST "/applications/$A/stop" >/dev/null && sleep 5 && echo "app: $(capi GET "/applications/$A" | jq -r .status)"
```

Expect `exited:...`. From here nothing writes to the old database.

### 4. Final dump of the old database, restore into the new one

```
. ./lib.sh; O=$(state_get PG_UPGRADE_OLD); F=$(db_dump "$O") && state_set PG_UPGRADE_DUMP "${F%% *}" && echo "dump: $F"
```

```
. ./lib.sh; O=$(state_get PG_UPGRADE_OLD); N=$(state_get PG_UPGRADE_NEW)
RESTORE_FROM_DB="$O" db_restore "$N" "$(state_get PG_UPGRADE_DUMP)"
```

The target is the first argument, the **new** database. `RESTORE_FROM_DB` names the database the
dump comes from: `db_restore` refuses a dump from another database without it, and refuses
`RESTORE_FROM_DB` equal to the target, so the old database is never overwritten here. The
restore is all or nothing. On any error: stop, tell the user, this needs a human. The way back
is simple at this point: start the app again (`capi POST "/applications/<APP_UUID>/start"`); its
`DATABASE_URL` still points at the old database, which has not changed.

Compare the row counts of every table in both:

```
. ./lib.sh; O=$(state_get PG_UPGRADE_OLD); N=$(state_get PG_UPGRADE_NEW)
U=$(capi GET "/databases/$O" | jq -r '.postgres_user // "postgres"'); DB=$(capi GET "/databases/$O" | jq -r '.postgres_db // .postgres_user // "postgres"')
Q="select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1;"
W=$(mktemp -d); for d in "$O" "$N"; do rssh "docker exec -i \$(docker ps -q -f name=$d) psql -U $U -d $DB -tA" <<<"$Q" > "$W/$d"; done
diff "$W/$O" "$W/$N" && echo "same tables, same row counts ($(wc -l < "$W/$N") tables)"; rm -rf "$W"
```

Any difference: stop, this needs a human (way back as above).

### 5. Switch the app to the new database

Stop the old database, so nothing can reach it by mistake, then replace `DATABASE_URL` (a `POST`
on an existing key makes a duplicate: read, delete, post, `references/coolify-api.md`):

```
. ./lib.sh; A=$(state_get APP_UUID); O=$(state_get PG_UPGRADE_OLD); N=$(state_get PG_UPGRADE_NEW)
capi POST "/databases/$O/stop" >/dev/null && echo "old database stopped" &&
URL=$(capi GET "/databases/$N" | jq -r '.internal_db_url // empty') && [ -n "$URL" ] &&
for e in $(capi GET "/applications/$A/envs" | jq -r '.[] | select(.key == "DATABASE_URL") | .uuid'); do capi DELETE "/applications/$A/envs/$e" >/dev/null; done &&
capi POST "/applications/$A/envs" "$(jq -n --arg v "$URL" '{key:"DATABASE_URL", value:$v, is_preview:false}')" >/dev/null &&
echo "DATABASE_URL now points at $N"
```

Do not print `$URL`; it contains the password. If the block stops after the delete and before the
new variable is saved, the app has no `DATABASE_URL`: run the block again (it is safe to repeat),
or go back with step 8. Then deploy, so the container gets the new
variable. `DEPLOY_SKIP_DUMP=1` is needed: `DB_UUID` is still the old, stopped database, and a dump
of it would fail and stop the deploy (the dump from step 4 is the one that matters):

```
. ./lib.sh; DEPLOY_SKIP_DUMP=1 deploy_and_wait "$(state_get APP_UUID)"
```

### 6. Check

```
. ./lib.sh; A=$(state_get APP_UUID); echo "app: $(capi GET "/applications/$A" | jq -r .status)"
curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"; echo
```

Expect `running:healthy` and `"db":"ok"`. With the old database stopped, `"db":"ok"` proves the
app talks to the new one. Then the user clicks through the app's main flow, including one write
(a signup on the starter).

### 7. Record it, move the backups

Only now does the state point at the new database:

```
. ./lib.sh; N=$(state_get PG_UPGRADE_NEW); state_set DB_UUID "$N" && echo "DB_UUID=$N"
```

The scheduled backup belongs to the old database. Give the new one its own schedule with the
S3 copy (phase 06 step 1), run it once, and turn the old one's off so a stopped database does not
send backup-failure alerts every night (`PATCH` of `enabled` on a schedule **[verify]**):

```
. ./lib.sh; N=$(state_get PG_UPGRADE_NEW); O=$(state_get PG_UPGRADE_OLD)
db_backup_attach_s3 "$N" "$(state_get S3_STORAGE_UUID)" && db_backup_now "$N" "$(state_get BACKUP_UUID)"
for b in $(capi GET "/databases/$O/backups" | jq -r '.[]?.uuid'); do capi PATCH "/databases/$O/backups/$b" '{"enabled":false}' >/dev/null && echo "old schedule $b off"; done
./status.sh
```

Expect `S3: uploaded` (or `unreported`, `RESTORE.md` step 1), and in `status.sh`
`OK postgres <name>-pg18 18 (postgres:18-alpine)` with the new backup and off-site lines.

### 8. Way back, and removing the old database later

While the old database exists, going back is: stop the app, start the old database
(`capi POST /databases/<OLD>/start` **[verify]**), point `DATABASE_URL` at its `internal_db_url`
with the step 5 block (old and new swapped), `DEPLOY_SKIP_DUMP=1 deploy_and_wait`, and
`state_set DB_UUID <OLD>`. Everything written to the new database since step 5 is lost that way;
if that matters, it needs a human.

Keep the old database stopped for at least a week. Delete it with `capi DELETE "/databases/<OLD>"` **[verify]** only on the user's explicit yes,
then `state_set PG_UPGRADE_OLD ''`. The dumps in `/root/db-dumps/<OLD>/` stay until the user
removes them.

## Drill (not built yet)

How the test harness (roadmap R01, R14) will prove this file on a throwaway server. Not run yet;
the steps are the plan.

```text
1. Install Coolify one minor version behind the newest; status.sh -> WARN version.
2. Section A with the newest as the target -> status.sh OK version (latest), app healthy.
3. Insert a marker row into the starter's waitlist.
4. Section C 17 -> 18: plan, new database healthy (or the 18 volume quirk, recorded), restore,
   row counts equal, switch, deploy -> health "db":"ok" with the old database stopped.
5. The marker row is in the new database; status.sh -> OK postgres <name>-pg18 18.
```

The drill passes when Coolify is on the newest release and the marker row survived the move to
Postgres 18. That is the R14 done criterion.
