# vps-setup-one-shot: plan

A public repo that turns one prompt into a working self-hosted deploy setup:
Hetzner (or any Ubuntu VPS) + Coolify v4 + a deployed Next.js landing with Postgres.
A second prompt later prepares an existing app and deploys it to the same setup.

Status: plan reviewed by an advisor pass (Fable 5.1). Items marked **[verify]** are
unproven and must be checked in the spike (step 0 of the build order) before they go
into a runbook.

## User experience

```
git clone https://github.com/<owner>/vps-setup-one-shot && cd vps-setup-one-shot
# then, in Claude Code / Codex / Cursor:
Read SETUP.md and guide me through it.
```

Clone, not fetch: works in agents without a network tool, ships `starter/` locally,
and phase files can be re-read after context compaction.

Later, inside any existing app repo:

```
Read ~/vps-setup-one-shot/PREPARE-APP.md and prepare this app for deployment.
```

## Principles (what makes it reliable over a 60-minute session)

1. **Reality is the state.** `verify.sh` checks the real world (SSH works, password auth
   off, Coolify reachable on its domain, API token valid, app health returns `db: ok`)
   and prints which phase is next. The state file holds only what cannot be derived:
   VPS IP, domain, Coolify resource UUIDs, Coolify version.
2. **Small phase files.** `SETUP.md` is a ~40-line dispatcher: run `verify.sh`, open
   `phases/NN-*.md`. Each phase file is under ~150 lines and starts with "Done when".
3. **The agent does everything that has a CLI or API.** The user clicks only: Hetzner
   signup and payment, Hetzner API token, Coolify admin registration, Coolify API token,
   DNS records, backup toggle. Every click = exact UI path + what you should see after.
4. **Secrets never go through chat or the agent's shell input.** The user runs a given
   command in their own terminal (`read -s` into a chmod 600 file), replies "done", the
   agent verifies with `test -s` plus a real API call. Interactive input does not work in
   agent shells.
5. **Remote commands are always explicit:** `ssh root@$VPS_IP '...'`. Never a bare
   `apt upgrade` that would run on the user's laptop.
6. **Config compatible with the existing `coolify-deploy` skill:** `~/.config/coolify/config`
   (`COOLIFY_URL`, `COOLIFY_TOKEN`, `COOLIFY_SERVER_UUID`) and per-project `.coolify.env`.

## Repo layout (MVP)

```
README.md            one-liner, what you get, cost (~5-10 EUR/month), time (~60 min), teardown
SETUP.md             dispatcher prompt
PREPARE-APP.md       second prompt (Node/Next.js only in MVP)
verify.sh            reality check + "next phase" detector, run from the user's machine
phases/
  00-preflight.md    ssh key, git, gh (logged in), jq, hcloud; domain; Hetzner account
  01-server.md       hcloud: SSH key, firewall (22/80/443 only), Ubuntu 24.04, >=4 GB RAM
  02-harden.md       apt upgrade, swap 4 GB, unattended-upgrades, key-only SSH
  03-coolify.md      official install script, admin via SSH tunnel, API token
  04-domain.md       DNS A records, dig gate, Coolify instance domain, HTTPS check
  05-starter.md      repo from starter/, Postgres 17, app, deploy key, env, domain, deploy
  06-handover.md     backups, SERVER.md summary, PREPARE-APP one-liner, teardown
starter/             Next.js landing + waitlist form + /api/health (DB ping)
references/
  coolify-api.md     generalized from the private skills, gotchas included
  troubleshooting.md log signature -> cause -> fix
```

## Phase details and the traps each one guards

**00 preflight.** Check tools, `gh auth status`, SSH key exists (offer `ssh-keygen`).
Warn up front that a new Hetzner account may need identity verification (can take hours);
non-Hetzner users skip to "give me the IP of a fresh Ubuntu 24.04 box with your key".

**01 server.** `hcloud` CLI with a project API token (one click) instead of ~8 UI paths
that change every few months. Firewall opens 22, 80, 443 only. Port 8000 is never public:
the Coolify UI is reached through `ssh -L 8000:localhost:8000` until it has a domain.
That removes the "first visitor becomes admin" race and the problem of a user IP changing
mid-session (mobile, CGNAT). Hetzner Cloud Firewall, not ufw, because Docker bypasses ufw.

**02 harden.** Disable password auth only after a second, fresh SSH login with the key
succeeded. 4 GB swap, because `next build` OOMs on small boxes.

**03 coolify.** Official install script; record `GET /api/v1/version` in the state file and
warn if it is newer than the version this repo was tested on. User registers the admin
through the tunnel, creates the API token, writes it to the config file themselves.

**04 domain.** Records: `coolify.<domain>` and `<domain>` (Cloudflare proxy off).
Gate: `dig +short coolify.<domain>` must equal the VPS IP before the instance domain is set,
otherwise the UI redirects to an unreachable host **[verify]**. Rule for the agent: SSL
problems are fixed by checking DNS, never by redeploying (Let's Encrypt rate limits failed
attempts).

**05 starter.** Zero-click git source on GitHub:
`gh repo create --private` from `starter/`, generate a deploy key, `gh repo deploy-key add`
(read-only), `POST /security/keys`, `POST /applications/private-deploy-key`.
Push-to-deploy: per-app `manual_webhook_secret_github` + `gh api repos/O/R/hooks` pointing
at `/webhooks/source/github/events/manual` **[verify: the GitHub variant; only the gitea
variant is proven in coolify-selfhosted]**. Fallback if it does not exist: agent-triggered
deploy via the API (never put the broad API token into a GitHub secret or webhook).
Postgres image `postgres:17-alpine` (PG18 fails on Coolify's volume layout **[verify on
current Coolify]**). `DATABASE_URL` uses the DB's internal hostname. Env writes:
GET, DELETE existing key, then POST; `is_build_time` needs a PATCH after POST.
Smoke test: `https://<domain>/api/health` returns `{"db":"ok"}`, then submit the waitlist
form and show the row via `ssh ... docker exec <db> psql`.

**06 handover.** Turn on Coolify scheduled DB backups and say plainly that they live on the
same disk, so they are not a real backup until off-site S3 is added. Write `SERVER.md`
(IP, domains, UUIDs, where the config is, how to tear down: `hcloud server delete`).

## starter/

Next.js (App Router, `output: "standalone"`), one landing page with a single bold visual
decision, waitlist form via a server action, `/api/health` that runs `select 1`.
Plain `pg`, `migrate.sql` with `create table if not exists` run at boot (no ORM: the user
picks their own). Multi-stage Dockerfile, non-root user, binds `0.0.0.0:$PORT`.
Email validated and length-capped server side, unique constraint on email
(double submit is a no-op), no PII in logs.

## PREPARE-APP.md (MVP scope: Node / Next.js)

1. Read `~/.config/coolify/config`, verify the token.
2. Inventory: port, start command, env vars (from code and `.env*`), DB, file uploads,
   migrations. Write findings to `DEPLOY.md` before changing anything; ask before writes.
3. Add what is missing: Dockerfile (modeled on `starter/`), `.dockerignore`, health route,
   `.env.example`. `NEXT_PUBLIC_*` marked build-time.
4. Prove it locally: `docker build` and a run with the health check.
5. Provision and deploy as in phase 05, reusing the same deploy-key + webhook recipe.
6. Uploads on local disk get flagged, not silently "fixed": persistent storage is UI-only
   in Coolify, so the user gets the exact click path.

Other stacks: the prompt says "not supported yet" instead of guessing a Dockerfile.

## Build order

Status 2026-10-06: steps 1, 2, 3, 5 (written, not yet run on a real app) and 6 done.
`starter/` tested in Docker; `lib.sh` + `verify.sh` tested against a mock API
(`bash test/lib.test.sh`). Open: step 0 (spike) and step 4 (dry run), both need a real VPS.

0. **Spike on a fresh CX-class VPS (~1 hour, a few cents):** run the flow by hand and
   settle every **[verify]**: GitHub manual webhook endpoint, PG18 status, instance-domain
   lockout, `is_build_time` behavior on current Coolify. Record the tested Coolify version.
1. `starter/` + local `docker build` proof.
2. `verify.sh`.
3. Phase files 00-06 + `SETUP.md` dispatcher.
4. Dry run with a clean agent session on a second fresh VPS, start to finish, noting
   every place the agent asked something it should have known or did something unasked.
5. `PREPARE-APP.md`, tested on one real existing Next.js app.
6. README, then publish.

## Not in MVP (and when to add)

- Claude Code plugin (skills + `/vps-setup` command): after the markdown flow survives
  two clean dry runs.
- Other stacks in PREPARE-APP: when someone asks for a specific one.
- Off-site S3 backups (Hetzner Object Storage / R2): first extension, it is the real
  data-loss gap.
- Staging/preview environments, monitoring, Cloudflare DNS API, self-hosted Forgejo
  (already covered by the private `coolify-selfhosted` skill), Terraform.

## Do not copy from the private skills

`coolify-deploy` hardcodes the private Coolify URL and server IP. Everything that goes into
`references/` gets scrubbed to placeholders.
