# 01 Server

**Done when** `VPS_IP` is recorded, `rssh true` succeeds with the user's key, and the DNS
records have been created (they may still be propagating; phase 04 waits for them).

Tell the user: "Now we create the server and a firewall that only lets in SSH and web traffic.
The Coolify admin panel will never be open to the internet; we'll reach it through an SSH
tunnel until it has its own HTTPS domain."

## Hetzner path (`PROVIDER=hetzner`)

### 1. API token (user, in Hetzner Console)

console.hetzner.com → pick or create a project (e.g. "vps-setup") → left sidebar **Security**
→ tab **API tokens** → **Generate API token** → description `vps-setup`, permission
**Read & Write** → Generate. They should see the token once; it is not shown again.

Then, in their own terminal (it prompts for the token, hidden):

```
hcloud context create vps-setup
```

They should see `Context vps-setup created and activated`. You verify: `hcloud server list`
(prints a header, no error), and that the chosen location exists:
`hcloud location list | grep -w "$(. ./lib.sh; state_get HCLOUD_LOCATION)"`.

### 2. SSH key, firewall, server (you)

```
. ./lib.sh
hcloud ssh-key create --name vps-setup --public-key-from-file "$(state_get SSH_PUBKEY)"
hcloud firewall create --name vps-setup-fw
for p in 22 80 443; do
  hcloud firewall add-rule vps-setup-fw --direction in --protocol tcp --port $p \
    --source-ips 0.0.0.0/0 --source-ips ::/0
done
hcloud firewall add-rule vps-setup-fw --direction in --protocol icmp --source-ips 0.0.0.0/0 --source-ips ::/0
```

If a resource already exists from an earlier attempt, reuse it (check `hcloud ssh-key list`,
`hcloud firewall describe vps-setup-fw`) instead of creating a duplicate.

Why a Hetzner Cloud Firewall and not `ufw`: Docker publishes container ports by writing its own
iptables rules, which bypass `ufw`. The cloud firewall sits in front of the server, so it works.

Pick a server type: at least 2 vCPU and 4 GB RAM (Next.js builds run on the server; 2 GB boxes
run out of memory). Show the user the current options and prices, then let them choose:

```
hcloud server-type list -o json | jq -r --arg loc "$(state_get HCLOUD_LOCATION)" '
  .[] | select(.memory >= 4 and .deprecated != true and .architecture == "x86")
  | [.name, .cores, .memory, (.prices[] | select(.location == $loc) | .price_monthly.gross)] | @tsv'
```

Use x86 unless the user wants ARM (cheaper, works, but rare native modules can fail to build).
Record the choice with `state_set HCLOUD_TYPE <name>` and `state_set SERVER_NAME coolify-1`, then:

```
. ./lib.sh
hcloud server create --name "$(state_get SERVER_NAME)" --type "$(state_get HCLOUD_TYPE)" \
  --image ubuntu-24.04 --location "$(state_get HCLOUD_LOCATION)" \
  --ssh-key vps-setup --firewall vps-setup-fw
state_set VPS_IP "$(hcloud server ip "$(state_get SERVER_NAME)")"
```

## Other provider (`PROVIDER=other`)

Ask the user to create: Ubuntu 24.04, at least 2 vCPU / 4 GB RAM, their SSH public key added
at creation (show them `cat $(state_get SSH_PUBKEY)`), and the provider's **cloud firewall**
allowing inbound TCP 22, 80, 443 only. If the provider has no cloud firewall, say so plainly:
the Coolify panel on port 8000 will be public until phase 04, so the admin account must be
registered immediately after install. Record the IP: `state_set VPS_IP <ip>`.

## 3. Check SSH (you)

```
. ./lib.sh; sleep 20; rssh 'cat /etc/os-release | grep PRETTY; nproc; free -h | grep Mem'
```

Expect Ubuntu 24.04, the core count and RAM they chose. "Host key verification failed" for a
reused IP: `ssh-keygen -R <ip>` and retry.

## 4. DNS now, so it propagates while we work (user)

In their DNS provider, create two **A** records pointing to the VPS IP:

| Name | Type | Value |
|------|------|-------|
| `coolify` (COOLIFY_DOMAIN) | A | VPS_IP |
| `@` or `app` (APP_DOMAIN) | A | VPS_IP |

On Cloudflare: DNS → Records → Add record, and set **Proxy status** to **DNS only** (grey cloud).
The orange cloud breaks certificate issuance. Also delete any existing **AAAA** records for these
two names (registrar parking pages often have one); a stale AAAA makes HTTPS fail for IPv6 users
and can break certificate issuance.

Check (may take minutes): `dig +short A <name> @1.1.1.1` and `dig +short AAAA <name> @1.1.1.1`.
Do not wait here; continue with phase 02.

Run `./verify.sh`.
