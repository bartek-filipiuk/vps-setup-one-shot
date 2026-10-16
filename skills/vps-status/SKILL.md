---
name: vps-status
description: Run status.sh, the read-only one-screen health check of the server, Coolify, apps, certificates, backups and alerts. User-invoked only.
disable-model-invocation: true
---
The script is `${CLAUDE_PLUGIN_ROOT}/status.sh`, read-only. `${CLAUDE_PLUGIN_ROOT}` is a complete copy of the vps-setup-one-shot repo.

Run the script by its full path, show the user its output and exit code (0 all OK, 1 needs attention, 2 server or API unreachable) and explain each WARN or FAIL in plain words. Fixes live in `${CLAUDE_PLUGIN_ROOT}/DOCTOR.md`; change nothing without the user's yes.

The user's state lives in `~/.config/vps-setup/` and `~/.config/coolify/`, never in this directory. Nothing here repeats a step: the script and `DOCTOR.md` are the source.
