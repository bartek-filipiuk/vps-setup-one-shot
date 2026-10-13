# 04 Domain and API

**Done when** `https://COOLIFY_DOMAIN` serves Coolify with a valid certificate, port 8000 is not
reachable from the internet, the API token works, and `COOLIFY_SERVER_UUID` is saved.

Tell the user: "Now Coolify gets its own HTTPS address, and you create an API token so I can set
up your apps without you clicking through the panel."

## 1. DNS gate (you)

Setting Coolify's domain before DNS points at the server redirects the panel to an address that
does not work yet. So check first:

```
. ./lib.sh; IP=$(state_get VPS_IP)
for h in "$(state_get COOLIFY_DOMAIN)" "$(state_get APP_DOMAIN)"; do
  echo "$h A=$(dig +short A "$h" @1.1.1.1 | tr '\n' ' ') AAAA=$(dig +short AAAA "$h" @1.1.1.1 | tr '\n' ' ') (want A=$IP, no AAAA)"
done
```

Both must show `A=<VPS_IP>` and an empty AAAA. If not, re-check the records with the user
(phase 01, step 4). Typos and the Cloudflare orange cloud are the usual causes. Wait and re-check
every minute; do not continue until both match.

## 2. Instance domain (user, through the tunnel)

The tunnel from phase 03 must be up: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000`
gives 200 or 302. If not (new session, laptop slept), open it again with the `ssh -fN ...` command
from phase 03 step 2.

In the panel at http://localhost:8000: **Settings** (left sidebar) → **Configuration** /
**General** → field **Domain** (Instance's domain) → enter `https://<COOLIFY_DOMAIN>` →
**Save**.

Then you wait for the certificate (Coolify's Traefik proxy requests it from Let's Encrypt):

```
. ./lib.sh; for i in $(seq 1 18); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$(state_get COOLIFY_DOMAIN)" || true)
  echo "try $i: $code"; [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] && break; sleep 10; done
```

Expect 200 or 302 within about three minutes. `000` means no valid certificate yet. If it is still
`000` after three minutes, see "HTTPS" in `references/troubleshooting.md`. Do not keep saving the
domain again: each failed attempt counts against Let's Encrypt's limits.

The user now opens `https://<COOLIFY_DOMAIN>` and logs in. They should see the same dashboard with a
padlock in the address bar, and no "realtime connection lost" warning after a minute. If that
warning stays, see "Coolify install and panel" in `references/troubleshooting.md`. Close the
tunnel through its control socket, so nothing else on the machine is touched:
`. ./lib.sh; ssh -S ~/.config/vps-setup/tunnel.sock -O exit "root@$(state_get VPS_IP)"`.

## 3. API access and token (user)

1. **Settings** → **Advanced** (or **Configuration** → **Advanced**, depending on the version) →
   enable **API Access** if it is off → Save.
2. **Keys & Tokens** (left sidebar) → **API Tokens** → description `vps-setup`, permissions:
   select **root** (full access; it is their own server) → **Create**. The token is shown once.
3. In their own terminal (it prompts for the token, hidden; paste and Enter):

```
mkdir -p ~/.config/coolify && umask 077 && printf 'Coolify API token: ' && read -rs T && echo &&
printf 'COOLIFY_URL=https://%s\nCOOLIFY_TOKEN=%s\n' "<COOLIFY_DOMAIN>" "$T" > ~/.config/coolify/config && unset T && echo saved
```

Replace `<COOLIFY_DOMAIN>` in the command before you give it to them. The command works in bash
and zsh (the macOS default shell). If phase 00 found an
existing config, move it to the backup name first, as agreed there.

## 4. Verify and record (you)

```
. ./lib.sh; test -s "$COOLIFY_CONFIG" && capi GET /version && capi GET /servers | jq -r '.[] | [.uuid, .name, .ip] | @tsv'
```

Expect a version string and one server (usually named `localhost`). Save it:

```
. ./lib.sh; S=$(capi GET /servers | jq -r '.[0].uuid') && [ -n "$S" ] && [ "$S" != null ] &&
( VPS_STATE=$COOLIFY_CONFIG; state_set COOLIFY_SERVER_UUID "$S" ) && echo "server $S saved"
state_set COOLIFY_VERSION "$(capi GET /version | tr -d '"')"
```

Errors: 401 means a wrong or truncated token (redo step 3). A message about the API being
disabled means step 3.1. Compare the version with "Tested with" in `README.md` and tell the user
if it is newer; API details may have changed.

## 5. Port 8000 closed (you)

```
. ./lib.sh; curl -s -o /dev/null --max-time 5 "http://$(state_get VPS_IP):8000" && echo "OPEN - fix firewall" || echo "closed"
```

`OPEN` on a non-Hetzner server: the user adds a rule in their provider's cloud firewall that
allows only 22, 80, 443. `ufw` is not enough, because Docker bypasses it.

Run `./verify.sh`.
