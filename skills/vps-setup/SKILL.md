---
name: vps-setup
description: Guide the user through SETUP.md: a Hetzner or Ubuntu VPS with Coolify and a deployed starter app. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/SETUP.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Under `~/.claude/plugins/cache/` this directory changes with every plugin update: where `SERVER.md` would get this path, write the plugin commands instead (`/vps-status`, `/vps-doctor`, `/vps-rollback`, `/vps-restore`, `/vps-upgrade`).

Work from that directory, read the file, then follow it exactly, in the user's language. After a new session or a lost context, start again where it says.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
