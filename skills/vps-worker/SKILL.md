---
name: vps-worker
description: Follow WORKER.md to add a background worker (scheduled jobs and a job queue in the app's own Postgres) as a second app from the same repo, with no domain, or remove it. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/WORKER.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

For an app set up from its own repo, the current directory is that repo: stay in it. For the starter app from the setup, work from `${CLAUDE_PLUGIN_ROOT}`. Read the file, then follow it exactly, in the user's language, with `SETUP_DIR` set to `${CLAUDE_PLUGIN_ROOT}`.

The user's state lives in `~/.config/vps-setup/`, `~/.config/coolify/` and the app's own gitignored state files, never in this directory. Nothing here repeats a step: the runbook is the source.
