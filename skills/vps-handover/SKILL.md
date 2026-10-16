---
name: vps-handover
description: Follow HANDOVER.md to hand a server or a project to a client, add a colleague, or remove old access. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/HANDOVER.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Change into it once (`cd "${CLAUDE_PLUGIN_ROOT}"`; `/add-dir` it if Claude Code asks), then run the runbook's commands as written. Under `~/.claude/plugins/cache/` this directory changes with every plugin update: where `SERVER.md` would get this path, write the plugin commands instead (`/vps-status`, `/vps-doctor`, `/vps-rollback`, `/vps-restore`, `/vps-upgrade`).

Read the file, then follow it exactly, in the user's language; nothing changes without the user's yes.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
