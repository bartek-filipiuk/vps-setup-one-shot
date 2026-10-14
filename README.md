# vps-setup-one-shot

Your own deploy server in about an hour, with an AI coding agent guiding you through it.

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

Any other agent (Codex, Cursor, ...) works the same way: open it in that folder and say
`Read SETUP.md and guide me through it.`

Later, in the repo of an app you already have:

```
Read /path/to/vps-setup-one-shot/PREPARE-APP.md and prepare this app for deployment.
```

## What you need

- A computer with macOS, Linux or Windows with WSL2, plus `git`. The agent installs the rest
  (`gh`, `jq`, `dig`, `hcloud`) after asking.
- A GitHub account.
- A domain where you can edit DNS records.
- A Hetzner Cloud account (new accounts may need identity verification, which can take hours),
  a fresh Hetzner server you already have, or a fresh Ubuntu 24.04 server from any provider.

## What it costs

A 4 GB server is about 5-10 EUR per month, billed by the hour. Optional Hetzner backups add 20%.
Optional off-site database backups to Hetzner Object Storage have their own monthly price.
Delete the server and billing stops; `~/.config/vps-setup/SERVER.md` lists the teardown commands.

## What you do vs. what the agent does

You: create accounts, pay, add two DNS records, register the Coolify admin, create two API
tokens (typed into your own terminal, never into the chat), choose backups (and, for off-site
ones, create a storage bucket and its key pair).

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
- `status.sh` prints one screen: server (ssh, disk, memory, pending reboot), Coolify version vs
  the latest release, every app with its status, last deploy and days to certificate expiry, and
  the last backup of every database, plus the age of its last copy in S3. A Coolify release a
  minor version or more ahead is a warning. Exit 0 all OK, 1 needs attention, 2 server or API
  unreachable.
- `starter/` is the demo app: Next.js (standalone output), a waitlist form writing to Postgres,
  `/api/health` checking the database, a non-root multi-stage Docker image.

## Security choices

- The Coolify panel is never open to the internet before it has HTTPS: the firewall allows only
  22, 80 and 443, and you register the admin through an SSH tunnel.
- Hetzner Cloud Firewall instead of `ufw`, because Docker bypasses `ufw`.
- SSH: key only. Root login stays allowed with keys only, because Coolify manages its own host
  over SSH as root.
- Coolify clones your private repo with a read-only deploy key for that repo only. GitHub calls
  Coolify with a per-app webhook secret; the API token never leaves your machine.
- The database is never exposed publicly.

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
- Phases 01-04 (new server, hardening, Coolify install, panel domain) have **not yet been run
  end to end on a fresh server**.

Tested with: Coolify 4.3.23, Ubuntu 24.04, Next.js 16.3, Postgres 17.

## Not included yet

Staging/preview environments, monitoring and alerts, apps that
are not Node.js, Git hosts other than GitHub, DNS automation. What comes next, in which order
and how we will know it is done: [ROADMAP.md](ROADMAP.md).
