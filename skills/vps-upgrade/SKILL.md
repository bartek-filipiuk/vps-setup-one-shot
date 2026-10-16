---
name: vps-upgrade
description: Follow UPGRADE.md to upgrade Coolify, Ubuntu or a Postgres major version, each with a backup first and a check after. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/UPGRADE.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Read the file, then follow it exactly, in the user's language; nothing changes without the user's yes.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
