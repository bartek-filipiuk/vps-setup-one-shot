# PREPARE-APP: get an existing app deployed on the user's Coolify server

You are an AI coding agent in the repo of an existing app. The user already ran SETUP.md from
the `vps-setup-one-shot` repo, so they have a Coolify server, an API token in
`~/.config/coolify/config`, and the server details in `~/.config/vps-setup/state`.

`SETUP_DIR` below is the directory that contains this file. Every command sources the helpers:
`. "$SETUP_DIR/lib.sh"; VPS_STATE=.coolify.env` (per-app state lives in the app's gitignored
`.coolify.env`; `rssh` and `capi` still use the global server config).

All rules from `$SETUP_DIR/SETUP.md` apply: secrets never through the chat, server commands only
via `rssh`, API only via `capi`, never retry deploys to fix HTTPS, prove every step, ask before
anything destructive. Additionally: **change nothing in the repo until the user has approved the
plan from step 2.**

## 0. Preconditions

```
. "$SETUP_DIR/lib.sh"; capi GET /version && git remote get-url origin && git status --short | head
```

- API fails: the setup is incomplete. Tell the user to run `$SETUP_DIR/verify.sh`.
- Remote is not GitHub: not supported yet. Say so and stop.
- Uncommitted changes: ask the user to commit or stash first, so our changes are a clean diff.

## 1. Scope check

Supported stacks, from the fixtures in `$SETUP_DIR/fixtures/` (`fixtures/README.md`):

| Stack | Evidence | What to do |
| --- | --- | --- |
| Node.js (Next.js or a plain Node server) with a `package.json` | deployed on a server (phase 05, the starter) | continue |
| Static site, Python with FastAPI, Go | a fixture in `fixtures/static`, `fixtures/python-fastapi`, `fixtures/go`, built and health-checked in CI; **not deployed on a server by this guide yet** | continue, with the fixture as the Dockerfile model |
| Docker Compose stack | a fixture in `fixtures/compose`, built and health-checked in CI; the Coolify compose path is not written yet | tell the user it is not supported yet and stop |
| Django, PHP, Ruby, anything else | no fixture | tell the user it is not supported yet and stop |

For a fixture-backed stack that is not Node.js, write in `DEPLOY.md` that this stack has not been
deployed through this guide before, so the first deploy is the proof. Do not guess a Dockerfile
for a stack without a fixture. Monorepos (workspaces, Turborepo): warn that it needs care, and
continue only if the user wants to.

## 2. Inventory (read only), then a plan the user approves

Find and write down, each with the file it came from:

- Package manager (lockfile: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`) and
  Node version (`engines`, `.nvmrc`, `.node-version`; default 22).
- Framework, build command, start command, port. Next.js: is `output: "standalone"` set?
- Environment variables: grep `process.env.` and `import.meta.env`, plus `.env.example` / `.env*`.
  Mark which are secrets, which are build-time (`NEXT_PUBLIC_*` are inlined at build), which
  can be generated (session or auth secrets).
- Database: driver or ORM (`pg`, `postgres`, `prisma`, `drizzle-orm`, `mysql2`, `mongodb`,
  `redis`), and how migrations run today.
- Local disk writes: uploads, SQLite files, caches. Containers lose these on every deploy.
- Background work: cron jobs, queues, workers, websockets.
- Existing `Dockerfile` / `.dockerignore` / health route.

Then where it goes: one Coolify project per client or product, one environment per stage. Show
the user what exists (read only):

```
. "$SETUP_DIR/lib.sh"; projects_inventory | column -t -s "$(printf '\t')"
```

The default is a new project named after the repo, in `production`. If the app belongs to a
client or product that already has a project, the user picks that project instead, and a stage
(`production`, or for example `staging`). The suggested domain follows from both; a domain the
user names wins. Whatever domain the plan says, no app or service may use it yet:

```
. "$SETUP_DIR/lib.sh"; P="<project>"; N="<repo name>"; S=production
H=$(app_domain_default "$P" "$N" "$S") && echo "default: $H"
domain_in_use "$H"; echo "exit $?"
```

`domain_in_use` exit 1 means free; exit 0 prints who has it (pick another domain); exit 2 means
Coolify could not be read (fix that first).

Write this into `DEPLOY.md` (inventory + plan) and show it to the user. The plan lists every file
you will add or change, the project and stage, the domain, whether a Postgres database is
created, and open questions. Wait for approval.

Things to flag rather than silently fix:
- **SQLite or uploads on local disk**: needs a persistent volume (Coolify UI only: app →
  **Persistent Storage** → add a volume with the mount path) or moving to Postgres / S3. Ask.
- **Database other than Postgres**: Coolify can run MySQL, MariaDB, MongoDB and Redis too, but
  this guide only covers Postgres. Say so; proceed only if the user wants to adapt.
- **Background workers** (cron jobs, a queue): a second Coolify app from the same repo, with
  no domain and the app's database: `$SETUP_DIR/WORKER.md`, after this app is deployed. Move
  the app's own in-process timers there only with the user; until then they keep running in
  the web app.
- **Sign-in by email link or transactional mail** to build: `$SETUP_DIR/starter-auth/` is the
  model (hashed single-use links, sessions and limits in Postgres, SMTP on stdin), and a new app
  can start from it with `$SETUP_DIR/AUTH.md` (not run on a server yet). An app that already
  sends mail: its SMTP password is a secret the user owns (step 5).

## 3. Make it deployable

Use `$SETUP_DIR/starter/Dockerfile` as the model. Lessons already paid for:

- Multi-stage build, run as the non-root `node` user, `ENV HOSTNAME=:: PORT=3000`. Binding `::`
  (not `0.0.0.0`) matters: Coolify's health check calls `localhost`, which resolves to IPv6 in
  Alpine images, and the deploy fails if nothing listens there.
- Next.js: set `output: "standalone"`; copy `.next/standalone`, `.next/static` and `public`.
  Plain Node: `npm ci --omit=dev` (or the pnpm/yarn equivalent) in the final stage, start command
  from `package.json`. The server must read `PORT` and listen on `::`.
- pnpm/yarn: `corepack enable` in the build stages and the matching frozen-lockfile install.
- `NEXT_PUBLIC_*` variables: declare `ARG NEXT_PUBLIC_X` and `ENV NEXT_PUBLIC_X=$NEXT_PUBLIC_X`
  in the build stage, otherwise they are empty in the browser bundle.
- `.dockerignore`: `node_modules`, `.next`, `.git`, `.env*` (keep `.env.example`), `.coolify*.env`
  (also covers the staging state of `STAGING.md`).
- Health route (e.g. `/api/health`): 200 when the app and its database work, 503 otherwise,
  no error details in the response.
- Migrations must run automatically before the new version serves traffic and must fail the
  start loudly. Use the app's own tool. Drizzle: call `migrate()` from
  `drizzle-orm/node-postgres/migrator` at server start (see `starter/lib/db.ts` and
  `instrumentation.ts` for the retry-then-exit pattern) and copy the migrations folder into the
  image. Prisma: in the final stage install the `prisma` CLI at the exact version from
  `package.json`, copy `prisma/`, and start with `prisma migrate deploy && node server.js`.
- `.env.example` listing every variable (names and comments, no real values).

Other fixture-backed stacks follow the same rules with their fixture as the model:

- Static site: `fixtures/static` (nginx as a non-root user on 8080, `listen 8080` and
  `listen [::]:8080`, the built site copied into the image). A site with a build step (Vite,
  Astro, Hugo) adds a build stage before it and copies only the output.
- Python with FastAPI: `fixtures/python-fastapi` (`python:3.12-slim`, a system user, a fully
  pinned `requirements.txt` from `pip-compile`). `uvicorn --host ::` listens on IPv6 only, so the
  proxy's IPv4 connection is refused: start through one socket with `IPV6_V6ONLY` off, as
  `app.py` does in `dual_stack_socket`. Schema setup at start with retry-then-exit, like
  `migrate_or_exit`; with Alembic, `alembic upgrade head` before the server starts.
- Go: `fixtures/go` (a static binary in `distroless/static-debian12:nonroot`; `":"+PORT` listens
  on IPv4 and IPv6). Distroless has no shell, so the `HEALTHCHECK` runs the binary itself
  (`-healthcheck`), in exec form.

Health contract for every stack: `GET /api/health` answers `200` `{"status":"ok","db":"ok"}`
(`"db":"none"` for an app without a database) or `503` `{"status":"error","db":"error"}`, no
error details. The `"db":"ok"` checks in `verify.sh` and phase 05 are for the starter only.

### Migrations: expand, then contract

A deploy can be rolled back to the previous image in a minute (`ROLLBACK.md`); a migration
that dropped a column cannot. So every schema change ships in two deploys, and the old code
must keep working with the new schema in between:

1. **Expand** (deploy 1): add the new column, table or index, nullable or with a default; write
   to both old and new places if the data moves; backfill in batches, not in the migration
   transaction. The previous version still runs against this schema, so a rollback is safe.
2. **Contract** (deploy 2, after deploy 1 has been live and quiet): remove the old column,
   add `NOT NULL`, drop the fallback code. Only now a rollback would need the dump.

Rename = add the new column, copy, switch reads, drop the old one later. Never rename or drop
in the same deploy that introduces the replacement. Large tables: create indexes
`CONCURRENTLY` outside a transaction (Drizzle: a custom SQL migration; Prisma: `--create-only`
and edit). Say which of the two steps a migration is in `DEPLOY.md`, and deploy both with
`deploy_and_wait` so a dump exists before each.

## 4. Prove it locally

```
docker build -t prepare-app-test .
```

With a database: start a throwaway Postgres 17 on a dedicated network, run the image with
`DATABASE_URL` pointing at it and the other variables from `.env.example` filled with dummy
values, and check the health route returns 200. Then exercise one real flow (sign up, create
something). Clean up **only what you created, by name**: the two containers, the network, the
test image, and the Postgres container's anonymous volume (`docker rm -v`). Never run
`docker system prune`, `docker volume prune` or similar on the user's machine.

`$SETUP_DIR/test/fixtures.sh` is the reference for this proof (the health answer on
`127.0.0.1` and on `[::1]` inside the container, the image's `HEALTHCHECK`, a non-root user,
`503` with the database stopped); read it for the commands, it runs only the fixtures.

Show the user the build result and the health response. Ask before committing; commit on the
current branch only with their go-ahead, then push to GitHub with their go-ahead.

## 5. Provision on Coolify

Follow `$SETUP_DIR/phases/05-starter.md` steps 2 to 6 with these differences:

- Use `VPS_STATE=.coolify.env` so the UUIDs land in this repo's `.coolify.env` (check it is
  gitignored first). Set `GH_REPO` from `gh repo view --json nameWithOwner -q .nameWithOwner`,
  `APP_NAME` from the repo name, `APP_DOMAIN` from the approved plan, `APP_DIR` to the repo path.
- Step 3, the project: the approved project and stage instead of the app's name. Both are found
  or created, and recorded in `.coolify.env` (`PROJECT_UUID`, `PROJECT_NAME`, `ENV_NAME`); the
  database and application bodies of steps 3 and 4 then take them from `project_ctx`:

  ```
  . "$SETUP_DIR/lib.sh"; VPS_STATE=.coolify.env
  project_ensure "<project from the plan>" "<one line: client or product>" &&
  env_ensure "$(state_get PROJECT_UUID)" "<stage from the plan>" && project_ctx
  ```

  If `project_ensure` says several projects have that name, ask the user which one is meant and
  to rename the other in the Coolify UI (**Projects**); never pick one yourself.
- Before the domain is set (step 4), `domain_in_use "$(state_get APP_DOMAIN)"` must still exit 1.
- DNS: the user adds an A record for the new hostname pointing to the server IP (no AAAA, DNS
  only on Cloudflare). With `DNS_PROVIDER=cloudflare` in `~/.config/vps-setup/state` you create
  it: `dns_set_a "$(state_get APP_DOMAIN)" "$(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP)"`
  (read its exit codes as in phase 01, step 4). Before the first deploy, this must print the server IP:
  `dig +short A "$(state_get APP_DOMAIN)" @1.1.1.1` (compare with `VPS_IP` in
  `~/.config/vps-setup/state`).
- Naming: in `.coolify.env`, `COOLIFY_DOMAIN` means this app's URL (the classic format other
  tools read). The Coolify panel URL is `COOLIFY_URL` in `~/.config/coolify/config`.
- Postgres only if the plan says so. Port: whatever the app listens on.
- The build pack stays `dockerfile` for every supported stack (the application body of phase 05
  step 4, like `app_create` in `lib.sh`). A Docker Compose stack is not supported here yet
  (step 1).
- Monorepo or app in a subfolder: add `base_directory:"/<folder>"` to the application body (the
  Dockerfile is then read from that folder). The landing of this very guide is deployed that way
  from `/starter`.
- Environment variables, one POST per variable (`{key, value, is_preview:false}`):
  - Generated secrets: create them in the same command with `openssl rand -hex 32`, never printed.
  - Secrets the user owns (API keys, SMTP passwords): the user writes them into a local file
    `.env.production` (check it is gitignored first) in their own editor, `KEY=value` per line,
    no quotes around values.
    Never `cat` it. Upload with:

    ```
    . "$SETUP_DIR/lib.sh"; VPS_STATE=.coolify.env; A=$(state_get APP_UUID)
    grep -Ev '^[[:space:]]*(#|$)' .env.production | while IFS='=' read -r k v; do
      capi POST "/applications/$A/envs" "$(printf '%s' "$v" | jq -Rs --arg k "$k" '{key:$k, value:., is_preview:false}')" >/dev/null && echo "set $k"
    done
    ```

    Then the user may delete the file.
  - Build-time variables: POST rejects `is_build_time`. After the POST, mark them as build
    variables in Coolify: app → **Environment Variables** → the variable → enable the build-time
    option → Save. Ask the user to do it and confirm.
  - A key that already exists: POST creates a duplicate. GET the list, DELETE the old one by its
    UUID, then POST.
- Health check path: the route from step 3.

Write the classic keys too, so `coolify-deploy`-style tools work in this repo:
`state_set COOLIFY_PROJECT_UUID ...`, `COOLIFY_APP_UUID`, `COOLIFY_DOMAIN=https://<APP_DOMAIN>`.
`PROJECT_NAME` and `ENV_NAME` are already there from `project_ensure` and `env_ensure`. An
older `.coolify.env` with only the classic keys keeps working: `project_ctx` reads
`COOLIFY_PROJECT_UUID` and `production`.

## 6. Deploy and verify

`deploy_and_wait "$(state_get APP_UUID)"` (with `VPS_STATE=.coolify.env`, so it finds `DB_UUID`
and dumps this app's database first; an app without a database prints `database dump: none`),
then wait for HTTPS and a healthy health route as in phase 05 step 5. The user clicks through
the app's main flow on the real domain.

## 7. Finish DEPLOY.md

Update `DEPLOY.md` with what is now true: URL, how deploys happen (push to `main` or manual),
variable names (never values), where data lives, backups (same choice as in SETUP phase 06, for
this database), rollback (`$SETUP_DIR/ROLLBACK.md`: `deploy_and_wait` prints the rollback point
and dumps the database to `/root/db-dumps/<DB_UUID>/` on the server before every deploy; a push
to `main` deploys without the dump), and anything that was flagged and left open. Show the user
the summary.

Then regenerate the server's list of projects, so the new app shows up in it:

```
. "$SETUP_DIR/lib.sh"; projects_md
```

A staging copy of this app later (branch `staging`, its own database, `staging.<domain>`,
promotion by merge): `$SETUP_DIR/STAGING.md`.
