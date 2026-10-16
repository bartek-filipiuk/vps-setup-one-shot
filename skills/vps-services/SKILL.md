---
name: vps-services
description: Follow SERVICES.md to add a self-hosted tool (analytics, automation, uptime monitor, Git host) as a Coolify one-click service on its own domain. User-invoked only.
argument-hint: "[umami, n8n, uptime-kuma or forgejo]"
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/SERVICES.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

Change into it once (`cd "${CLAUDE_PLUGIN_ROOT}"`; `/add-dir` it if Claude Code asks), then run the runbook's commands as written.

The tool the user asked for, if given: $ARGUMENTS. Read the file, then follow it exactly, in the user's language.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
