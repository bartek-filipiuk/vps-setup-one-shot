# vps-setup-one-shot

Your own deploy server in about an hour, with an AI coding agent guiding you through it.

You end up with a VPS (Hetzner, or any Ubuntu 24.04 server) running [Coolify](https://coolify.io),
the panel on its own HTTPS domain, and a Next.js + Postgres landing page deployed to your domain.
Every push to `main` deploys it again. A second prompt then gets your existing apps onto the
same server.

## Start

```
git clone https://github.com/<owner>/vps-setup-one-shot
cd vps-setup-one-shot
```

Open your agent (Claude Code, Codex, Cursor, or similar) in that folder and say:

```
Read SETUP.md and guide me through it.
```

Later, in the repo of an app you already have:

```
Read /path/to/vps-setup-one-shot/PREPARE-APP.md and prepare this app for deployment.
```

## What you need

- A computer with macOS, Linux or Windows with WSL2, plus `git`. The agent installs the rest
  (`gh`, `jq`, `dig`, `hcloud`) after asking.
- A GitHub account.
- A domain where you can edit DNS records.
- A Hetzner Cloud account (new accounts may need identity verification, which can take hours)
  or a fresh Ubuntu 24.04 server from any provider.

## What it costs

A 4 GB server is about 5-10 EUR per month, billed by the hour. Optional Hetzner backups add 20%.
Delete the server and billing stops; `~/.config/vps-setup/SERVER.md` lists the teardown commands.

## What you do vs. what the agent does

You: create accounts, pay, add two DNS records, register the Coolify admin, create two API
tokens (typed into your own terminal, never into the chat), flip a backup switch.

The agent: creates the server and firewall, hardens SSH, adds swap, installs Coolify, creates the
GitHub repo, deploy key, database, app and webhook, deploys, and proves each step worked.

## How it works

- `SETUP.md` is a short dispatcher. `verify.sh` checks the real state of your setup (can I SSH in,
  is password login off, does the panel serve valid HTTPS, is the app healthy) and names the next
  phase file in `phases/`. A new session or a lost context just runs `verify.sh` again.
- `~/.config/vps-setup/state` keeps what cannot be checked from outside (IP, domains, resource IDs,
  a few "you confirmed this" flags).
- `~/.config/coolify/config` holds the API URL and token (mode 600).
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
- The full guided flow has **not yet been run end to end on a real server**. Items marked
  **[verify]** in `references/coolify-api.md` are expected behavior, not yet confirmed.

Tested with: Coolify (not yet), Ubuntu 24.04, Next.js 16.3, Postgres 17.

## Not included yet

Off-site database backups to S3, staging/preview environments, monitoring and alerts, apps that
are not Node.js, Git hosts other than GitHub, DNS automation.
