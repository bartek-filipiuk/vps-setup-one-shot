# Coolify v4 API: what this guide uses

Base: `<COOLIFY_URL>/api/v1`, header `Authorization: Bearer <token>`. Use `capi` from `lib.sh`.
Checked against Coolify 4.3.23 on 2026-10-09 unless marked **[verify]**.

## Endpoints

| Call | Use | Notes |
|------|-----|-------|
| `GET /version` | sanity check, record version | plain string |
| `GET /servers` | find `COOLIFY_SERVER_UUID` | the Coolify host is usually named `localhost` |
| `POST /projects {name}` | one project per app | returns `uuid`; environment `production` exists by default |
| `POST /security/keys {name, private_key}` | store a deploy key | returns `uuid` → `private_key_uuid` |
| `POST /databases/postgresql` | Postgres | body: `project_uuid, server_uuid, environment_name, name, image, postgres_user, postgres_password, postgres_db, is_public:false, instant_deploy:true`; returns `uuid`, `internal_db_url` |
| `GET /databases/{uuid}` | status, `internal_db_url` | status `running:healthy` when ready; the uuid is the hostname inside the `coolify` network and part of the container name |
| `POST /applications/private-deploy-key` | app from a private Git repo | body: `project_uuid, server_uuid, environment_name, name, git_repository` (SSH form `git@github.com:owner/repo.git`), `git_branch, build_pack:"dockerfile", ports_exposes, private_key_uuid, instant_deploy:false`, optional `base_directory:"/subfolder"` |
| `PATCH /applications/{uuid}` | domain, health check, webhook secret | `domains:"https://host"`, `base_directory`, `health_check_enabled`, `health_check_path`, `health_check_port`, `manual_webhook_secret_github` |
| `GET/POST/DELETE /applications/{uuid}/envs[/{env_uuid}]` | environment variables | POST body `{key, value, is_preview:false}` |
| `POST /deploy?uuid={app}` | trigger a deploy | returns `deployments[0].deployment_uuid`; `GET` answers 405 since 4.3 |
| `GET /deployments/{uuid}` | poll | `status`: `queued`, `in_progress`, `finished`, `failed`, `cancelled-by-user`; `logs` is a JSON string of `[{output, hidden}]` |
| `GET /applications/{uuid}/logs?lines=100` | runtime logs (`app_logs`, `DOCTOR.md`) | `{"logs": "<one string, lines joined by newlines>"}`, verified live 2026-10-14 on 4.3.23 (GET). From the 4.3.23 source: `lines` defaults to 100, at most 10000; 400 `{"message":"Application is not running."}` when no container runs **[verify]** |

Read-only calls used by `status.sh`, verified 2026-10-13 on 4.3.23 (GET, response shapes as below).

| Call | Use | Notes |
|------|-----|-------|
| `GET /applications` | every app | array; items have `uuid`, `name`, `fqdn` (comma-separated URLs), `status` like `running:healthy`, `running:unhealthy`, `exited:unhealthy` |
| `GET /deployments/applications/{uuid}` | last deploy of an app | object `{count, deployments:[...]}`, `deployments[0]` is the newest; fields include `status`, `created_at`, `finished_at`, `commit`, `application_name`; a successful deploy is `finished`; dates like `2026-10-13T12:08:21.000000Z`; no deploys = `count` 0, empty list |
| `GET /databases` | every database | array with `uuid`, `name` |
| `GET /databases/{uuid}/backups` | scheduled backups of a database | array of `{uuid, enabled, frequency, last_execution_at (may be null), executions:[...]}` |
| `GET /databases/{uuid}/backups/{backup_uuid}/executions` | backup runs | object `{executions:[...]}`; fields `uuid`, `status` (`success`), `created_at` like `2026-10-13T12:08:10+00:00` (offset, not `Z`), `finished_at` (null), `filename`, `message`, `size` |

Safe deploys (`deploy_and_wait`, `rollback_and_wait`, `ROLLBACK.md`). GET calls verified
2026-10-14 on 4.3.23; the POST calls are from the 4.3.23 `openapi.yaml` and not yet exercised **[verify]**.

| Call | Use | Notes |
|------|-----|-------|
| `GET /deployments/applications/{uuid}` | rollback point | the newest deployment with `status: finished` is what runs now; its `commit` is the full sha. `GET /applications/{uuid}` has `git_commit_sha`, but that is the configured ref (`HEAD`), not the running commit. Deployments also carry `rollback` (bool) and `commit_message` |
| `GET /applications/{uuid}/rollback-images` | which images a rollback can use | `{current, images:[{tag, created_at, is_current}]}`; `tag` is the commit sha; `created_at` is server-local like `2026-10-13 17:52:17 +0200 CEST`; on 4.3.23 `current` was `null` and every `is_current` `false` even for the running commit, so do not rely on them; images pruned by Coolify's cleanup are missing |
| `POST /applications/{uuid}/rollback {commit}` | redeploy an existing image, no rebuild | returns `{message, deployment_uuid}`, then poll `GET /deployments/{uuid}` **[verify]** |
| `POST /applications/{uuid}/stop`, `POST /applications/{uuid}/start` | stop writes during a restore | return `{message}` **[verify]** |
| `GET /databases/{uuid}` | dump parameters | `database_type` (`standalone-postgresql`, `standalone-redis`, ...), `image`, `postgres_user`, `postgres_db`; also `postgres_password`, never print the whole object |
| `POST /databases/{uuid}/backups` | create a **scheduled** backup | see the off-site table below; `db_dump` still runs `pg_dump` over `rssh` before a deploy, because a deploy needs a finished dump at a known path on the server, and keeps the files in `/root/db-dumps/<DB_UUID>/` |

Off-site backups (`s3_storage_create`, `db_backup_attach_s3`, `db_backup_now`, `db_backup_list`,
`db_fetch_from_s3`, `status.sh` off-site line, `RESTORE.md`). `GET /s3-storages` was checked on a
live 4.3.23 on 2026-10-14; everything else here is from the 4.3.23 source and `openapi.yaml` and
not yet exercised **[verify]**.

| Call | Use | Notes |
|------|-----|-------|
| `GET /s3-storages` | find a storage by name | array of `{uuid, name, description, endpoint, bucket, region, is_usable, ...}`; `key` and `secret` are not returned (live GET) |
| `GET /s3-storages/{uuid}` | endpoint and bucket for a download | same fields as the list **[verify]** |
| `POST /s3-storages {name, description, endpoint, bucket, region, key, secret, is_usable}` | create the storage | returns `{uuid}`; the body goes through `capi`'s stdin, the key pair never on a command line **[verify]** |
| `PATCH /s3-storages/{uuid}`, `DELETE /s3-storages/{uuid}` | update (same fields) or delete | **[verify]** |
| `POST /s3-storages/{uuid}/validate` | Coolify lists the bucket with the stored key pair | `{valid: bool, message}`; `valid:false` with the S3 error as `message` **[verify]** |
| `POST /databases/{uuid}/backups` | create a scheduled backup | `frequency` required (cron or `daily`, ...), `enabled`, `save_s3`, `s3_storage_uuid`, `dump_all`, `databases_to_backup`, `database_backup_retention_amount_locally` / `_s3` (also `_days_` and `_max_storage_` variants), `timeout`, `backup_now`; returns `{uuid, message}` **[verify]** |
| `PATCH /databases/{uuid}/backups/{backup_uuid}` | attach S3 to a schedule; run it now | same fields; `{"backup_now":true}` dispatches a backup job at once: this is the on-demand run (no separate endpoint). It does not return the execution; poll the executions for a new `uuid` **[verify]** |
| `GET /databases/{uuid}/backups` | schedules | also `save_s3`, `s3_storage_id` (numeric id, not the uuid) and the retention fields **[verify]** |
| `GET /databases/{uuid}/backups/{backup_uuid}/executions` | did the copy reach S3 | `status` stays `success` when only the upload failed; then `message` contains `Warning: S3 upload failed: ...`. The model has `s3_uploaded` and `s3_storage_deleted`, but the live GET did not show `s3_uploaded`, so the scripts use it when present and the message otherwise **[verify]** |

Where the files go: Coolify uploads with `mc` to `<bucket>/<execution filename without the
leading slash>`. A Postgres backup without `dump_all` is `pg_dump --format=custom`, so
`db_restore` (`pg_restore`) takes it as it is; with `dump_all` it is a gzipped `pg_dumpall` and
needs `psql` instead **[verify]**. `db_fetch_from_s3` downloads with the `mc` inside the newest
`ghcr.io/coollabsio/coolify-helper` image already on the server (the image Coolify itself uploads
with; checked 2026-10-14 on a 4.3.23 server: `coolify-helper:1.0.17` has `/usr/bin/mc`; `minio/mc`
is gone from Docker Hub), override with `MC_IMAGE`, and `MC_HOST_s3=https://KEY:SECRET@host`, key
and secret percent-encoded **[verify]**.

Rebuild (R15: `s3_backup_list`, `rebuild_inventory`, `REBUILD.md`). No Coolify API call: a new
Coolify knows none of the old server's backup runs, so the list comes from the bucket. Nothing
here has been run against a real bucket yet **[verify]**.

- Layout in the bucket, from the 4.3.23 source (`DatabaseBackupJob`): `<bucket>/data/coolify/backups/databases/<team name slug>-<team id>/<database name slug>-<database uuid>/<file>`,
  for Postgres `pg-dump-<db>-<unix time>.dmp`, with `dump_all` `pg-dump-all-<unix time>.gz`
  (checked 2026-10-16 on a 4.3.23 server against the execution filenames, e.g.
  `root-team-0/<name>-db-<uuid>/`; the bucket itself not listed yet). `s3_backup_list` takes the
  uuid as the part after the last `-` of the directory name (Coolify uuids have no dashes) **[verify]**.
- The call, inside the coolify-helper image on the server, credentials as for `db_fetch_from_s3`:
  `mc --json ls --recursive s3/<bucket>/data/coolify/backups/databases/`. One JSON object per line,
  `{status:"success", type:"file"|"folder", lastModified (RFC 3339, may carry an offset or
  fractions), size, key, ...}`; the key is relative to the listed prefix, a full key is accepted
  too. Errors come on stdout as `{status:"error", error:{message, cause:{message}}}` with a non-zero
  exit; an empty prefix may answer either empty or with an error **[verify]**.
- Coolify's instance backup (**Settings** → **Backup**, Coolify's own database to S3) is not used.
  Restoring it on a new server needs the old `APP_KEY` from `/data/coolify/source/.env` (Coolify
  encrypts environment values, keys and passwords with it) and the old `/data/coolify/ssh/keys/`
  (Coolify docs, "Backup and Restore Your Coolify Instance"). This guide saves neither, so the
  restored secrets could not be read; `REBUILD.md` recreates everything through the phases instead.
- A never deployed application (`instant_deploy:false`) does not report `running*`, so
  `db_restore`'s running-app guard passes before the first deploy **[verify]**.

Notifications (R06a: `notify_setup`, `notify_status`, `status.sh` alerts line, phase 06 step 2).
`GET` verified live on 4.3.23 on 2026-10-14; the `PATCH` behaviour, the validation, the 422 shape,
the URL echo and the missing test endpoint are from the 4.3.23 source only **[verify]**.
Settings belong to the team of the API token.

| Call | Use | Notes |
|------|-----|-------|
| `GET /notifications/{email\|discord\|slack\|telegram\|pushover\|webhook}` | read a channel's settings | flat object of booleans: `<channel>_enabled` and `<event>_<channel>_notifications` for `backup_failure`, `backup_success`, `deployment_failure`, `deployment_success`, `docker_cleanup_failure`, `docker_cleanup_success`, `restart_limit_reached`, `scheduled_task_failure`, `scheduled_task_success`, `server_disk_usage`, `server_patch`, `server_reachable`, `server_unreachable`, `status_change`, `traefik_outdated`; Discord also `discord_ping_enabled`; plus `id`, `team_id`. Secrets (`discord_webhook_url`, ...) are not returned (live GET). Email has no `email_enabled`: `status.sh` counts it on when `smtp_enabled` or `resend_enabled` is true **[verify]** |
| `PATCH /notifications/discord {discord_enabled, discord_webhook_url, discord_ping_enabled, <event>_discord_notifications...}` | turn on Discord with the seven alert events | allow-list per channel; an unknown key is a 422 `{"message":"Validation failed.","errors":{"<field>":["..."]}}`; `discord_webhook_url` must be http(s) and not localhost or a private IP (the host is not checked to be discord.com) **[verify]**. The response may echo the webhook URL to a token with `read:sensitive`, so `notify_setup` never prints it and shows only `message` and `errors` of a 422, URL blanked **[verify]** |
| (none) | test notification | no API call; Coolify UI → **Notifications** → **Discord** → **Send test notification** **[verify]** |

Teams and keys (R12: `team_members`, `ssh_keys_list`, `HANDOVER.md`). The two `GET` calls were
verified live on 4.3.23 on 2026-10-14/15; everything about roles, invites and tokens is from the
4.3.23 source, because the API has no call for them.

| Call | Use | Notes |
|------|-----|-------|
| `GET /team`, `GET /teams`, `GET /teams/{id}` | the token's team, every team of the user | ability `read` |
| `GET /team/members`, `GET /teams/{id}/members` | who is in the team (`team_members`) | array of users: `id`, `name`, `email`, `email_verified_at`, `two_factor_confirmed_at`, dates; **no role** (live GET). The role is only in the UI: **Team** → **Members** |
| `GET /security/keys` | private keys Coolify holds (server key, deploy keys) (`ssh_keys_list`) | array of `{uuid, name, fingerprint, public_key, is_git_related, team_id, ...}` (live GET); a token with `root` or `read:sensitive` also gets `private_key` **[verify]**, so print only chosen fields. `POST`, `PATCH`, `DELETE /security/keys[/{uuid}]` exist |
| (none) | invites, roles, API tokens | no API in 4.3.23: there is no `/tokens` and no invite or role call. UI only, see below |

From the 4.3.23 source **[verify]**:

- Roles are `owner`, `admin`, `member`. Managing members and invitations needs `admin` or
  `owner`; deleting the team needs `owner`. In **Team** → **Members** an owner can make someone
  owner; an admin can make someone admin or member (`readonly` in the UI) or remove them. Each of
  these changes also revokes that user's API tokens for the team.
- An invite is an email plus a role, sent by email or as a copied link. An admin cannot invite an
  owner. `/invitations/{uuid}` needs a login with a verified email; invites expire after 3 days.
- API tokens (**Keys & Tokens** → **API Tokens**) have the abilities `root`, `write`, `deploy`,
  `read` and `read:sensitive`, an expiry of 7, 30, 60, 90 or 365 days or none, and belong to the
  team that is current when they are created. There is **no project or server scope**. Sensitive
  fields (passwords, keys, webhook URLs) come back only with `root` or `read:sensitive` **and**
  the user being `admin` or `owner`.

`status_change` is the "app stopped" alert, read in the 4.3.23 source:
`app/Notifications/Application/StatusChanged.php` uses `getEnabledChannels('status_change')` with
the subject "Coolify: {resource} has been stopped", and `Container/ContainerRestarted.php` uses
it too; there is no separate container-stopped notification. So `NOTIFY_EVENTS` includes it, or
the R06a drill (stop the app, a message arrives) gets nothing. Not yet seen on a server **[verify]**.

Services (R10: `service_create`, `service_status`, `service_delete`, the `status.sh` Services
section, `SERVICES.md`). The two `GET` calls were verified live on 4.3.23 on 2026-10-15;
everything else is from the 4.3.23 source and not yet exercised **[verify]**.

| Call | Use | Notes |
|------|-----|-------|
| `GET /services` | every service (`service_status`, `status.sh`) | array of `{uuid, name, description, service_type, status, server_status, applications:[...], databases:[...], environment_id, server_id, ...}` (live GET). `applications[]`: `uuid, name, human_name, fqdn, url, image, status, exposes, ports, is_force_https_enabled, restart_count, restart_limit_reached, last_online_at`; `databases[]`: `uuid, name, image, status, is_public, public_port` |
| `GET /services/{uuid}` | one service | the same object plus `environment` (live GET) |
| `POST /services {type, name, project_uuid, server_uuid, environment_name, instant_deploy, urls}` | create a one-click service with its domain (`service_create`) | `urls: [{name: <compose service name>, url: "https://domain"}]` sets that application's `fqdn`; returns `{uuid, domains:[...]}`; `instant_deploy:true` starts it. A domain in use is a 409 `{message, conflicts:[...]}` unless `force_domain_override:true` (never sent); validation errors are a 422 `{message, errors}`; on either error Coolify deletes the new service again **[verify]** |
| `PATCH /services/{uuid}` | `name, description, instant_deploy, docker_compose_raw, urls, force_domain_override` | not used yet **[verify]** |
| `PATCH /services/{uuid}/applications/{app_uuid} {url}` | change the domain of one application of a service | not used yet **[verify]** |
| `DELETE /services/{uuid}?delete_volumes=true` | remove a service (`service_delete`, only with `--yes`) | `delete_volumes` defaults to true: the data goes with it **[verify]** |
| `POST /services/{uuid}/start`, `/stop`, `/restart` | lifecycle | not used yet **[verify]** |
| `PUT`/`POST /services/{uuid}/storages/{storage_uuid}/backups[/run]` | volume backups of a service | not used yet; `SERVICES.md` step 5 **[verify]** |
| (none) | scheduled backups of a database inside a service | `/databases/{uuid}/backups` covers standalone databases only; UI only **[verify]** |

Upgrades (R14: `db_major`, `pg_major_upgrade_plan`, the `status.sh` updates and postgres lines,
`UPGRADE.md`). From the 4.3.23 source, `routes/api.php` and the Coolify docs; none of it has been
exercised on a server yet **[verify]**.

| Call | Use | Notes |
|------|-----|-------|
| (none) | upgrade Coolify, read or change its update settings | no API: `routes/api.php` has only `/settings/email` under settings. Auto-update is a UI setting (**Settings** → **Updates**). The UI **Upgrade** button and the auto-update scheduler both run `/data/coolify/source/upgrade.sh <version>` on the server; by hand: `curl -fsSL https://cdn.coollabs.io/coolify/upgrade.sh \| bash -s <version>`, which refuses a downgrade. The way back from a bad upgrade is the instance backup (**Settings** → **Backup**), not a downgrade |
| `GET https://cdn.coollabs.io/coolify/versions.json` | the newest version Coolify itself offers | `.coolify.v4.version`; not the Coolify API (no token). `status.sh` compares with the newest GitHub release instead (`/repos/coollabsio/coolify/releases/latest`) |
| `GET /deployments` | deployments running or queued, before an upgrade | array **[verify]** |
| `POST /databases/postgresql` | a new database for a Postgres major upgrade | as in the first table; `image` is required in practice (`postgres:18-alpine`), plus `postgres_user`, `postgres_password`, `postgres_db`, optional `postgres_initdb_args`, `postgres_host_auth_method`, `postgres_conf`; `environment_name` or `environment_uuid`; `destination_uuid` when the server has more than one destination; `instant_deploy` **[verify]** |
| `PATCH /databases/{uuid}` | change a database's settings | accepts `image`, but a new **major** in place is not an upgrade: the new server refuses the old data directory. `UPGRADE.md` never does it **[verify]** |
| `POST /databases/{uuid}/stop`, `POST /databases/{uuid}/start` | keep the old database stopped after the switch, start it for a way back | **[verify]** |
| `GET /databases` | `status.sh` postgres line | the list items carry `image` and `database_type` like `GET /databases/{uuid}` (checked 2026-10-15 on 4.3.23: tags like `postgres:16`, `postgres:17-alpine`); the major is the number at the start of the image tag (`pg_image_major`) |
| `PATCH /databases/{uuid}/backups/{backup_uuid} {enabled:false}` | turn off the old database's schedule after the switch | **[verify]** |
| `DELETE /databases/{uuid}` | remove the old database, only on the user's yes | **[verify]** |

One-click templates on 4.3.23 (source): `umami` (umami + postgresql, `SERVICE_URL_UMAMI_3000`),
`n8n` (also `n8n-with-postgresql`), `uptime-kuma`, `forgejo` (Git over SSH on host port
`22222`). `minio` and `plausible` are in Coolify's ignored templates, so not one-click; MinIO
works only as `docker_compose_raw` and is not supported here yet.

Webhook target for GitHub push events: `<COOLIFY_URL>/webhooks/source/github/events/manual`,
a GitHub webhook with `content_type: json`, event `push`, and the app's
`manual_webhook_secret_github` as the secret. Deliveries return 200 and trigger a deploy.

Checkup (R16: `checkup.sh`, `CHECKUP.md`, `checkup_server_facts`, `firewall_rules`,
`firewall_applied`, `hcloud_json`, `coolify_advisories`, `backup_success_rate`, `server_cost`).
The Coolify calls are the `GET`s of `status.sh` above; the rest is not Coolify's API. None of it
has been run against a real server, Hetzner project or GitHub answer yet **[verify]**.

| Call | Use | Notes |
|------|-----|-------|
| `GET /databases/{uuid}/backups`, `.../executions` | backup success rate, last 30 days | as above. Coolify deletes old execution rows together with old local backups (retention), so the 30 days may hold fewer runs than the schedule made; a short history is not a failure **[verify]** |
| `GET https://api.github.com/repos/coollabsio/coolify/security-advisories?state=published&per_page=100` | Coolify advisories against `GET /version` | GitHub REST, no token: 60 calls an hour per IP, 403 or 429 past it. Array of `{ghsa_id, cve_id, severity, published_at, summary, vulnerabilities:[{package, vulnerable_version_range, patched_versions}]}`; ranges like `< 4.0.0-beta.420` or `>= 4.0.0, <= 4.3.23`, may be null; a pre-release sorts before its release (`JQ_VERSION` in `lib.sh`) **[verify]** |
| `hcloud firewall describe vps-setup-fw -o json` | firewall rules and where it is applied | `{rules:[{direction, protocol, port (string, null for icmp), source_ips:[...]}], applied_to:[{type:"server", server:{id}} or {type:"label_selector", applied_to_resources:[...]}]}` as in the Hetzner Cloud API **[verify]** |
| `hcloud server describe <name> -o json`, `hcloud server list -o json` | server id; monthly list price | `id`, `server_type.prices[]:{location, price_monthly:{net, gross}}` (strings), `datacenter.location.name` (newer API also `location.name`), `backup_window` null when backups are off; backups add 20% of the server price **[verify]** |
| `hcloud primary-ip list -o json`, `hcloud volume list -o json` | counted in the cost line | no price in the answer; their prices, Object Storage and traffic only in the Hetzner Console → **Usage** **[verify]** |

On the server (`checkup_server_facts`, one `rssh` round trip, read-only): `ss -tlnpH` and
`ss -ulnpH`, `sshd -T`, `ssh-keygen -lf /root/.ssh/authorized_keys` (comments dropped),
`ps -o args= -C dockerd`, the `"hosts"` of `/etc/docker/daemon.json`, `docker inspect` of every
container (name, image, privileged, a mount of `/var/run/docker.sock` or `/run/docker.sock`),
`df -Pk /`, `du -sk /data/coolify/backups /root/db-dumps`, `docker system df`. Expected on a clean
4.3.23, from the source and its compose files: `coolify-proxy` (Traefik, socket read-only) and
`coolify-sentinel` mount the socket, and the `coolify-helper` build containers while a deploy
runs (`DOCKER_SOCK_OK`, `DOCKER_SOCK_OK_IMAGES`) **[verify]**; 8000 (dashboard), 6001 and 6002
(realtime, terminal) and 8080 (the proxy's dashboard) listen on all addresses and are closed
from the internet only by the cloud firewall **[verify]**.

## Known quirks

- **Do not use `POST /applications/dockerfile`** for a repo: it builds an inline Dockerfile without
  the repo as build context, so every `COPY` fails.
- **Env POST on an existing key creates a duplicate** (or 409). GET, DELETE the old `env_uuid`, POST.
- **`is_build_time` is rejected on POST.** Mark build variables in the UI afterwards.
- **Postgres 18 fails to start** on Coolify's volume layout (`/var/lib/postgresql/data`); use
  `postgres:17-alpine` **[verify on newer Coolify]**.
- **Custom domains for compose resources and one-click services.** An older Coolify was seen
  reverting a domain set through the API to `*.sslip.io`. On 4.3.23 the source shows
  `POST /services` with `urls` setting the domain (`service_create`, table above); not yet seen
  on a server **[verify]**. Your own apps still go in as applications (phase 05, `PREPARE-APP.md`).
- **Persistent storage has no API.** Add volumes in the UI: app → **Persistent Storage**.
- **Never set a database `is_public:true`** to reach it from your laptop. Use
  `rssh "docker exec <db_uuid> psql ..."` or an SSH tunnel to the container's IP on the
  `coolify` Docker network.
- **The health check runs inside the container against `localhost`.** In Alpine images that is
  IPv6 first; the app must listen on `::`.
- **Realtime (6001) and terminal (6002) behind the instance domain**: once the dashboard works
  through its domain on the Coolify proxy, 8000, 6001 and 6002 can stay closed; realtime and the
  terminal go through 443 (coolify.io/docs/core/infrastructure/servers/firewall).
- **One project cannot be isolated inside a team.** A server belongs to one team, and every
  member sees (and, by role, changes) every project on that team's servers; tokens have no project
  scope either. A client who must see only their project gets their own server in their own team
  (`HANDOVER.md` step 0) **[verify]**.
- **Never put the API token into GitHub** (secrets, webhooks). It controls the whole server.
  Use the per-app webhook secret.
