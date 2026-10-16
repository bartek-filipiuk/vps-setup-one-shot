---
name: vps-setup
description: Guide the user through SETUP.md: a Hetzner or Ubuntu VPS with Coolify and a deployed starter app, about an hour. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/SETUP.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Work from that directory, read the file, then follow it exactly, in the user's language. After a new session or a lost context, start again where it says.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
