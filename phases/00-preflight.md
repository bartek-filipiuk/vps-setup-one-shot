# 00 Preflight

**Done when** `./verify.sh` shows all `00 preflight` checks green: tools installed, `gh` logged
in, an SSH key exists, and PROVIDER, DOMAIN, COOLIFY_DOMAIN, APP_DOMAIN, APP_NAME are recorded.
With `DNS_PROVIDER=cloudflare`, `cf_check` also passed (step 4a).

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

`hcloud` is only needed on the Hetzner path. `age` is optional, for `VAULT.md` (the encrypted
copy of this setup's secrets; `brew install age`, `sudo apt install age`); `verify.sh` does not
check it. Windows users: run everything inside WSL2 (Ubuntu).

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

1. **Provider.** Three answers:
   - "Hetzner, create the server for me" → `PROVIDER=hetzner`.
   - "Hetzner, I already have a fresh server" → `PROVIDER=hetzner` and `SERVER_EXISTS=1`.
     Fresh means Ubuntu 24.04 with nothing installed yet; phase 02 and 03 assume that.
   - "Another provider" (a dedicated server or any VPS: they install Ubuntu 24.04 with their SSH
     key through the provider's panel or API and give you the IP; the firewall will live on the
     server itself, phase 02 step 4) → `PROVIDER=other`. `references/providers.md` has what
     differs at Scaleway Dedibox, OVHcloud, Servers.com and Worldstream.
   For Hetzner, warn now: a brand new Hetzner account can require identity verification that
   takes hours. If they have no account yet, they should create it at console.hetzner.com now.
2. **Domain.** "Which domain do you control?" → `DOMAIN=example.com`. They need access to its
   DNS settings. No domain yet: they should buy one first (any registrar); stop here until they do.
3. **Hostnames.** Propose `COOLIFY_DOMAIN=coolify.<domain>` and `APP_DOMAIN=<domain>` (or
   `app.<domain>` if the apex is already in use). Confirm both.
4. **App name.** Lowercase, dashes only, used for the GitHub repo and Coolify resources.
   Default `my-landing` → `APP_NAME`.
5. **Hetzner, new server only: location.** "Europe or US?" Suggest `fsn1` (Falkenstein),
   `nbg1` (Nuremberg) or `hel1` (Helsinki) for Europe, `ash` (Ashburn) or `hil` (Hillsboro)
   for the US → `HCLOUD_LOCATION`. Phase 01 checks it is valid once `hcloud` is logged in.
   Skip when the server already exists.
6. **DNS provider.** "Is the DNS of <DOMAIN> managed at Cloudflare?" (`dig +short NS <DOMAIN>`
   ending in `ns.cloudflare.com` says yes.) Yes, and they want you to create the records →
   `DNS_PROVIDER=cloudflare`, then step 4a. Anything else → `DNS_PROVIDER=other`: they add two
   records by hand in phase 01.

Example: `. ./lib.sh; state_set PROVIDER hetzner; state_set DOMAIN example.com`

### 4a. Cloudflare token (user, then you; only for `DNS_PROVIDER=cloudflare`)

The user creates a token that can edit DNS of this one zone and nothing else:
dash.cloudflare.com → profile icon (top right) → **My Profile** → **API Tokens** → **Create
Token** → template **Edit zone DNS** → **Use template** → under **Zone Resources** keep
`Include` · `Specific zone` and pick the zone of <DOMAIN> → **Continue to summary** → **Create
Token**. Cloudflare shows the token once. They write it into a file in their own terminal:

```
( mkdir -p ~/.config/vps-setup && umask 077 && printf 'Cloudflare API token: ' && read -rs T && echo &&
printf 'CF_API_TOKEN=%s\n' "$T" > ~/.config/vps-setup/cloudflare.env && chmod 600 ~/.config/vps-setup/cloudflare.env && echo saved )
```

The token never goes into the chat. Then you check it and record the zone:

```
. ./lib.sh; cf_check
```

Expect `Cloudflare token active; zone <zone> (<id>), status active`. What else it can say:

- `Invalid API Token`, `token is expired`, `token does not work`: they create a new token and
  run the command above again.
- `no Cloudflare zone for ...`: the token is for another zone, or the domain is not in this
  Cloudflare account. A new token for the right zone, or `DNS_PROVIDER=other`.
- `warning: zone ... is pending`: the domain's name servers are not Cloudflare's yet; records
  made there do not resolve. The user finishes the move at their registrar, or `DNS_PROVIDER=other`.

## 5. Existing Coolify config

If `~/.config/coolify/config` already exists, the user has another Coolify instance. Ask before
touching it. On yes: `mv ~/.config/coolify/config ~/.config/coolify/config.bak-$(date +%F)` in
phase 04, and tell them where the backup is.

## 6. Cost and time, said plainly

"A 4 GB VPS is billed by the hour; I will show you Hetzner's current monthly prices for your
location before creating anything, and you can delete it any time and billing stops. Most of the
time goes to waiting for installs and DNS; the whole run has not been timed end to end yet."

On `PROVIDER=other` with a dedicated server, say instead: "A dedicated server is a monthly
contract, often with a setup fee and a notice period; check both before ordering."

Run `./verify.sh`.
