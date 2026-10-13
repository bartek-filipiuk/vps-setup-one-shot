# 06 Handover

**Done when** the user has decided on backups (both options below explained, their choice
applied), `~/.config/vps-setup/SERVER.md` exists, and `HANDOVER_DONE=1` is recorded.

Tell the user: "It works. Last part: backups, a one-page summary of your server, and how to
deploy your next app."

## 1. Backups (user decides, you apply)

Say this plainly: right now nothing is backed up. Two options, they can pick both:

1. **Coolify scheduled database backups** (free). In Coolify: **Projects** → their project →
   **production** → the `<APP_NAME>-db` database → tab **Backups** → add a scheduled backup,
   frequency **daily**, keep 7. They should see the schedule listed and, after the first run,
   an execution with status success. Limitation: the dumps are stored on the same server disk,
   so they protect against a bad migration or an accidental delete, not against losing the server.
   Off-site copies (S3-compatible storage, e.g. Hetzner Object Storage or Cloudflare R2) can be
   added in the same tab later.
2. **Hetzner server backups** (Hetzner only, adds 20% to the server price). Daily snapshots of
   the whole disk, stored by Hetzner outside the server, 7 kept. You enable it after a yes:
   `. ./lib.sh; hcloud server enable-backup "$(state_get SERVER_NAME)"`.

Record the choice: `state_set BACKUPS "coolify-db,hetzner"` (or whatever they chose, or `none`).

## 2. SERVER.md (you)

Write a summary the user can keep. No secrets in it.

```
. ./lib.sh; f="$HOME/.config/vps-setup/SERVER.md"; cat > "$f" <<EOF
# My deploy server

- Server: $(state_get SERVER_NAME) at $(state_get VPS_IP) ($(state_get PROVIDER)), SSH: ssh root@$(state_get VPS_IP)
- Coolify: https://$(state_get COOLIFY_DOMAIN) (version $(state_get COOLIFY_VERSION) at setup)
- Starter app: https://$(state_get APP_DOMAIN), repo $(state_get GH_REPO), local copy $(state_get APP_DIR)
- Push-to-deploy: $(state_get WEBHOOK)
- Backups: $(state_get BACKUPS)
- Coolify UUIDs: project $(state_get PROJECT_UUID), app $(state_get APP_UUID), database $(state_get DB_UUID)
- API config (contains the token, mode 600): ~/.config/coolify/config
- Setup state: ~/.config/vps-setup/state

## Everyday

- Deploy: git push to main (or Coolify UI -> app -> Deploy)
- Logs: Coolify UI -> app -> Logs
- Panel access if the domain breaks: ssh -N -L 8000:localhost:8000 root@$(state_get VPS_IP), then http://localhost:8000

## Deploy another app

In that app's repo, tell your agent: Read $(state_get SETUP_DIR)/PREPARE-APP.md and prepare this app for deployment.

## Tear everything down (billing stops when the server is deleted)

- Hetzner: hcloud server delete $(state_get SERVER_NAME); hcloud firewall delete vps-setup-fw; hcloud ssh-key delete vps-setup
- DNS: delete the A records for $(state_get COOLIFY_DOMAIN) and $(state_get APP_DOMAIN)
- GitHub (optional): gh repo delete $(state_get GH_REPO)
EOF
chmod 600 "$f"; echo "written: $f"
```

Show the user the file.

## 3. Close

`. ./lib.sh; state_set HANDOVER_DONE 1`, then `./verify.sh` should print `ALL DONE`.

Finish with three sentences: what they now have, where the summary is, and the one-liner for
their next app:

```text
Read <path-to-vps-setup-one-shot>/PREPARE-APP.md and prepare this app for deployment.
```
