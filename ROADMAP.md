# Roadmap

No dates. Four lanes, read left to right: Now, Next, Later, Ideas. Each item has a stable id
(R01…), one line on what the user gains and one line on the done criterion. The same list is on
the landing (`starter/app/roadmap.ts`, English and Polish); keep the two in sync. The repo is
developed by an autonomous agent with human review; pace is set by proof, not by the calendar.

Who we build for: one person running a few apps for themselves and for clients, who wants to
get a server and a deploy pipeline without learning Coolify, Docker or Hetzner first; put any
reasonable app on it; see at a glance whether their apps are up, backed up and up to date;
survive the bad day (failed deploy, full disk, dead server); and hand a project to a client or
a colleague without handing over their own credentials. Every item serves one of those five.

Rules that apply to every item:
- Nothing ships without a run on a fresh, throwaway server (R01). "Should work" is not a result.
- Runbooks plus a thin, tested shell layer. Where Coolify has the feature (backups,
  notifications, rollback, services), we drive it through its API; we never rebuild it.
- Secrets stay on the user's machine or their server. Never in the chat, never in the repo.
- One way to do each thing. A second option is added only for a user with a concrete case.

## Now

- **R01 End-to-end harness on a throwaway server.** `test/e2e.sh` creates a CX-class Hetzner
  server, drives phases 01–06 unattended (answers from a fixture state file, the two admin clicks
  replaced by a documented tunnel or API step), runs `verify.sh`, submits the starter form and
  deletes the server. Cents per run; on every PR and nightly against Coolify `latest`.
  Done when: a green run from `hcloud server create` to `ALL DONE`, server gone, Coolify version logged.
- **R02 The recorded run, then public.** The whole flow on a fresh server, recorded; every
  `[verify]` in `PLAN.md` and `references/` settled; `AGENTS.md` at the root telling a contributing
  agent how this repo is developed. Done when: `grep -r '\[verify\]'` is empty, the repo is public,
  the landing links the recording.
- **R03 `status.sh`: one screen.** Server reachable, disk and memory, pending reboot, Coolify version
  vs latest release, every app with status and last deploy result, days to certificate expiry, last
  backup and whether it succeeded. Non-zero exit when something needs attention.
  Done when: every line is backed by a real check on the harness server and on a production server.
- **R04 Off-site backups and a restore drill.** Coolify database backups to any S3-compatible
  storage (Hetzner Object Storage first), set up in phase 06. `RESTORE.md` restores one database
  from a chosen backup. Done when: the harness backs up, destroys the database, restores, and the
  waitlist row is back; `status.sh` shows off-site backup age.
- **R05 `DOCTOR.md`: "my app is down".** From a symptom (site down, deploy failed, 502, certificate
  error, server unreachable) through `status.sh`, deployment logs, container logs, disk and DNS to
  a fix from `references/` or an honest "this needs a human because X".
  Done when: the five symptoms have harness fixtures that break the server on purpose, and the
  runbook reaches the right fix for each.
- **R06 Alerts that reach a phone.** Coolify's notifications (deploy failed, backup failed, server
  unreachable) wired to email, Telegram or Discord; an external uptime check per app domain through
  Uptime Kuma run as a Coolify service, with its public status page. Done when: the harness stops
  the starter container and an alert arrives within five minutes.

## Next

- **R07 Safe deploys.** `deploy_and_wait` dumps the database first and prints the rollback point;
  `ROLLBACK.md` reverts to the previous image and restores the dump if needed; migration guidance
  in `PREPARE-APP.md` (expand, then contract). Done when: the harness deploys a broken commit,
  rolls back, and the app is healthy with its data.
- **R08 More stacks, by fixture.** Each supported stack gets a sample app in `fixtures/` that the
  harness deploys: static site, Docker Compose stack, Python (FastAPI, Django), Go. A stack without
  a green fixture stays "not supported yet". Done when: three stacks beyond Node are green.
- **R09 Projects and clients.** One Coolify project per client or product, one environment per
  stage, names and domains derived from the project name, `PROJECTS.md` listing what runs where,
  `status.sh` grouped by project. Done when: the harness runs two projects side by side.
- **R10 `SERVICES.md`: self-host the tools in one prompt.** n8n, Plausible or Umami, Uptime Kuma,
  Forgejo, Minio and the other Coolify one-click services, each with a domain, HTTPS, backups and a
  line in `status.sh`. Done when: three services deploy in the harness with backups verified.
- **R11 Staging without a second server.** A `staging` branch deploys to `staging.<app-domain>`
  as a second app with its own database; promotion is a merge to `main`. Done when: the harness
  pushes to `staging`, sees it change, merges, sees production change.
- **R12 Handover pack.** `HANDOVER.md` produces what a client or colleague needs to take over a
  project or a server: a Coolify team invite with the right role, a scoped token where Coolify
  supports it, `SERVER.md` for that project, DNS and repo ownership steps, and the checklist that
  removes the original developer's access. Done when: a second user, with only the pack, deploys a
  change in the harness.
- **R13 Move in from Vercel, Railway or Render.** The agent reads the existing project (framework,
  env, domains), reproduces it on the user's server, and walks the domain cut-over with a
  rollback window. Done when: a fixture Next.js app on Vercel moves with its env and the old
  deployment is still there to switch back to.

## Later

- **R14 Upgrades.** `UPGRADE.md` for the three things that rot: Coolify (dump first, diff the
  release notes against `references/coolify-api.md`, upgrade, `verify.sh`), Ubuntu (updates, reboot
  window), Postgres major versions. `status.sh` says when each is due. Done when: the harness
  upgrades pinned Coolify to `latest` and a Postgres 17 database to 18 with data intact.
- **R15 Rebuild from nothing.** `REBUILD.md`: new server, every database restored from off-site
  backups, DNS repointed, apps redeployed from git. The harness runs it on purpose, quarterly.
  Done when: the rebuilt server passes `verify.sh` and `status.sh` with all data present.
- **R16 Monthly checkup.** `CHECKUP.md`, run by the user's agent on a schedule: open ports vs the
  firewall, sshd config, Docker socket exposure, Coolify advisories, certificate renewals, backup
  success rate, disk growth, and what the servers cost this month. Ends with actions, each with a
  runbook. Done when: it runs on the harness server with no false positives on a clean setup.
- **R17 Second server and moving an app.** Add a server to the same Coolify (a bigger box, or a
  client's own account) and move an app with its database with a short downtime window.
  Done when: the harness moves the starter between two servers and the form data survives.
- **R18 DNS through the API.** Cloudflare first, then the providers users ask for: the agent
  creates the records and the `dig` gate becomes a formality. Done when: a harness run on a
  Cloudflare-managed test domain needs no DNS click.
- **R19 Agent packaging.** A Claude Code plugin (`/vps-setup`, `/vps-status`, `/vps-doctor`) and
  parity for Codex and Cursor through `AGENTS.md`; the markdown stays the source, a test diffs the
  two. Done when: the harness passes through the plugin and through plain markdown.
- **R20 Providers beyond Hetzner.** `PROVIDER=other` becomes first-class: the generic path (an
  Ubuntu box with your key) tested in the harness on one more provider; provider-specific firewall
  and backup steps only on request. Done when: the harness is green on Hetzner and one other.

## Ideas

- **R21 Preview deployment per pull request**, if Coolify's GitHub App source becomes drivable
  without the UI.
- **R22 A status page per client**, from the Uptime Kuma pages in R06, with the client's domain.
- **R23 Secrets vault on the user's machine** (`age` or `sops`) with a rotation runbook.
- **R24 Starter variants:** the same plumbing with auth and transactional mail; a cron-and-queue
  worker example as a second app from the same repo.
- **R25 Windows through WSL**, tested in the harness driver.
- **R26 Cost forecast before anything is created:** what this setup will cost per month, with the
  provider's current price list.

## Done

- **2026-10-11** Existing Hetzner server variant (phase 01): pick a server you already have,
  attach the cloud firewall, continue as usual.
- **2026-10-11** Landing in English and Polish, optional Brevo double opt-in, consent, rate limit.
- **2026-10-09** Phase 05 proven on Coolify 4.3.23: private repo, Postgres 17, deploy key, webhook,
  push-to-deploy; the landing runs on the setup it describes.
