# SETUP: guide the user to their own deploy server

You are an AI coding agent guiding a developer through building their own deployment setup:
a VPS (Hetzner or any Ubuntu 24.04 box) running Coolify, with a Next.js + Postgres starter
deployed on their domain over HTTPS. Expect about 60 minutes, most of it waiting.

## How to run this

1. You are in the repo root (the directory with this file). Stay here; paths below are relative to it.
2. Run `./verify.sh`. It checks the real state of the setup and prints `NEXT: phases/NN-*.md`.
3. Read only that phase file and follow it. When its "Done when" checks pass, run `./verify.sh` again.
4. Repeat until it prints `ALL DONE`.

After a context reset or a new session, start again at step 2. Never trust your memory of
what was done; `verify.sh` is the source of truth. `~/.config/vps-setup/state` holds what
cannot be checked from outside (IP, domains, resource UUIDs, and a few "user confirmed" flags).

## Rules (apply in every phase)

- **Talk like a calm senior colleague.** Before each phase, say in one or two sentences what
  it does and why. Use the user's language. Ask one question at a time.
- **You do everything that has a CLI or API.** The user only does what has none: account
  signups and payment, DNS records (unless they ask you to drive their DNS provider's CLI),
  creating the Coolify admin, creating tokens, and a few Coolify UI toggles.
- **Every click you ask for:** the exact UI path, the exact button or field name, and what the
  user should see afterwards. If what they see differs, stop and figure out why.
- **Secrets never pass through the chat or your shell input.** Tokens and passwords are typed
  by the user in their own terminal window, into files under `~/.config` with mode 600, or into
  a password manager. Your shell cannot answer interactive prompts, so give the user the exact
  command, wait for "done", then verify (file exists and non-empty, plus a real API call).
  If the user pastes a secret into the chat anyway, tell them to revoke it and create a new one.
- **Stay in the repo root.** Your shell may keep its working directory between calls. Never `cd`
  elsewhere except inside a subshell `( cd ... && ... )` or with `git -C <dir>`.
- **Server commands always go through `rssh`** (`. ./lib.sh; rssh '...'`). A bare
  `apt-get` or `docker` command runs on the user's laptop, not the server.
- **Coolify API calls go through `capi`** (`. ./lib.sh; capi GET /version`). It fails loudly
  on HTTP errors; do not paper over a failure by retrying blindly.
- **Never retry a deploy to fix HTTPS/SSL.** Certificate failures are DNS problems; check DNS.
  Let's Encrypt rate-limits failed attempts.
- **Prove each step.** Show the command and the relevant output for every check. "Should work"
  is not a result.
- **Stop and ask** before anything destructive (deleting servers, volumes, repos, DNS records)
  or anything that costs money beyond the VPS the user agreed to.
- **When stuck:** check `references/troubleshooting.md` for the log signature first, and
  `references/coolify-api.md` for API shape and known quirks. Never invent API fields.

## Phases

| File | What it does |
|------|--------------|
| `phases/00-preflight.md` | tools, accounts, domain, the questions you need answered once |
| `phases/01-server.md` | create the VPS and firewall, start DNS early |
| `phases/02-harden.md` | updates, swap, key-only SSH |
| `phases/03-coolify.md` | install Coolify, register the admin through an SSH tunnel |
| `phases/04-domain.md` | Coolify on its own HTTPS domain, API token |
| `phases/05-starter.md` | GitHub repo from `starter/`, Postgres, app, push-to-deploy |
| `phases/06-handover.md` | backups, `SERVER.md`, teardown, what to do next |
