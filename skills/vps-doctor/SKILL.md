---
name: vps-doctor
description: Follow DOCTOR.md when the user's app is down, a deploy failed, the browser shows 502 or a certificate error, or the server does not answer. User-invoked only.
argument-hint: "[symptom]"
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/DOCTOR.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

The user's symptom, if given: $ARGUMENTS. Read the file, then follow it exactly, in the user's language; nothing changes without the user's yes.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the runbook is the source.
