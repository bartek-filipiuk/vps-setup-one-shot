# vps-setup-one-shot

Your own deploy server, with an AI coding agent guiding you through it.

You end up with a VPS (Hetzner, or any Ubuntu 24.04 server) running [Coolify](https://coolify.io),
the panel on its own HTTPS domain, and a Next.js + Postgres landing page deployed to your domain.
Every push to `main` deploys it again. A second prompt then gets your existing apps onto the
same server.

## Start

```
git clone https://github.com/bartek-filipiuk/vps-setup-one-shot
cd vps-setup-one-shot
```

Then start your agent with the guide. With Claude Code it is one line:

```
claude "Read SETUP.md and guide me through it."
```

Or install it as a Claude Code plugin, no clone needed:

```
/plugin marketplace add bartek-filipiuk/vps-setup-one-shot
/plugin install vps-setup-one-shot@bartek-filipiuk
```

(from a shell: `claude plugin marketplace add bartek-filipiuk/vps-setup-one-shot`, then
`claude plugin install vps-setup-one-shot@bartek-filipiuk`), then type `/vps-setup` (or `/vps-setup-one-shot:vps-setup` if another command has that name). Later:
`/vps-status`, `/vps-doctor`, `/vps-checkup`, and in the repo of an app you already have,
`/vps-prepare-app` (later `/vps-staging` for a staging copy of it, `/vps-worker` for a
background worker next to it).

Any other agent (Codex, Cursor, ...) works the same way: open it in that folder and say
`Read SETUP.md and guide me through it.` `AGENTS.md` lists every runbook and the matching command.

Later, in the repo of an app you already have:

```
Read /path/to/vps-setup-one-shot/PREPARE-APP.md and prepare this app for deployment.
```

## What you need

- A computer with macOS, Linux or Windows with WSL2, plus `git`. The agent installs the rest
  (`gh`, `jq`, `dig`, `hcloud`, and `age` for `VAULT.md`, optional) after asking.
- A GitHub account.
- A domain where you can edit DNS records (at Cloudflare, the agent creates them with a token you
  make for that one zone).
- A Hetzner Cloud account (new accounts may need identity verification, which can take hours),
  a fresh Hetzner server you already have, or a fresh Ubuntu 24.04 server from any provider: a
  dedicated server or a VPS, installed in the provider's panel with your SSH key
  (`references/providers.md`).

## What it costs

A 4 GB server costs what Hetzner charges for it that day, billed by the hour: phase 01 lists every 4 GB type with its
monthly price for your location before anything is created (prices and the available types change; CX22, for example, is
no longer offered). Optional Hetzner backups add 20%.
Optional off-site database backups to Hetzner Object Storage have their own monthly price.
Delete the server and billing stops; `~/.config/vps-setup/SERVER.md` lists the teardown commands.

## What you do vs. what the agent does

You: create accounts, pay, add two DNS records (or, with DNS at Cloudflare, create one DNS
token instead), register the Coolify admin, create two API
tokens (typed into your own terminal, never into the chat), choose backups (and, for off-site
ones, create a storage bucket and its key pair), create a Discord webhook for alerts.

The agent: creates the server and firewall, hardens SSH, adds swap, installs Coolify, creates the
GitHub repo, deploy key, database, app and webhook, deploys, and proves each step worked.

## How it works

- `SETUP.md` is a short dispatcher. `verify.sh` checks the real state of your setup (can I SSH in,
  is password login off, does the panel serve valid HTTPS, is the app healthy) and names the next
  phase file in `phases/`. A new session or a lost context just runs `verify.sh` again.
- `~/.config/vps-setup/state` keeps what cannot be checked from outside (IP, domains, resource IDs,
  a few "you confirmed this" flags).
- `~/.config/coolify/config` holds the API URL and token (mode 600).
- `deploy_and_wait` (in `lib.sh`) prints the rollback point (the running commit), dumps the
  app's Postgres on the server (`/root/db-dumps/<DB_UUID>/`, newest ten kept) and only then
  deploys; a failed dump means no deploy. It ends with the exact rollback commands.
  `ROLLBACK.md` goes back to the previous image through Coolify's rollback and restores the dump
  only if a migration broke the data.
- Phase 06 connects Coolify's scheduled database backups to an S3 bucket (Hetzner Object
  Storage): daily, 7 kept on the server, 30 in the bucket, one run right away. `RESTORE.md`
  downloads a chosen backup onto the server and restores it.
- Phase 06 also turns on Coolify's notifications to a Discord channel (app stopped, deploy failed,
  backup failed, server unreachable and back, disk usage, restart limit) from one webhook URL you
  paste into your own terminal.
- `status.sh` prints one screen: server (ssh, disk, memory, pending reboot, package updates),
  Coolify version vs the latest release, every app with its status, last deploy and days to
  certificate expiry, the last backup of every database, plus the age of its last copy in S3,
  the Postgres major of every database, and whether a notification channel is on with the alert
  events. A Coolify release a
  minor version or more ahead is a warning. Exit 0 all OK, 1 needs attention, 2 server or API
  unreachable.
- `DOCTOR.md` is the runbook for "my app is down": `status.sh`, the health route, the newest
  deployment, the container, its logs (`app_logs`), disk and DNS, read-only, then one of five
  symptoms (site down, deploy failed, 502/503/504, certificate error, server unreachable) with
  its fix from `references/`, `ROLLBACK.md` or `RESTORE.md`, or an honest "this needs a human".
  Nothing changes without your yes.
- `HANDOVER.md` hands a whole server or one project to a client, or adds a colleague: the
  Coolify invite and role, each person's own API token, `SERVER.md` with who holds what, repo
  transfer and a new webhook secret, DNS, a table of every secret with how to rotate it, and the
  checklist that removes the developer's access (SSH key last, never the only one). Coolify cannot
  isolate one project inside a team; the file says so and offers the ways around it.
- One Coolify project per client or product, one environment per stage (`production` by
  default): `PREPARE-APP.md` and `SERVICES.md` ask which project a new app or tool belongs to,
  suggest a domain from the project's name and refuse one that is taken; `status.sh` groups apps
  and services by project, and `~/.config/vps-setup/PROJECTS.md` (generated, no secrets) lists
  what runs where. A setup from before keeps its one project as it is.
- `STAGING.md` adds a staging copy of an app on the same server: the branch `staging` deploys
  to `staging.<app-domain>` as a second app in the project's `staging` environment, with its own
  empty database (production data only if you opt in), the variable names from production with
  staging values, HTTP basic auth so it is not public, and push-to-deploy through the same
  GitHub webhook. Promotion is a merge into `main`, with the rollback point and a dump first;
  removal only on your yes.
- `WORKER.md` adds a background worker to an app: `starter-worker/` copied into the app's repo
  as `worker/`, deployed as a second Coolify app from the same repo with no domain, keeping a job
  queue and its schedules in the app's own Postgres. The web app enqueues a job with one SQL
  insert; a push deploys both; removal only on your yes.
- `SERVICES.md` puts a self-hosted tool next to your apps as a Coolify one-click service on its
  own domain: Umami, n8n, Uptime Kuma or Forgejo, with a DNS gate, the HTTPS wait, the first
  login, what is and is not backed up, and removal only on your yes. `status.sh` shows a line
  per service.
- `UPTIME.md` sets up Uptime Kuma through `SERVICES.md`, takes over its two first-start pages
  (database type, admin) from the server before the domain answers, with a generated password in
  `~/.config/vps-setup/kuma.env` (mode 600), then adds one HTTP check per app domain and a public
  status page per project (`kuma_sync`, idempotent, never deletes), and, per client, that page
  on the client's own domain with its own certificate (`kuma_domain_add`; the client adds one
  DNS record). Kuma 2.x has no write API,
  so `kuma.js` runs inside the Kuma container and drives it through socket.io like Kuma's own UI.
  `status.sh` gets an Uptime section read from the page's public JSON. The checks run on the same
  server, so a dead server is not reported by Kuma.
- `UPGRADE.md` keeps the server current: Coolify (backups first, the release notes checked
  against the API calls this guide uses, then Coolify's own upgrade script), Ubuntu updates and
  the reboot window, and a Postgres major version moved into a new database with the old one
  kept for a way back. `status.sh` says when each is due: pending security updates or an old
  reboot, and the Postgres major of every database.
- `REBUILD.md` brings everything back on a new server when the old one is gone for good: it
  runs the phases again, after `rebuild_inventory` says which state keys survive and which
  belonged to the old server, and restores each database from the newest backup of the old
  database in the bucket (`s3_backup_list`). Environment variable values, service volumes and
  everything written after that backup do not come back; the file says so up front.
- `CHECKUP.md` and `checkup.sh` are the monthly look: `status.sh` first, then the cloud firewall
  against the setup's three ports and every public port probed from your machine, the SSH
  daemon's settings and the keys that can log in as root, the Docker API on TCP or the Docker
  socket in a container that is not Coolify's, Coolify's published security advisories against
  the installed version, the backup success rate of the last 30 days, disk growth since last
  month and what the Hetzner servers cost. It ends with a list of actions, each with the runbook
  that fixes it. Read-only; the one write is a line with the disk numbers and cost in
  `~/.config/vps-setup/checkup.log` (mode 600) on your machine.
- `VAULT.md` keeps the tokens and the key of this setup safe on your machine: `vault_export`
  puts `~/.config/vps-setup/`, `~/.config/coolify/config`, the `hcloud` config and the ssh key
  into one file encrypted with `age` and a passphrase, which you keep off the laptop;
  `vault_import` brings them back on a new machine, `vault_check` (and the checkup) says when the
  copy is stale, and the rotation part changes each secret in an order that keeps the server
  working. You run the export and the restore in your own terminal: `age` asks for the
  passphrase there, so the agent never handles the passphrase.
- With DNS at Cloudflare, phase 01 and `SERVICES.md` create the A records through the
  Cloudflare API (`dns_set_a` in `lib.sh`: DNS only, created or updated, never deleted) from a
  token for that one zone; the `dig` check in phase 04 stays as the proof they resolve.
- The Claude Code plugin is this repo itself: `.claude-plugin/` holds the plugin and marketplace
  manifests, and each command in `skills/` is a thin pointer that names its runbook in the
  installed copy and repeats none of it; the Cursor rule in `.cursor/rules/` lists the same
  files. `test/packaging.sh` checks that the commands, the rule and the `AGENTS.md` table agree.
  The manifests carry no version, so `claude plugin update vps-setup-one-shot` follows the latest
  commit.
- `starter/` is the demo app: Next.js (standalone output), a waitlist form writing to Postgres,
  `/api/health` checking the database, a non-root multi-stage Docker image.

## Security choices

- The Coolify panel is never open to the internet before it has HTTPS: the firewall allows only
  22, 80 and 443, and you register the admin through an SSH tunnel.
- Hetzner Cloud Firewall instead of `ufw`, because Docker bypasses `ufw`. On any other provider
  a host firewall in `INPUT` and Docker's `DOCKER-USER` chain, on the public interface only,
  IPv4 and IPv6 (phase 02 step 4), tried with a five-minute automatic revert before it is kept.
- SSH: key only. Root login stays allowed with keys only, because Coolify manages its own host
  over SSH as root.
- Coolify clones your private repo with a read-only deploy key for that repo only. GitHub calls
  Coolify with a per-app webhook secret; the API token never leaves your machine.
- The database is never exposed publicly.
- The secrets on your machine are files with mode 600, never typed into the chat; the vault
  (`VAULT.md`) is an `age`-encrypted copy of them, to get everything back on a new laptop and to
  keep a leaked home backup harmless. It does not keep the files on a lost disk secret (that is
  full-disk encryption's job), and it does not stop malware running as you, or an agent ignoring
  `AGENTS.md` rule 2, from reading them.

## Status

- `starter/` is tested: Docker build, health check, signup flow, duplicate and invalid input,
  database down at runtime and at startup, IPv6 `localhost` health check.
- Phase 05 (deploy key, Postgres, app, domain, push-to-deploy) has been run against a live
  Coolify 4.3.23; the landing at selfhosted.devince.dev is the result.
- `status.sh` is tested against a fake Coolify API only (`test/status.test.sh`) and has **not
  been run on a real server yet**. The API response shapes it reads were checked by hand on a
  live Coolify 4.3.23 (`references/coolify-api.md`). On macOS it needs `gtimeout`
  (`brew install coreutils`) for the certificate checks; without it they are skipped with a
  warning. The script's macOS date fallback has not been run on a Mac.
- Safe deploys (R07: dump and rollback point in `deploy_and_wait`, `rollback_and_wait`,
  `db_restore`, `ROLLBACK.md`) are tested against a fake Coolify API and a stubbed `ssh` only
  (`test/lib.test.sh`) and have **not been run on a real server yet**. The GET endpoints they
  read were checked on a live Coolify 4.3.23; the rollback, stop and start POST calls come from
  the 4.3.23 OpenAPI document and are marked `[verify]` in `references/coolify-api.md`.
- Off-site backups (R04: S3 storage, backup schedule, backup now, download and restore in
  `lib.sh`, phase 06 step 1, `RESTORE.md`, the `status.sh` off-site line) are tested against a
  fake Coolify API, a stubbed `ssh` and a fake `docker` only (`test/lib.test.sh`,
  `test/status.test.sh`) and have **not been run on a real server yet**. `GET /s3-storages` was
  checked on a live Coolify 4.3.23; the other calls come from the 4.3.23 source and are marked
  `[verify]` in `references/coolify-api.md`.
- Alerts (R06a: `notify_setup`, `notify_status` in `lib.sh`, phase 06 step 2, the `status.sh`
  alerts line) are tested against a fake Coolify API only (`test/lib.test.sh`,
  `test/status.test.sh`) and have **not been run on a real server yet**: no Discord message has
  been sent through them. `GET /notifications/*` was checked on a live Coolify 4.3.23; the PATCH
  call comes from the 4.3.23 source and is marked `[verify]` in `references/coolify-api.md`.
- `DOCTOR.md` (R05) and `app_logs` are tested against a fake Coolify API only
  (`test/lib.test.sh`) and have **not been run on a real server yet**; the five symptoms have
  not been broken on purpose on a server. `GET /applications/{uuid}/logs` was checked on a live
  Coolify 4.3.23; its "not running" answer comes from the source and is marked `[verify]`.
- `HANDOVER.md` (R12), `team_members` and `ssh_keys_list` are tested against a fake Coolify API
  only (`test/lib.test.sh`) and have **not been run on a real server yet**; no server has been
  handed over with it. `GET /team/members` and `GET /security/keys` were checked on a live
  Coolify 4.3.23; invites, roles and tokens have no API, so those parts come from the source and
  are marked `[verify]`.
- `SERVICES.md` (R10), `service_create`, `service_status`, `service_delete` and the `status.sh`
  Services section are tested against a fake Coolify API only (`test/lib.test.sh`,
  `test/status.test.sh`) and have **not been run on a real server yet**; no service has been
  created with them. `GET /services` was checked on a live Coolify 4.3.23; creating a service
  with its domain, delete and the backups of a service come from the 4.3.23 source and are
  marked `[verify]`.
- `UPTIME.md` (R06b), `kuma_env_init`, `kuma_init`, `kuma_targets`, `kuma_sync`, `kuma_status`,
  `kuma.js` and the `status.sh` Uptime section are tested against a fake Coolify API, a stubbed
  `ssh`, a fake `docker` and a fake Kuma socket only (`test/lib.test.sh`, `test/status.test.sh`,
  `test/kuma.test.js`) and have **not been run on a real server yet**; no Kuma has been set up
  with them. The socket events and HTTP answers come from Uptime Kuma 2.x (2.5.6 source) and are
  marked `[verify]` in `references/uptime-kuma.md`. The same goes for a client's domain on a
  status page (R22: `UPTIME.md` step 9, `dns_check`, `kuma_domain_add`, `kuma_domain_remove`,
  `service_app`, `service_app_urls_set`, `service_restart`, the `kuma.js` domain action, the
  `status.sh` `page` line, also against a fake `dig`): no client domain has been mapped yet; the
  Coolify calls come from the 4.3.23 source and are marked `[verify]`.
- Projects and clients (R09: `project_ensure`, `env_ensure`, `project_ctx`,
  `app_domain_default`, `domain_in_use`, `projects_inventory`, `projects_md`, the `status.sh`
  group lines and the changes to phase 05, `PREPARE-APP.md` and `SERVICES.md`) are tested against
  a fake Coolify API only (`test/lib.test.sh`, `test/status.test.sh`) and have **not been run on a
  real server yet**; no second project has been created with them. The `GET` shapes of projects,
  environments and `environment_id` were checked read-only on a live Coolify 4.3.23; creating an
  environment, a domain set twice and duplicate project names come from the API docs and are
  marked `[verify]` in `references/coolify-api.md`.
- `STAGING.md` (R11), `staging_init`, `app_env_keys`, `app_env_set`, `app_create`,
  `app_basic_auth`, `apps_webhook_secret` and `staging_teardown` are tested against a fake
  Coolify API only (`test/lib.test.sh`, `test/status.test.sh`) and have **not been run on a real
  server yet**; no staging app has been created or promoted with them. The `GET` shapes of an
  application and its environment variables were checked read-only on a live Coolify 4.3.23; the
  basic-auth write, the deletes, a second app on the same deploy key and one GitHub webhook
  serving two branches come from the 4.3.23 source and docs and are marked `[verify]` in
  `references/coolify-api.md`.
- The worker (R24, first half: `WORKER.md`, `starter-worker/`, `worker_create`,
  `worker_env_db`, `worker_enqueue`, `worker_jobs`, `worker_teardown`) is tested against a fake
  Coolify API and a stubbed `ssh` only (`test/lib.test.sh`), and the worker itself with Docker
  and a real Postgres in CI (`test/fixtures.sh starter-worker`: health, a job through the queue,
  the cron slots, the database stopped). It has **not been run on a real server yet**; no worker
  app has been created in a Coolify. An app with no domain (`autogenerate_domain:false`), the
  health check without a domain and one webhook deploying both apps come from the Coolify 4.3.23
  source and are marked `[verify]` in `references/coolify-api.md`.
- `UPGRADE.md` (R14), `db_major`, `pg_major_upgrade_plan`, the `RESTORE_FROM_DB` guard of
  `db_restore` and the `status.sh` updates and postgres lines are tested against a fake Coolify
  API, a stubbed `ssh` and a fake `docker` only (`test/lib.test.sh`, `test/status.test.sh`) and
  have **not been run on a real server yet**; no Coolify, Ubuntu or Postgres upgrade has been
  done with them. The upgrade script, the missing upgrade API and the database calls come from
  the Coolify 4.3.23 source and docs and are marked `[verify]`.
- DNS through the Cloudflare API (R18: `cf_check`, `dns_set_a`, `dns_list` in `lib.sh`, phase 00
  step 4a, phase 01 step 4, `SERVICES.md`) is tested against a fake Cloudflare API only
  (`test/lib.test.sh`) and has **not been run on a real server or a real Cloudflare zone yet**; no
  record has been created with it. The calls come from the Cloudflare API documentation; the
  answers not described there, and DNS only being required, are marked `[assumed]` in
  `references/cloudflare-api.md`.
- `REBUILD.md` (R15), `s3_backup_list` and `rebuild_inventory` are tested against a fake Coolify
  API, a stubbed `ssh` and a fake `docker` only (`test/lib.test.sh`) and have **not been run on a
  real server yet**; no server has been rebuilt with them. The layout of the backups in the
  bucket and what `mc ls` prints come from the Coolify 4.3.23 source and the `mc` documentation
  and are marked `[verify]` in `references/coolify-api.md`.
- `CHECKUP.md` (R16), `checkup.sh` and its helpers in `lib.sh` are tested against a fake Coolify
  API, a fake GitHub advisories answer, a fake `hcloud` and fake server tools only
  (`test/lib.test.sh`, `test/checkup.test.sh`) and have **not been run on a real server yet**; the
  "no false positive on a clean setup" criterion holds against the fakes only. Which containers of
  a clean Coolify mount the Docker socket, the `hcloud` JSON fields, the advisories answer and how
  long Coolify keeps backup runs come from the source and API documentation and are marked
  `[verify]` in `references/coolify-api.md`.
- `VAULT.md` (R23), `vault_export`, `vault_import` and `vault_check` are tested against a fake
  `age` (`test/lib.test.sh`, `test/checkup.test.sh`) and in a round trip with the real `age`
  under a pseudo-terminal (`test/vault-roundtrip.sh`, checked on the author's machine with age
  1.2.1, CI uses Ubuntu's `age`). No machine has been restored from a vault for real, and **no rotation
  step has been run on a server yet**; the UI paths in it are marked `[verify]`.
- The Claude Code plugin and the Cursor rule (R19) are checked by `test/packaging.sh` only and
  have **not been installed from the marketplace or run end to end yet**; that Codex and Cursor
  pick up `AGENTS.md` and the rule comes from their documentation, not a run. `claude plugin
  validate .` passes locally (warning only about the missing version) and is not in CI.
- Fixtures for more stacks (R08: `fixtures/static`, `fixtures/python-fastapi`, `fixtures/go`,
  `fixtures/compose`, the stack table in `PREPARE-APP.md` step 1) are built and health-checked
  with Docker in CI only (`test/fixtures.sh`, `.github/workflows/fixtures.yml`) and have **not
  been deployed on a server yet**; no app of these stacks has gone through `PREPARE-APP.md`.
  Compose applications in Coolify come from the API docs and are marked `[verify]` in
  `references/coolify-api.md`; the runbooks have no compose path yet.
- Providers beyond Hetzner (R20: the "Other provider" path of phase 01 with `server_check`, the
  host firewall of phase 02 step 4 with `hostfw_install`, `hostfw_apply`, `hostfw_confirm`,
  `hostfw_status`, `hostfw_port_add` and the server script `vps-hostfw`, the checkup's host
  firewall line, `references/providers.md`) are tested against a stubbed `ssh` and fake
  `iptables`, `systemctl` and `systemd-run` only (`test/lib.test.sh`, `test/checkup.test.sh`) and
  have **not been run on a dedicated server yet**; no rule has been applied to a real firewall.
  Docker's firewall backend field and Ubuntu 24.04's nft-backed `iptables` were checked on a live
  Coolify server; the provider panel paths come from the providers' docs and are marked
  `[verify]` in `references/providers.md`.
- Phases 01-04 (new server, hardening, Coolify install, panel domain) have **not yet been run
  end to end on a fresh server**.

Tested with: Coolify 4.3.23, Ubuntu 24.04, Next.js 16.3, Postgres 17.

## Not included yet

Preview environments per pull request (R21), uptime checks from outside the server, deploying apps
that are not Node.js (fixtures exist, see Status), Git hosts other than GitHub, DNS through the API for providers other than Cloudflare, installing the OS through a server
provider's API (documented in `references/providers.md`, not driven). What comes next, in which order
and how we will know it is done: [ROADMAP.md](ROADMAP.md).
