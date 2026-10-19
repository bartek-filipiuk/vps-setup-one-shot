# Contributing to vps-setup-one-shot

For anyone who changes this repository, person or agent. The repo is developed by an autonomous
agent with human review; read this before the first pull request. (`starter/AGENTS.md` is about
the Next.js starter app only.)

## Entry points

For the user's agent: open this folder and say `Read SETUP.md and guide me through it.` Codex and
Cursor read this file (Cursor also `.cursor/rules/vps-setup-one-shot.mdc`); Claude Code users can
install the plugin instead (README "Start") and type the command. A command never repeats a
runbook step; it names the file. `test/packaging.sh` parses this table.

| What | Runbook | Claude Code |
| --- | --- | --- |
| a server from nothing, Coolify and the starter app | `SETUP.md` | `/vps-setup` |
| one-screen health, read-only | `status.sh` | `/vps-status` |
| the app is down, a deploy failed, 502, certificate error | `DOCTOR.md` | `/vps-doctor` |
| the monthly checkup | `CHECKUP.md` | `/vps-checkup` |
| an existing app onto the server, from its repo | `PREPARE-APP.md` | `/vps-prepare-app` |
| a staging copy of an app from its staging branch, promotion by merge | `STAGING.md` | `/vps-staging` |
| back to the previous version after a bad deploy | `ROLLBACK.md` | `/vps-rollback` |
| a database back from an off-site backup | `RESTORE.md` | `/vps-restore` |
| a self-hosted tool on its own domain | `SERVICES.md` | `/vps-services` |
| uptime checks and a public status page for your apps, also on a client's domain | `UPTIME.md` | `/vps-uptime` |
| Coolify, Ubuntu and Postgres major upgrades | `UPGRADE.md` | `/vps-upgrade` |
| a new server, databases from the backups | `REBUILD.md` | `/vps-rebuild` |
| a server or project to someone else, old access removed | `HANDOVER.md` | `/vps-handover` |

## Layout

`SETUP.md` (entry point the user's agent reads), `phases/` (00–06, one file per step),
`PREPARE-APP.md` (moving an existing app onto the server), `STAGING.md` (a staging app and
database from the `staging` branch on the same server, promotion by merge, teardown), `ROLLBACK.md` (back to the previous
version after a bad deploy), `RESTORE.md` (a database back from an off-site S3 backup), `DOCTOR.md`
(from "my app is down" to a fix or to "this needs a human"), `HANDOVER.md` (a server or a
project to a client, or a colleague joining, and removing the old access), `SERVICES.md`
(self-hosted tools as Coolify one-click services, each on its own domain), `UPTIME.md` (Uptime
Kuma from `SERVICES.md`, its first-start pages taken over, a check per app domain and a public
status page per project, also on the client's domain), `UPGRADE.md`
(Coolify, Ubuntu and Postgres major versions, each with a backup first and a check after),
`REBUILD.md` (a new server from nothing through the phases, the databases from the off-site
backups), `CHECKUP.md` (the monthly checkup: `checkup.sh`, what each line means, the fixes),
`lib.sh`
(state file, Coolify API helpers, deploy with dump and rollback point, rollback, restore, app logs,
S3 storage and off-site backups, Coolify notifications to Discord, team members and stored keys,
one-click services, uptime checks (the Kuma login in `kuma.env`, `kuma_init`, `kuma_sync`,
`kuma_status`), status page domains (`dns_check`, `kuma_domain_add`, `kuma_domain_remove`),
projects and environments and the generated PROJECTS.md, staging (the
staging state, environment variable names, a second app, basic auth, the shared webhook
secret, teardown), Postgres major
versions, DNS records through the Cloudflare API, the
rebuild inventory and the backups in the bucket, the read-only checkup helpers: hcloud list and
describe only, advisories, backup success rate, the checkup log), `kuma.js` (runs inside the Kuma
container and drives Kuma through socket.io; `lib.sh` sends it there), `verify.sh` (reads the real
server state and says which phase is next), `status.sh` (one-screen health check, read-only),
`checkup.sh` (the monthly checkup: `status.sh` plus ports, sshd, Docker, advisories, backup rate,
disk growth and cost, ending with the actions; read-only),
`references/` (Coolify and Cloudflare API notes, troubleshooting), `starter/` (the Next.js + Postgres app the setup
deploys; it is also the landing), `fixtures/` (the smallest app of each further stack: static,
FastAPI, Go, compose; the model `PREPARE-APP.md` uses, see `fixtures/README.md`), `test/`
(checks that need no server), `ROADMAP.md` (the plan, ids R01…, mirrored in `starter/app/roadmap.ts`), `.claude-plugin/` (the Claude Code plugin
and marketplace manifests), `skills/` (one pointer per entry point, the plugin's commands),
`.cursor/rules/` (the Cursor rule, the same pointers).

## Rules

1. **Proof before "done".** A phase, runbook or script counts as working only after a run on a real,
   fresh, throwaway server, with the output in the pull request. "Should work" is not a result. Until
   then the README "Status" section and the landing copy say so honestly.
2. **Secrets never go through the chat, the repo or a command line the agent types.** The user types
   tokens into their own terminal; files under `~/.config/vps-setup/` are `0600` (`kuma.env`, the
   Kuma admin password, is generated there by `kuma_env_init` and read only by the user and `lib.sh`). Never commit
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

- `bash test/lib.test.sh` must print `ALL PASSED` (fake Coolify API, no server, no network). With
  `node` on the PATH it also runs `node --check kuma.js` and `test/kuma.test.js` (`kuma.js` against
  a fake Kuma socket and fetch, prints `ALL PASSED`).
- `bash test/status.test.sh` must print `ALL PASSED` (`status.sh` against a fake Coolify API with
  ssh and openssl stubs; seams `STATUS_SSH`, `STATUS_OPENSSL`, `STATUS_LATEST_URL`,
  `STATUS_TIMEOUT`, `STATUS_ENTRY_URL`). The test needs GNU `date` (Linux, CI); `status.sh` itself also runs on macOS.
- `bash test/checkup.test.sh` must print `ALL PASSED` (`checkup.sh` against the same kind of fake
  Coolify API, also serving the GitHub advisories, with ssh, openssl and `hcloud` stubs; port
  probes go to 127.0.0.1 only; seams `CHECKUP_SSH`, `CHECKUP_LOG`, `CHECKUP_RECORD`,
  `ADVISORIES_URL`, `CHECKUP_PROBE_TIMEOUT` plus `status.sh`'s). A clean setup must give no `WARN`
  or `FAIL` line.
- `bash test/fixtures.sh` must print `ALL FIXTURES OK` (needs Docker with a recent compose v2,
  for `up --wait --wait-timeout`; builds every fixture, checks its health contract, removes what
  it created by name, never prunes).
  CI runs it per fixture when `fixtures/` changes (`.github/workflows/fixtures.yml`).
- `shellcheck lib.sh verify.sh status.sh checkup.sh test/*.sh` is clean (shellcheck v0.10.0, the version CI pins);
  `bash -n` on every other changed shell file.
- `bash test/extract-blocks.sh` must print `ALL BLOCKS OK`: it runs `bash -n` and shellcheck on
  every untagged, `bash` or `sh` code block (backtick or tilde fences) in `phases/`, `SETUP.md`,
  `PREPARE-APP.md`, `STAGING.md`, `ROLLBACK.md`, `RESTORE.md`, `DOCTOR.md`, `HANDOVER.md`, `SERVICES.md`, `UPGRADE.md`, `REBUILD.md`, `CHECKUP.md` and `UPTIME.md`, and fails on a fence left open. Tag blocks that are not shell (`text`,
  `json`, ...). `bash test/extract-blocks.test.sh` is its self-test and must print `ALL PASSED`.
- `bash test/packaging.sh` must print `ALL POINTERS OK`: the "Entry points" table, the plugin and
  marketplace manifests, `skills/` and the Cursor rule agree, and the pointers carry no runbook
  content (no code fences, no `lib.sh` helper names, no server commands). `claude plugin validate .`
  passes locally (warnings about the missing version are intended, so updates follow commits);
  it is not in CI.
- `bash test/no-secret-argv.sh` must print `NO SECRETS IN ARGV`: no `jq --arg/--argjson`,
  `-H/--header`, or (on a `gh`/`curl` line) `-f/-F/-d/--data/-u/-b` in the runbooks or the
  scripts, continued lines joined, expands a secret-named variable (`S`, `W`, `PW`, `PASS*`,
  `SECRET*`, `TOKEN*`, `KEY`, `URL`, also with a `FOO_` prefix, ...), `$(openssl rand` or a
  credential getter (`cf_cred`, `s3_cred`, `kuma_cred`, `cat`, ...); the value goes on stdin instead (`printf '%s' "$S" | jq -Rs`,
  `gh api --input -`, `curl -K`). It is a name-based grep: a secret under another name is still
  on you.
- Shellcheck exclusions. Scripts: only `.shellcheckrc` (`shell=bash`, `disable=SC2015,SC1091`),
  default severity. Doc blocks: the same `.shellcheckrc` (passed with `--rcfile`) plus
  `-e SC2034,SC2154`, because blocks set and read variables across blocks, at severity
  `warning`. Anything else is fixed in the code or disabled inline with a reason.
- CI runs the same on every PR and push to main (`.github/workflows/ci.yml`); the starter build
  (`npm ci && npm run build`) runs when `starter/` changes (`starter.yml`), the fixtures
  (`test/fixtures.sh`) when `fixtures/` changes (`fixtures.yml`). The full run on a real
  server (`e2e.yml`) is manual only and still a stub that always fails. Actions are pinned by
  commit SHA with the version in a comment.
- Changes to a phase: the PR says which run on a real server covered it, or is marked
  "not run yet" and the README status stays as it is.

## Pull requests

One roadmap item or one fix per pull request, small commits in English, test output in the
description. Keep `ROADMAP.md` and `starter/app/roadmap.ts` in sync. Commit messages carry no
AI or tool attribution lines.
