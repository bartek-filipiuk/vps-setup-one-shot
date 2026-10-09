# Coolify v4 API: what this guide uses

Base: `<COOLIFY_URL>/api/v1`, header `Authorization: Bearer <token>`. Use `capi` from `lib.sh`.
Items marked **[verify]** come from experience with one Coolify version and have not been
re-checked on the version in `README.md` → "Tested with".

## Endpoints

| Call | Use | Notes |
|------|-----|-------|
| `GET /version` | sanity check, record version | plain string |
| `GET /servers` | find `COOLIFY_SERVER_UUID` | the Coolify host is usually named `localhost` |
| `POST /projects {name}` | one project per app | returns `uuid`; environment `production` exists by default |
| `POST /security/keys {name, private_key}` | store a deploy key | returns `uuid` → `private_key_uuid` |
| `POST /databases/postgresql` | Postgres | body: `project_uuid, server_uuid, environment_name, name, image, postgres_user, postgres_password, postgres_db, is_public:false, instant_deploy:true`; returns `uuid`, `internal_db_url` |
| `GET /databases/{uuid}` | status, `internal_db_url` | status `running:healthy` when ready; the container name equals the uuid **[verify]** |
| `POST /applications/private-deploy-key` | app from a private Git repo | body: `project_uuid, server_uuid, environment_name, name, git_repository` (SSH form `git@github.com:owner/repo.git`), `git_branch, build_pack:"dockerfile", ports_exposes, private_key_uuid, instant_deploy:false` |
| `PATCH /applications/{uuid}` | domain, health check, webhook secret | `domains:"https://host"`, `health_check_enabled`, `health_check_path`, `health_check_port`, `manual_webhook_secret_github` **[verify]** |
| `GET/POST/DELETE /applications/{uuid}/envs[/{env_uuid}]` | environment variables | POST body `{key, value, is_preview:false}` |
| `GET /deploy?uuid={app}` | trigger a deploy | returns `deployments[0].deployment_uuid` (older versions: `deployment_uuid`) |
| `GET /deployments/{uuid}` | poll | `status`: `queued`, `in_progress`, `finished`, `failed`, `cancelled-by-user`; `logs` is a JSON string of `[{output, hidden}]` |
| `GET /applications/{uuid}/logs?lines=100` | runtime logs | |

Webhook target for GitHub push events: `<COOLIFY_URL>/webhooks/source/github/events/manual`,
signed with the app's `manual_webhook_secret_github` **[verify]**. The equivalent Gitea endpoint
and secret are proven; the GitHub pair is expected to be symmetric.

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
- **Realtime (6001) and terminal (6002) behind the instance domain**: expected to be proxied
  through the HTTPS domain, so the firewall keeps 6001/6002 closed **[verify]**.
- **Never put the API token into GitHub** (secrets, webhooks). It controls the whole server.
  Use the per-app webhook secret.
