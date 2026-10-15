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
- Nothing is called working without a run on a real, fresh server; until then the README Status says so.
- Runbooks plus a thin, tested shell layer. Where Coolify has the feature (backups,
  notifications, rollback, services), we drive it through its API; we never rebuild it.
- Secrets stay on the user's machine or their server. Never in the chat, never in the repo.
- One way to do each thing. A second option is added only for a user with a concrete case.

## Now

- **R02 The first full run, recorded.** One manual end-to-end run of phases 01–06 on a fresh small
  Hetzner server (CX22-class), recorded. The real `[verify]` notes settled: the domain lockout in
  `PLAN.md` and Postgres 18 in `references/coolify-api.md`. Results written into the README "Status".
  Done when: README Status says phases 01–06 ran end-to-end on <Coolify version>, the two `[verify]`
  notes are settled, the landing links the recording.
- **R01 Staged test harness.** On every PR, the checks that need no server: `test/lib.test.sh`,
  shellcheck, and `bash -n` on the shell blocks extracted from `phases/`. A full run on a throwaway
  server only on demand (`workflow_dispatch` or a label) and before releases. A fully unattended run
  needs the Coolify admin registration and API token steps automated, and per-run hostnames because
  of Let's Encrypt rate limits; that part depends on R18.
  Done when: the PR checks run on every PR and one on-demand full run went green.
  PR checks are live (ci.yml); the full run is still to build.
- **R04 Off-site backups and a restore drill.** Coolify database backups to any S3-compatible
  storage (Hetzner Object Storage first), set up in phase 06. `RESTORE.md` restores one database
  from a chosen backup. Done when: the harness backs up, destroys the database, restores, and the
  waitlist row is back; `status.sh` shows off-site backup age.
  (Code and fake-API tests done; not run on a server yet.)
- **R03 `status.sh`: one screen.** Server reachable, disk and memory, pending reboot, Coolify version
  vs latest release, every app with status and last deploy result, days to certificate expiry, last
  backup and whether it succeeded. Non-zero exit when something needs attention.
  Done when: every line is backed by a real check on the harness server and on a production server.
  (Code and fake-API tests done; not run on a server yet.)
- **R06a Alerts that reach a phone.** Coolify's own notifications (app stopped, deploy failed,
  backup failed, server unreachable and back, disk usage, container restart limit) sent to a
  Discord channel, set up in phase 06 from one webhook URL the user pastes into their own
  terminal; `status.sh` says whether a channel is on with those events. Done when: the harness stops the starter container
  and a Discord message arrives within five minutes.
  (Code and fake-API tests done; not run on a server yet.)

## Next

- **R07 Safe deploys.** `deploy_and_wait` dumps the database first and prints the rollback point;
  `ROLLBACK.md` reverts to the previous image and restores the dump if needed; migration guidance
  in `PREPARE-APP.md` (expand, then contract). Done when: the harness deploys a broken commit,
  rolls back, and the app is healthy with its data.
  (Code and fake-API tests done; not run on a server yet.)
- **R05 `DOCTOR.md`: "my app is down".** From a symptom (site down, deploy failed, 502, certificate
  error, server unreachable) through `status.sh`, deployment logs, container logs, disk and DNS to
  a fix from `references/` or an honest "this needs a human because X".
  Done when: the five symptoms have harness fixtures that break the server on purpose, and the
  runbook reaches the right fix for each.
  (Runbook done; fixtures not run on a server yet.)
- **R10 `SERVICES.md`: self-host the tools in one prompt.** Umami, n8n, Uptime Kuma and Forgejo
  as Coolify one-click services, each with its own domain, HTTPS, backups and a line in
  `status.sh`. MinIO and Plausible are not one-click on Coolify 4.3.23 and wait for a user with a
  concrete case. Done when: three services deploy in the harness with backups verified.
  (Runbook and helpers done; not run on a server yet.)
- **R06b Uptime checks with a status page.** Uptime Kuma run as a Coolify service, with an uptime
  check per app domain and its public status page. Builds on R10: `SERVICES.md` creates Kuma on
  its own domain (on Coolify 4.3.23 the API sets it, read in the source, not yet seen on a
  server). Done when: the harness stops the starter app, Kuma marks it down, and the status page
  on its own domain shows it.
- **R12 Handover pack.** `HANDOVER.md` produces what a client or colleague needs to take over a
  project or a server: a Coolify team invite with the right role, a scoped token where Coolify
  supports it, `SERVER.md` for that project, DNS and repo ownership steps, and the checklist that
  removes the original developer's access. Done when: a second user, with only the pack, deploys a
  change in the harness.
  (Runbook and read-only helpers done; not run on a server yet.)

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
- **R18 DNS through the API.** Cloudflare first, then the providers users ask for: the agent
  creates the records and the `dig` gate becomes a formality. Done when: a harness run on a
  Cloudflare-managed test domain needs no DNS click.
- **R19 Agent packaging.** A Claude Code plugin (`/vps-setup`, `/vps-status`, `/vps-doctor`) and
  parity for Codex and Cursor through `AGENTS.md`; the markdown stays the source, a test diffs the
  two. Done when: the harness passes through the plugin and through plain markdown.
- **R20 Providers beyond Hetzner.** `PROVIDER=other` becomes first-class: the generic path (an
  Ubuntu box with your key) tested on dedicated servers; provider-specific firewall and backup steps
  only on request. What differs on a dedicated server: the OS is installed through the provider's
  panel or API, the firewall lives on the host instead of in a cloud firewall, and there is
  out-of-band access. Providers to test on, and why:
  - Scaleway Dedibox: critical production with a clear SLA for power and connectivity.
  - OVHcloud Advance: automation, custom images, vRack, Anti-DDoS.
  - Servers.com: demanding recovery (iDRAC, IPKVM, Virtual Media).
  - Worldstream: best published value (ECC, RAID-1, iDRAC, DDoS protection).
  Done when: the generic path is green on one of them in addition to Hetzner.
- **R08 More stacks, by fixture.** Each supported stack gets a sample app in `fixtures/` that the
  harness deploys: static site, Docker Compose stack, Python (FastAPI, Django), Go. A stack without
  a green fixture stays "not supported yet". Done when: three stacks beyond Node are green.
- **R09 Projects and clients.** One Coolify project per client or product, one environment per
  stage, names and domains derived from the project name, `PROJECTS.md` listing what runs where,
  `status.sh` grouped by project. Done when: the harness runs two projects side by side.
- **R11 Staging without a second server.** A `staging` branch deploys to `staging.<app-domain>`
  as a second app with its own database; promotion is a merge to `main`. Done when: the harness
  pushes to `staging`, sees it change, merges, sees production change.

## Ideas

- **R21 Preview deployment per pull request**, if Coolify's GitHub App source becomes drivable
  without the UI.
- **R22 A status page per client**, from the Uptime Kuma pages in R06b, with the client's domain.
- **R23 Secrets vault on the user's machine** (`age` or `sops`) with a rotation runbook.
- **R24 Starter variants:** the same plumbing with auth and transactional mail; a cron-and-queue
  worker example as a second app from the same repo.

## Done

- **2026-10-11** Existing Hetzner server variant (phase 01): pick a server you already have,
  attach the cloud firewall, continue as usual.
- **2026-10-11** Landing in English and Polish, optional Brevo double opt-in, consent, rate limit.
- **2026-10-09** Phase 05 proven on Coolify 4.3.23: private repo, Postgres 17, deploy key, webhook,
  push-to-deploy; the landing runs on the setup it describes.

Retired ids: R13, R17, R25, R26 (cut 2026-10-13 to keep the roadmap focused).
