# 06 Handover

**Done when** the user has decided on backups (both options below explained, their choice
applied) and on alerts (Discord set up, or declined), `~/.config/vps-setup/SERVER.md` exists,
and `HANDOVER_DONE=1` is recorded.

Tell the user: "It works. Last part: backups, alerts on your phone, a one-page summary of your
server, and how to deploy your next app."

## 1. Backups (user decides, you apply)

Say this plainly: right now nothing is backed up. Two options, they can pick both:

1. **Database backups to S3 storage, off the server** (Hetzner Object Storage: a flat monthly
   price with storage included, check the current price in the Console before they decide
   **[verify]**). Coolify dumps the database daily, keeps 7 on the server and copies each
   to the bucket, where 30 are kept. That survives a lost server. `RESTORE.md` brings a copy back.
2. **Hetzner server backups** (Hetzner only, adds 20% to the server price). Daily snapshots of
   the whole disk, stored by Hetzner outside the server, 7 kept. You enable it after a yes:
   `. ./lib.sh; hcloud server enable-backup "$(state_get SERVER_NAME)"`.

Option 1 only with the user's yes to the cost; it is their account and their money.

### 1a. Bucket and S3 credentials (user, in the Hetzner Console)

The wording of the Console may differ **[verify]**:

1. https://console.hetzner.com → their project → **Object Storage** → **Create Bucket**.
   Location: the one closest to the server (`fsn1`, `nbg1` or `hel1`), a name like
   `<APP_NAME>-backups` (bucket names are global, add a suffix if it is taken), visibility
   **private**. They tell you the location and the bucket name (not secret).
2. **Security** (project menu) → **S3 credentials** → **Generate credentials**, description
   `vps-setup`. The access key and the secret key are shown once.
3. In their own terminal (it prompts for both keys, hidden; paste each and Enter):

```
( mkdir -p ~/.config/vps-setup && umask 077 && printf 'S3 access key: ' && read -rs K && echo &&
printf 'S3 secret key: ' && read -rs S && echo &&
printf 'S3_KEY=%s\nS3_SECRET=%s\n' "$K" "$S" > ~/.config/vps-setup/s3.env && chmod 600 ~/.config/vps-setup/s3.env && echo saved )
```

The keys never go into the chat. The file stays after setup: a restore reads it to download a
backup (`RESTORE.md`). If they rotate the keys in the Console, they run this command again and
you run step 1b again.

### 1b. Connect Coolify to the bucket and run the first backup (you)

Put the location and the bucket name into the command before you run it:

```
. ./lib.sh; L="<LOCATION>"; B="<BUCKET>"
s3_storage_create vps-setup-backups "https://$L.your-objectstorage.com" "$B" "$L" && state_set S3_BUCKET "$B"
```

Expect `S3 storage ... valid`. Then attach it to the database's backup schedule (created if
there is none: daily at 02:00 server time, 7 kept on the server, 30 in the bucket) and run one
backup now:

```
. ./lib.sh; D=$(state_get DB_UUID)
db_backup_attach_s3 "$D" "$(state_get S3_STORAGE_UUID)" && db_backup_now "$D" "$(state_get BACKUP_UUID)" && db_backup_list "$D" | head -5
```

Expect the run to end with `success` and `S3: uploaded` (or `S3: no upload error in the
message`, when this Coolify does not report the upload), and the run on top of the list. Show
the user that output. `./status.sh` now has an `off-site` line with the age of the last copy.

If validation fails: the message is Coolify's (wrong key pair, bucket name or location). Fix
the values and run 1b again. If it still fails, the user enters the storage in Coolify:
**Settings** → **S3 Storages** → add, with the endpoint above, the bucket, the location as region
and the same key pair as in `s3.env` **[verify]**; name it `vps-setup-backups`, then:

```
. ./lib.sh; U=$(s3_storage_find vps-setup-backups) && [ -n "$U" ] &&
capi POST "/s3-storages/$U/validate" | jq -e '.valid == true' && state_set S3_STORAGE_UUID "$U"
```

and continue with the attach command above.

Record the choice: `state_set BACKUPS "s3,hetzner"` (or whatever they chose: `s3`, `hetzner`,
or `none`).

## 2. Alerts (user creates a Discord webhook, you apply)

Say this plainly: right now nobody is told when a deploy or a backup fails or the server goes
down. Coolify can post that into a Discord channel, which their phone shows as a notification.
Discord is the one way this guide sets up. If they do not use Discord, record
`. ./lib.sh; state_set ALERTS none` and tell them `./status.sh` will keep a warning on the
`alerts` line; they can add another channel by hand in Coolify (**Notifications**).

### 2a. Discord webhook (user, in Discord)

The wording of Discord may differ **[verify]**:

1. In a server they own (or a new one), pick or create a channel such as `#alerts`.
2. **Server Settings** → **Integrations** → **Webhooks** → **New Webhook**, name it `Coolify`,
   choose that channel → **Copy Webhook URL**.
3. In their own terminal (it prompts for the URL, hidden; paste it and Enter):

```
( mkdir -p ~/.config/vps-setup && umask 077 && printf 'Discord webhook URL: ' && read -rs U && echo &&
printf 'DISCORD_WEBHOOK_URL=%s\n' "$U" > ~/.config/vps-setup/notify.env && chmod 600 ~/.config/vps-setup/notify.env && echo saved )
```

The URL never goes into the chat: anyone who has it can post into their channel. If it leaks,
they delete the webhook in Discord, create a new one, run this command again and you run 2b
again.

### 2b. Turn on Coolify's notifications (you)

```
. ./lib.sh; notify_setup discord
```

This turns on Discord in Coolify with the URL from `notify.env` and these events: app stopped
or restarted (Coolify's "status change"), deployment failed, backup failed, server unreachable
and reachable again, disk usage high, and container restart limit reached. Successful deploys
and backups stay quiet. Expect
`discord: enabled, 7/7 alert events on`; it records `ALERTS=discord`. A `Coolify refused`
message quotes Coolify's reason (usually a mistyped URL): the user runs the 2a command again,
then you run 2b again.

Then the user proves the path to their phone: in Coolify, **Notifications** → **Discord** →
**Send test notification** **[verify]** (the API has no test call). They tell you whether the
message arrived. If not: the webhook was deleted or points to another channel; redo 2a and 2b.

`./status.sh` now has an `alerts` line. The full drill (stop the app's container, an alert
arrives within five minutes) is what the harness run of R06a will prove; it has not been run
on a server yet. Do not stop the user's app to try it.

## 3. SERVER.md (you)

Write a summary the user can keep. No secrets in it.

```
. ./lib.sh; f="$HOME/.config/vps-setup/SERVER.md"; cat > "$f" <<EOF
# My deploy server

- Server: $(state_get SERVER_NAME) at $(state_get VPS_IP) ($(state_get PROVIDER)), SSH: ssh root@$(state_get VPS_IP)
- Coolify: https://$(state_get COOLIFY_DOMAIN) (version $(state_get COOLIFY_VERSION) at setup)
- Starter app: https://$(state_get APP_DOMAIN), repo $(state_get GH_REPO), local copy $(state_get APP_DIR)
- Push-to-deploy: $(state_get WEBHOOK)
- Backups: $(state_get BACKUPS) $(b=$(state_get S3_BUCKET); [ -n "$b" ] && echo "(S3 bucket $b, S3 keys in ~/.config/vps-setup/s3.env, mode 600)")
- Alerts: $(state_get ALERTS) $([ "$(state_get ALERTS)" = discord ] && echo "(Coolify notifications to a Discord webhook, URL in ~/.config/vps-setup/notify.env, mode 600; Coolify UI -> Notifications)")
- Coolify UUIDs: project $(state_get PROJECT_UUID), app $(state_get APP_UUID), database $(state_get DB_UUID)
- API config (contains the token, mode 600): ~/.config/coolify/config
- Setup state: ~/.config/vps-setup/state

## Everyday

- Deploy: git push to main (or Coolify UI -> app -> Deploy)
- Risky deploy (migrations): cd $(state_get SETUP_DIR) && . ./lib.sh && deploy_and_wait $(state_get APP_UUID)  (dumps the database first, prints the rollback point)
- Bad deploy: $(state_get SETUP_DIR)/ROLLBACK.md (previous image via Coolify rollback, dumps in /root/db-dumps/ on the server)
- Restore the database from an off-site backup: $(state_get SETUP_DIR)/RESTORE.md
- App down (site down, deploy failed, 502, certificate error, server unreachable): $(state_get SETUP_DIR)/DOCTOR.md
- Logs: Coolify UI -> app -> Logs
- Health: $(state_get SETUP_DIR)/status.sh (one screen; exit 0 = all OK)
- Alerts: the Discord channel; check the Coolify settings: cd $(state_get SETUP_DIR) && . ./lib.sh && notify_status
- Panel access if the domain breaks: ssh -N -L 8000:localhost:8000 root@$(state_get VPS_IP), then http://localhost:8000

## Deploy another app

In that app's repo, tell your agent: Read $(state_get SETUP_DIR)/PREPARE-APP.md and prepare this app for deployment.

## Tear everything down (billing stops when the server is deleted)

- Hetzner: hcloud server delete $(state_get SERVER_NAME); hcloud firewall delete vps-setup-fw; hcloud ssh-key delete vps-setup
- Hetzner Object Storage (if used): delete the bucket $(state_get S3_BUCKET) and the vps-setup S3 credentials in the Console (billed until then)
- Discord (if used): delete the Coolify webhook (Server Settings -> Integrations -> Webhooks)
- DNS: delete the A records for $(state_get COOLIFY_DOMAIN) and $(state_get APP_DOMAIN)
- GitHub (optional): gh repo delete $(state_get GH_REPO)
EOF
chmod 600 "$f"; echo "written: $f"
```

Show the user the file.

## 4. Close

`. ./lib.sh; state_set HANDOVER_DONE 1`, then `./verify.sh` should print `ALL DONE`.

Finish with three sentences: what they now have, where the summary is, and the one-liner for
their next app:

```text
Read <path-to-vps-setup-one-shot>/PREPARE-APP.md and prepare this app for deployment.
```
