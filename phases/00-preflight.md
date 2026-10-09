# 00 Preflight

**Done when** `./verify.sh` shows all `00 preflight` checks green: tools installed, `gh` logged
in, an SSH key exists, and PROVIDER, DOMAIN, COOLIFY_DOMAIN, APP_DOMAIN, APP_NAME are recorded.

Tell the user: "First I'll check your machine and ask a few questions once, so the rest runs
without interruptions."

## 1. Tools

Check: `for t in ssh git gh jq curl dig openssl hcloud; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done`

Install what is missing with the user's package manager (ask before installing):

| Tool | macOS (Homebrew) | Debian/Ubuntu |
|------|------------------|---------------|
| gh | `brew install gh` | `sudo apt install gh` |
| jq | `brew install jq` | `sudo apt install jq` |
| dig | `brew install bind` | `sudo apt install dnsutils` |
| hcloud | `brew install hcloud` | `brew install hcloud` if Homebrew is installed, otherwise the `hcloud-linux-amd64.tar.gz` (or `arm64`) binary from github.com/hetznercloud/cli/releases into `~/.local/bin` |

`hcloud` is only needed on the Hetzner path. Windows users: run everything inside WSL2 (Ubuntu).

## 2. GitHub CLI login

`gh auth status`. If not logged in, the user runs in their own terminal: `gh auth login`
(GitHub.com, HTTPS, login with a web browser). Afterwards `gh auth status` shows
"Logged in to github.com account <name>" and the token scopes include `repo`.

## 3. SSH key

`ls ~/.ssh/id_*.pub`. If nothing: `ssh-keygen -t ed25519 -C "<their email>"` in their own
terminal (a passphrase is good; then make sure `ssh-add` has loaded the key, because your shell
cannot type the passphrase). If there are several keys, ask which one to use.

Always record the key and this repo's location (the absolute path, used later in summaries):

```
. ./lib.sh; state_set SSH_PUBKEY "$HOME/.ssh/id_ed25519.pub"; state_set SETUP_DIR "$PWD"
```

## 4. Questions (ask one at a time, record each with `state_set`)

1. **Provider.** "Hetzner (I'll create the server for you) or another provider (you create an
   Ubuntu 24.04 server with your SSH key and give me the IP)?" → `PROVIDER=hetzner|other`.
   For Hetzner, warn now: a brand new Hetzner account can require identity verification that
   takes hours. If they have no account yet, they should create it at console.hetzner.com now.
2. **Domain.** "Which domain do you control?" → `DOMAIN=example.com`. They need access to its
   DNS settings. No domain yet: they should buy one first (any registrar); stop here until they do.
3. **Hostnames.** Propose `COOLIFY_DOMAIN=coolify.<domain>` and `APP_DOMAIN=<domain>` (or
   `app.<domain>` if the apex is already in use). Confirm both.
4. **App name.** Lowercase, dashes only, used for the GitHub repo and Coolify resources.
   Default `my-landing` → `APP_NAME`.
5. **Hetzner only: location.** "Europe or US?" Suggest `fsn1` (Falkenstein), `nbg1` (Nuremberg)
   or `hel1` (Helsinki) for Europe, `ash` (Ashburn) or `hil` (Hillsboro) for the US
   → `HCLOUD_LOCATION`. Phase 01 checks it is valid once `hcloud` is logged in.

Example: `. ./lib.sh; state_set PROVIDER hetzner; state_set DOMAIN example.com`

## 5. Existing Coolify config

If `~/.config/coolify/config` already exists, the user has another Coolify instance. Ask before
touching it. On yes: `mv ~/.config/coolify/config ~/.config/coolify/config.bak-$(date +%F)` in
phase 04, and tell them where the backup is.

## 6. Cost and time, said plainly

"A 4 GB VPS costs about 5-10 EUR per month, billed by the hour; you can delete it any time and
billing stops. This takes about an hour, mostly waiting for installs and DNS."

Run `./verify.sh`.
