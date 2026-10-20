---
name: vps-auth
description: Follow AUTH.md to create a new app with sign-in by email link and transactional mail (from starter-auth/, sessions in Postgres, SMTP from any provider) and deploy it on the user's Coolify server. User-invoked only.
disable-model-invocation: true
---
The runbook is `${CLAUDE_PLUGIN_ROOT}/AUTH.md`. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo and is the repo root the runbook means (its `SETUP_DIR`).

The new app gets its own repo, created by the runbook in the user's home directory. Read the file, then follow it exactly, in the user's language, with `SETUP_DIR` set to `${CLAUDE_PLUGIN_ROOT}`. The SMTP password is typed by the user in their own terminal, never in the chat.

The user's state lives in `~/.config/vps-setup/`, `~/.config/coolify/` and the app's own gitignored state file, never in this directory. Nothing here repeats a step: the runbook is the source.
