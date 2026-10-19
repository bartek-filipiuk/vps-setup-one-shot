# VAULT: the setup's secrets in one encrypted file, back on a new machine, rotated

You are an AI coding agent helping a user keep the secrets of their vps-setup-one-shot setup
safe on their own machine: one `age`-encrypted copy of the files this guide writes, a way back
on a new machine, and the steps that change one secret without breaking the server. Work from
the repo root; every command starts with `. ./lib.sh`. Rules from `SETUP.md` apply.

**The user runs `vault_export` and `vault_import` in their own terminal, never you.** `age` asks
for the passphrase on the terminal itself and has no flag or variable for it, so the passphrase
never goes through the chat, a command line or this repo, and you never see what is in the file.
Run in your shell, both say `age reads the passphrase from the terminal only` and change nothing.
You may run `vault_check` (it reads a list of paths and the file's first two lines, never decrypts).

**Not run on a real server yet.** `vault_export`, `vault_import` and `vault_check` are tested
against a fake `age` (`test/lib.test.sh`, `test/checkup.test.sh`), and `test/vault-roundtrip.sh`
runs a round trip with the real `age` under a pseudo-terminal (`script`): run locally with age
1.2.1; CI installs Ubuntu's `age` for it. No machine has been restored with it for real, and no
step of the rotation part (step 6) has been run on a server; the UI paths in it are marked
**[verify]**.

## 0. What it covers, and what not

The secrets this guide keeps on the user's machine, each `0600`, read with `grep`, never on a
command line:

| File | Holds | Written by |
|------|-------|------------|
| `~/.config/coolify/config` | the Coolify API token (root: the whole server) | phase 04 step 3 |
| `~/.config/vps-setup/s3.env` | the S3 key pair of the backup bucket | phase 06 step 1a |
| `~/.config/vps-setup/notify.env` | the Discord webhook URL | phase 06 step 2a |
| `~/.config/vps-setup/cloudflare.env` | the Cloudflare DNS token | phase 00 step 4a |
| `~/.config/vps-setup/kuma.env` | the Uptime Kuma admin login | `UPTIME.md` step 3 |
| `~/.config/hcloud/cli.toml` | the Hetzner API token (the `vps-setup` context) **[verify]** the path; macOS may keep it in `~/Library/Application Support/hcloud/`, then set `HCLOUD_CONFIG` to it, as `hcloud` itself reads it | phase 01 step 1 |
| `~/.ssh/<key>` and `<key>.pub` (`state_get SSH_PUBKEY`) | root on the server | phase 00 step 3 |

Next to them, without secrets: the state, `SERVER.md`, `PROJECTS.md`, `handover/`, the checkup
log and the `*.before-rebuild-*` copies. The vault holds all of these.

Covered: a lost, stolen or sold laptop; a cloud or Time Machine backup of the home directory
that leaks (the copy of `~/.config` in it is plaintext; the vault file is not); a new machine
(the whole setup back from one file and one passphrase); "which copy of the token is the
current one" after a rotation.

Not covered: malware or anyone working as the user while the files are on the disk (they read
`~/.config` directly; nothing that runs as the same user can stop that); a compromised server
(it holds the database passwords and Coolify's own keys); the agent (it never sees the
plaintext, before or after this file). Full-disk encryption (FileVault, BitLocker, LUKS) stays
the first line; the vault is the copy off the machine and the way back.

The vault is not a password manager and not the server's backups: the databases are in the S3
bucket (phase 06 step 1), the apps in git. Secrets that live only on the server (database
passwords, the GitHub webhook secret, the deploy keys' private halves, app environment values,
Coolify's `APP_KEY`) are not in it; `REBUILD.md` says what happens to them.

Not included, on purpose: `sops` (made for many people editing structured files in git; here it
is one user and a few flat files), age identity files (the key would need its own off-site copy,
and it would sit next to the data), encrypting the files in place (every helper would have to
decrypt, and the agent has no terminal), password manager CLIs. One way: `age` with a passphrase.

## 1. Install age (you, with the user's yes)

Check: `command -v age && age --version` (1.0 or newer).

| macOS (Homebrew) | Debian/Ubuntu, and Windows with WSL | Windows without WSL |
|------------------|-------------------------------------|---------------------|
| `brew install age` | `sudo apt install age` | `winget install FiloSottile.age` |

Nothing else is needed: `tar` is on every machine this guide supports.

## 2. Export (the user, in their own terminal)

Before: tell the user what goes into the file (the table in step 0) and that it holds the ssh
key and the API tokens, so the file and the passphrase are kept apart. Then they run, in their
own terminal, in this repo:

```
. ./lib.sh; vault_export
```

It prints the list of files, then `age` asks twice for a new passphrase. An empty answer makes
`age` generate a strong one and print it on the terminal. Expect
`wrote ~/vps-setup-vault-<YYYYMMDD>.age (mode 600, ... bytes) and ~/.config/vps-setup/vault.manifest (no secrets).`
An app moved in with `PREPARE-APP.md` has a `.coolify.env` (UUIDs only, but `REBUILD.md` step 7
needs it); add each one after the file name:
`vault_export ~/vps-setup-vault-<YYYYMMDD>.age ~/code/shop/.coolify.env`. The output name must
end in `.age`; an existing file is never overwritten.

Then the user, not you:

1. puts the passphrase into their password manager;
2. puts a copy of the file off this machine: as an attachment in the password manager, on
   another computer, on a USB stick. It is a few KB. A copy only on this disk protects against a
   leaked backup and nothing else.

You check (read only):

```
. ./lib.sh; vault_check
```

Expect `<N> files, exported <date> (0 days ago); ... here, age with a passphrase` and exit 0.
When the file is moved off the machine, it says `is not on this machine (fine when it is off it)`.

What `vault_export` can say:

- `age is not installed`: step 1.
- `vault_export failed; nothing written. Run it in your own terminal ...`: it was run without a
  terminal (your shell, a script), or the two passphrases differed (`age` says so above).
- `... exists already; nothing changed`: a second export the same day; it prints a name to use.
- `vault_paths: ... is outside your home directory`: the vault holds files under `$HOME` only.

## 3. When to export again

The vault is a copy at one moment. Export again, with step 2, after anything that writes one of
the files in step 0: phase 00 step 4a, phase 01 step 1, phase 04 step 3, phase 06 steps 1a and
2a, `UPTIME.md` step 3, `REBUILD.md` (new token), `HANDOVER.md` (new keys) and every rotation in
step 6. Then delete the older copies wherever they are: an old file with an old passphrase still
opens.

`vault_check` (and the monthly `checkup.sh`, line `vault`) says `stale` when a file with a
secret changed after the export or is not in it:
`stale, changed since: .config/vps-setup/s3.env; stale, not in it: .config/vps-setup/cloudflare.env`.
The state, `SERVER.md` and `PROJECTS.md` change on every deploy and hold no secret; they do not
make it stale. Their newest version is in the next export.

## 4. Restore on a new machine (the user, in their own terminal)

On the new machine: `git`, `age` (step 1) and the repo:

```
git clone https://github.com/bartek-filipiuk/vps-setup-one-shot.git
```

and every command below runs in that folder.

The vault file is copied there from where it was kept (step 2). Then, in their own terminal:

```
. ./lib.sh; vault_import ~/Downloads/vps-setup-vault-<YYYYMMDD>.age
```

`age` asks for the passphrase. It never overwrites: when a file of the vault exists already
(often `~/.ssh/id_ed25519` from another key), it lists them, changes nothing, and the user moves
them aside first (`mv FILE FILE.before-import`). It unpacks with directories `700` and files
`600`, writes the manifest and prints what came back. Then:

- `SSH_PUBKEY=... is not on this machine`: the home directory is a different path. Run
  `. ./lib.sh; state_set SSH_PUBKEY "$HOME/.ssh/<name>.pub"`.
- `SETUP_DIR=... is not on this machine`: in the repo, `. ./lib.sh; state_set SETUP_DIR "$PWD"`.
- `gh` is not in the vault: `gh auth login` (phase 00 step 2), and `ssh-add` for a key with a
  passphrase.

Then you:

```
./verify.sh; ./status.sh; echo "status exit $?"
```

Expect `ALL DONE` and `status exit 0`, with no token typed again. Each app's `.coolify.env` came
back to its old path under the home directory; clone the app repos there, or move the file into
the clone.

## 5. Lost the passphrase or the file

Nothing in the vault is irreplaceable while the server runs. Every secret is made again where
it came from, with step 6: a new Coolify token, a new Hetzner token, a new Cloudflare token, a
new S3 pair, a new Discord webhook, a new ssh key (step 6.12 needs a working key or the Hetzner
console). The Kuma password: `UPTIME.md` step 3's reset in the container **[verify]**. Then a new
vault (step 2) with a new passphrase, and the old copies deleted.

When both the server and the vault are gone, `REBUILD.md` from step 0, and every token typed
again.

## 6. Rotate a secret

One secret at a time, each in this order: make the new one, put it where it is used, prove it
works, and only then delete the old one. Stopping halfway leaves the old one working. After each:
step 2 again. Every subsection that touches the server, Coolify, Hetzner, Cloudflare, the
bucket or Discord is **not run yet**.

| Secret | Where it is made | Where it is used | Old one deleted |
|--------|------------------|------------------|-----------------|
| Coolify API token | Coolify UI | `~/.config/coolify/config` | Coolify UI |
| Hetzner API token | Hetzner Console | `hcloud` context | Hetzner Console |
| Cloudflare token | Cloudflare dashboard | `cloudflare.env` | Cloudflare dashboard |
| S3 key pair | Hetzner Console | `s3.env`, Coolify's S3 storage | Hetzner Console |
| Discord webhook | Discord | `notify.env`, Coolify | Discord |
| GitHub webhook secret | `openssl rand` | Coolify apps, the GitHub hook | replaced |
| Deploy key | `ssh-keygen` | Coolify, GitHub | `gh repo deploy-key delete` |
| Kuma admin password | Kuma UI | `kuma.env` | replaced |
| Database password | the user | Postgres, Coolify, the app | replaced |
| Staging basic auth | `openssl rand` | Coolify (the staging app) | replaced |
| App secrets (`AUTH_SECRET`, SMTP) | the app's provider or `openssl rand` | Coolify (the app) | replaced |
| SSH key | `ssh-keygen` | the server, Hetzner | the server, Hetzner |
| Coolify admin password | Coolify UI | the user's password manager | replaced |
| The vault's passphrase | the user | the vault file | old copies deleted |

### 6.1 Coolify API token

There is no API for tokens (`references/coolify-api.md`): the user makes the new one in the UI,
**Keys & Tokens** → **API Tokens** → description `vps-setup`, **root** → **Create**. Phase 04
step 3's command in their own terminal writes it; that command writes `COOLIFY_URL` and
`COOLIFY_TOKEN` only, so move the old file aside first and put the server uuid back:

```
. ./lib.sh; s=$(coolify_get COOLIFY_SERVER_UUID); cp -p ~/.config/coolify/config ~/.config/coolify/config.before-rotation && echo "server uuid: ${s:-none}"
```

After phase 04 step 3's command (the user), if a server uuid was printed:
`printf 'COOLIFY_SERVER_UUID=%s\n' "<UUID>" >> ~/.config/coolify/config`. Then:

```
. ./lib.sh; capi GET /version && ./status.sh >/dev/null; echo "status exit $?"
```

Expect the version and `status exit 0`. Then the user deletes the old token in **Keys &
Tokens** (the older `vps-setup` entry, by its date) **[verify]**, and you remove the copy:
`rm ~/.config/coolify/config.before-rotation`. Not run yet.

### 6.2 Hetzner API token

The user: Hetzner Console → the project → **Security** → **API tokens** → **Generate API token**,
**Read & Write**. `hcloud` has no command that changes a context's token **[verify]**, so the
context is made again; in their own terminal (it asks for the token):

```
hcloud context delete vps-setup && hcloud context create vps-setup
```

Then you: `hcloud server list` shows the server. Then the user deletes the old token in the
Console. Stopping after the delete and before the create leaves `hcloud` with no context:
create it again. Not run yet.

### 6.3 Cloudflare token

The user: **My Profile** → **API Tokens** → the `vps-setup` token → **Roll** (a new value, the old
one stops at once) **[verify]**, or a new **Edit zone DNS** token for the zone as in phase 00
step 4a. Then phase 00 step 4a's command in their own terminal writes it, and you:

```
. ./lib.sh; cf_check
```

Expect `Cloudflare token active; zone ...`. With a new token instead of a roll, the user deletes
the old one in the same list. Not run yet.

### 6.4 S3 key pair

The user: Hetzner Console → **Security** → **S3 credentials** → **Generate credentials**; the
secret is shown once. Phase 06 step 1a's command in their own terminal writes `s3.env`. Then you
point Coolify's storage at the new pair (it updates the existing storage and validates it) and
prove a backup goes up with it:

```
. ./lib.sh; L="<LOCATION>"; s3_storage_create vps-setup-backups "https://$L.your-objectstorage.com" "$(state_get S3_BUCKET)" "$L"
```

```
. ./lib.sh; D=$(state_get DB_UUID); db_backup_now "$D" "$(state_get BACKUP_UUID)" && db_backup_list "$D" | head -3
```

Expect `S3 storage ... valid`, a new `success` run in `db_backup_list` (S3 state `uploaded`, or
`unreported` where the API does not say; then `RESTORE.md` step 3 proves the upload) and
`./status.sh` with no new `off-site` warning. Only then the user deletes the old pair in the Console. An app's database with its own
schedule (`PREPARE-APP.md`) uses the same storage; the backup-now with its `VPS_STATE` proves it.
Not run yet.

### 6.5 Discord webhook URL

The user: Discord → the channel → **Edit Channel** → **Integrations** → **Webhooks** → **New
Webhook**, **Copy Webhook URL**. Phase 06 step 2a's command in their own terminal writes
`notify.env`. Then you:

```
. ./lib.sh; notify_setup discord && notify_status
```

Then the test message from the Coolify UI (phase 06 step 2b) arrives in the channel. Only then
the user deletes the old webhook in Discord. Not run yet.

### 6.6 GitHub webhook secret

It lives in Coolify and in the GitHub hook only, never on this machine. `HANDOVER.md` step 3 has
the rotation for one app; with a staging app (`STAGING_APP_UUID`), `STAGING.md` step 9's block
puts one new value on every app of the repo and the hook. `apps_webhook_secret` says which apps
already have the new value when one refuses; the block's text says how to finish. Prove it with
the test push of phase 05 step 6 (`200`, a deployment `finished`). Not run yet.

### 6.7 Deploy key

Its private half exists only in Coolify. A new one: phase 05 step 2's block (a new key on GitHub
titled `coolify` and in Coolify, `KEY_UUID` recorded); keep the old key's uuid first
(`state_get KEY_UUID`). Then the app uses the new key:

```
. ./lib.sh; capi PATCH "/applications/$(state_get APP_UUID)" "$(jq -n --arg k "$(state_get KEY_UUID)" '{private_key_uuid:$k}')" >/dev/null && echo "app uses key $(state_get KEY_UUID)"
```

The field name is from the 4.3.23 API reference **[verify]**. Deploy (`deploy_and_wait`, phase
05 step 5) and expect `finished`: the clone used the new key. Then the old key goes from GitHub
(`gh repo deploy-key list --repo "$(state_get GH_REPO)"`, the older `coolify` entry,
`gh repo deploy-key delete <ID> --repo ...`) and from Coolify
(`capi DELETE "/security/keys/<OLD KEY_UUID>"`). The same for each `PREPARE-APP.md` app in its
repo with its `VPS_STATE`. Not run yet.

### 6.8 Kuma admin password

The user changes it in Kuma: **Settings** → **Security** → **Change Password** **[verify]**, with
a new random value (`openssl rand -base64 24` in their own terminal), then writes the same value
into the `KUMA_PASSWORD=` line of `~/.config/vps-setup/kuma.env` with an editor in their own
terminal (`kuma_env_init` refuses an existing file on purpose). Then you: `kuma_sync` logs in
with `kuma.env` (it matches the checks by URL and deletes nothing); a login error means the
file and Kuma disagree. Not run yet.

### 6.9 Database password

Needs a human, as in `HANDOVER.md` step 5: the change in Postgres (`\password app` over
`ssh -t`), the same value in Coolify (the database's **Configuration**, the app's
`DATABASE_URL`) and a redeploy **[verify]**. Between the first and the last step the app cannot
connect. Not run yet.

### 6.10 Staging basic auth

`STAGING.md` step 6, in the user's own terminal: a new value replaces the old one. Not run yet.

### 6.11 App secrets

A value from a provider (SMTP, an API key): the new one is made there first, then, in the user's
own terminal, with the value on stdin (`read -rs` keeps it off the screen and the command line):

```
. ./lib.sh; printf 'value: ' && read -rs V && echo && printf '%s' "$V" | app_env_set "$(state_get APP_UUID)" "<KEY>" && unset V
```

Then a redeploy (`deploy_and_wait`) and the old value revoked at the provider. A generated
session secret (`AUTH_SECRET`): a new value logs every user out; if the app can take two
(the old one for reading), expand first and contract later, as `PREPARE-APP.md` step 3 says for
migrations. Data encrypted with the old value cannot be read with the new one: stop and tell the
user. Not run yet.

### 6.12 SSH key

`HANDOVER.md` 6.2, with the user as both sides: the new key added, proven from a new connection,
then the old one removed (the command there refuses unless both are present), and Coolify's
own key never touched. Then `state_set SSH_PUBKEY "$HOME/.ssh/<new>.pub"` and in Hetzner, for
servers made later, `hcloud ssh-key delete vps-setup` and
`hcloud ssh-key create --name vps-setup --public-key-from-file "$(state_get SSH_PUBKEY)"`.
Not run yet.

### 6.13 Coolify admin password

The user, in Coolify: **Profile** → **Password** **[verify]**, the value from their password
manager. Not in the vault. Not run yet.

### 6.14 The vault's passphrase

Step 2 again with a new passphrase (a new file name or the old file moved away first), then the
old files deleted everywhere they were copied. The old passphrase still opens every old copy.

## 7. Done when

The R23 criterion, on the test harness (`ROADMAP.md`): `vault_export` on machine A,
`vault_import` on a clean machine B, then `./verify.sh` prints `ALL DONE` and `./status.sh`
exits 0 on B with no secret typed again; and one rotation, the S3 pair (step 6.4), done end to
end with the backups still green. Not run yet.
