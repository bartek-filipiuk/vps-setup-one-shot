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
| `GET /applications/{uuid}/logs?lines=100` | runtime logs | |

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
needs `psql` instead **[verify]**. `db_fetch_from_s3` downloads with `minio/mc` (tag pinned in
`lib.sh`, `MC_IMAGE`) and `MC_HOST_s3=https://KEY:SECRET@host`, key and secret percent-encoded
**[verify]**.

Webhook target for GitHub push events: `<COOLIFY_URL>/webhooks/source/github/events/manual`,
a GitHub webhook with `content_type: json`, event `push`, and the app's
`manual_webhook_secret_github` as the secret. Deliveries return 200 and trigger a deploy.

## Known quirks

- **Do not use `POST /applications/dockerfile`** for a repo: it builds an inline Dockerfile without
  the repo as build context, so every `COPY` fails.
- **Env POST on an existing key creates a duplicate** (or 409). GET, DELETE the old `env_uuid`, POST.
- **`is_build_time` is rejected on POST.** Mark build variables in the UI afterwards.
- **Postgres 18 fails to start** on Coolify's volume layout (`/var/lib/postgresql/data`); use
  `postgres:17-alpine` **[verify on newer Coolify]**.
- **Compose resources and one-click services cannot get a custom domain via the API** (it reverts
  to `*.sslip.io`). Anything that needs a domain is an application.
- **Persistent storage has no API.** Add volumes in the UI: app → **Persistent Storage**.
- **Never set a database `is_public:true`** to reach it from your laptop. Use
  `rssh "docker exec <db_uuid> psql ..."` or an SSH tunnel to the container's IP on the
  `coolify` Docker network.
- **The health check runs inside the container against `localhost`.** In Alpine images that is
  IPv6 first; the app must listen on `::`.
- **Realtime (6001) and terminal (6002) behind the instance domain**: once the dashboard works
  through its domain on the Coolify proxy, 8000, 6001 and 6002 can stay closed; realtime and the
  terminal go through 443 (coolify.io/docs/core/infrastructure/servers/firewall).
- **Never put the API token into GitHub** (secrets, webhooks). It controls the whole server.
  Use the per-app webhook secret.
