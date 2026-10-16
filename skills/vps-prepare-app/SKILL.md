---
name: vps-prepare-app
description: Follow PREPARE-APP.md to move the existing app in the current directory onto the user's Coolify server. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/PREPARE-APP.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

The current directory is the app's repo: stay in it. Read the file, then follow it exactly, in the user's language, with `SETUP_DIR` set to `${CLAUDE_PLUGIN_ROOT}`.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
