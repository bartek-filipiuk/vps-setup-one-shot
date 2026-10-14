# Contributing to vps-setup-one-shot

For anyone who changes this repository, person or agent. The repo is developed by an autonomous
agent with human review; read this before the first pull request. (`starter/AGENTS.md` is about
the Next.js starter app only.)

## Layout

`SETUP.md` (entry point the user's agent reads), `phases/` (00–06, one file per step),
`PREPARE-APP.md` (moving an existing app onto the server), `ROLLBACK.md` (back to the previous
version after a bad deploy), `RESTORE.md` (a database back from an off-site S3 backup), `lib.sh`
(state file, Coolify API helpers, deploy with dump and rollback point, rollback, restore,
S3 storage and off-site backups, Coolify notifications to Discord), `verify.sh` (reads the real server state and says which phase is next), `status.sh` (one-screen
health check, read-only),
`references/` (Coolify API notes, troubleshooting), `starter/` (the Next.js + Postgres app the setup
deploys; it is also the landing), `test/` (checks that need no server), `ROADMAP.md` (the plan,
ids R01…, mirrored in `starter/app/roadmap.ts`).

## Rules

1. **Proof before "done".** A phase, runbook or script counts as working only after a run on a real,
   fresh, throwaway server, with the output in the pull request. "Should work" is not a result. Until
   then the README "Status" section and the landing copy say so honestly.
2. **Secrets never go through the chat, the repo or a command line the agent types.** The user types
   tokens into their own terminal; files under `~/.config/vps-setup/` are `0600`. Never commit
   `.coolify.env`, state files or logs with tokens. Run `gitleaks git .` before opening a PR.
3. **Use Coolify, don't rebuild it.** Backups, notifications, rollback and services go through the
   Coolify API. Pin behaviour to a tested Coolify version and note it in `references/coolify-api.md`.
4. **Remote commands are explicit** (`ssh root@$VPS_IP '...'`), and nothing on the user's own
   machine is killed by pattern: background processes are stopped through their control socket or
   a saved PID.
5. **One way to do each thing.** A second option needs a user with a concrete case.
6. **Spending money needs the maintainer's yes.** Creating servers, buying domains or storage is
   done only for an agreed run, and every run ends with the teardown from `SERVER.md`.

## Checks

- `bash test/lib.test.sh` must print `ALL PASSED` (fake Coolify API, no server, no network).
- `bash test/status.test.sh` must print `ALL PASSED` (`status.sh` against a fake Coolify API with
  ssh and openssl stubs; seams `STATUS_SSH`, `STATUS_OPENSSL`, `STATUS_LATEST_URL`,
  `STATUS_TIMEOUT`). The test needs GNU `date` (Linux, CI); `status.sh` itself also runs on macOS.
- `shellcheck lib.sh verify.sh status.sh test/*.sh` is clean (shellcheck v0.10.0, the version CI pins);
  `bash -n` on every other changed shell file.
- `bash test/extract-blocks.sh` must print `ALL BLOCKS OK`: it runs `bash -n` and shellcheck on
  every untagged, `bash` or `sh` code block (backtick or tilde fences) in `phases/`, `SETUP.md`,
  `PREPARE-APP.md`, `ROLLBACK.md` and `RESTORE.md`, and fails on a fence left open. Tag blocks that are not shell (`text`,
  `json`, ...). `bash test/extract-blocks.test.sh` is its self-test and must print `ALL PASSED`.
- Shellcheck exclusions. Scripts: only `.shellcheckrc` (`shell=bash`, `disable=SC2015,SC1091`),
  default severity. Doc blocks: the same `.shellcheckrc` (passed with `--rcfile`) plus
  `-e SC2034,SC2154`, because blocks set and read variables across blocks, at severity
  `warning`. Anything else is fixed in the code or disabled inline with a reason.
- CI runs the same on every PR and push to main (`.github/workflows/ci.yml`); the starter build
  (`npm ci && npm run build`) runs when `starter/` changes (`starter.yml`). The full run on a real
  server (`e2e.yml`) is manual only and still a stub that always fails. Actions are pinned by
  commit SHA with the version in a comment.
- Changes to a phase: the PR says which run on a real server covered it, or is marked
  "not run yet" and the README status stays as it is.

## Pull requests

One roadmap item or one fix per pull request, small commits in English, test output in the
description. Keep `ROADMAP.md` and `starter/app/roadmap.ts` in sync. Commit messages carry no
AI or tool attribution lines.
