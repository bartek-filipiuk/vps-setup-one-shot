---
name: vps-rollback
description: Follow ROLLBACK.md to go back to the previous version of an app after a bad deploy. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/ROLLBACK.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Change into it once (`cd "${CLAUDE_PLUGIN_ROOT}"`; `/add-dir` it if Claude Code asks), then run the runbook's commands as written.

Read the file, then follow it exactly, in the user's language; nothing changes without the user's yes.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
