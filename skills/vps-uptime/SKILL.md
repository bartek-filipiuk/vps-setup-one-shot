---
name: vps-uptime
description: Follow UPTIME.md to set up Uptime Kuma with a check per app domain and a public status page per project, also on a client's domain, and to read it. User-invoked only.
argument-hint: "[project name, optional]"
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/UPTIME.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Change into it once (`cd "${CLAUDE_PLUGIN_ROOT}"`; `/add-dir` it if Claude Code asks), then run the runbook's commands as written.

The project the user asked for, if given: $ARGUMENTS. Read the file, then follow it exactly, in the user's language.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
