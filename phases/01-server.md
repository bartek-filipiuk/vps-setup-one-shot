# 01 Server

**Done when** `VPS_IP` is recorded, `rssh true` succeeds with the user's key, and the DNS
records have been created (they may still be propagating; phase 04 waits for them).

Tell the user: "Now we create the server and a firewall that only lets in SSH and web traffic.
The Coolify admin panel will never be open to the internet; we'll reach it through an SSH
tunnel until it has its own HTTPS domain." (On `PROVIDER=other` the server already exists and
the firewall comes in phase 02 step 4, on the server itself.)

## Hetzner path (`PROVIDER=hetzner`)

Two variants share step 1: a new server (steps 2 and onward) or a server the user already has
(skip to "Existing Hetzner server" below).

### 1. API token (user, in Hetzner Console)

console.hetzner.com → pick the project that holds the server (or create one, e.g. "vps-setup") → left sidebar **Security**
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

## Existing Hetzner server (`PROVIDER=hetzner`, `SERVER_EXISTS=1`)

The token from step 1 must belong to the project that contains the server. List it and let the
user confirm which one:

```
hcloud server list -o columns=name,status,type,ipv4,datacenter
```

```
. ./lib.sh; N="<name-from-the-list>"; state_set SERVER_NAME "$N"; state_set VPS_IP "$(hcloud server ip "$N")"
hcloud server describe "$N" -o json | jq -r '"image: \(.image.description // .image.name)  type: \(.server_type.name)  ram: \(.server_type.memory) GB"'
```

Expect Ubuntu 24.04 and at least 4 GB RAM. Another image or less memory: stop and tell the user
why (phase 02 and 03 assume a fresh 24.04 box; builds need the memory). The SSH key must be the
one the server was created with; if `rssh true` fails in step 3 below, the user adds their key
through the Hetzner Console (server → **Rescue** → reset root password → **Console** →
`echo "<pubkey>" >> /root/.ssh/authorized_keys`).

Firewall: create it exactly as in step 2 (reuse `vps-setup-fw` if it exists), then attach it to
the running server:

```
hcloud firewall apply-to-resource vps-setup-fw --type server --server "$N" && hcloud firewall describe vps-setup-fw | grep -A3 -i 'applied to'
```

Expect the server listed under "Applied To". From that moment only 22, 80, 443 and ICMP reach
the server; anything else that was running on it is cut off, which is the point on a fresh box.
Then continue with step 3 (SSH check) and step 4 (DNS).

## Other provider (`PROVIDER=other`): check the box the user installed

Dedicated servers and most non-Hetzner VPSs: the user installs the OS in the provider's panel
(or through its API) and gives you the IP. Nothing here creates or buys a server.
`references/providers.md` has the panel paths, rescue and out-of-band console per provider.

### 1. In the provider's panel (user)

Tell them what to pick when they install (or reinstall) the server:

- **Ubuntu 24.04 LTS**, the plain server image.
- **Their SSH public key** added at install (show them `cat "$(. ./lib.sh; state_get SSH_PUBKEY)"`).
- At least 2 cores and 4 GB RAM.
- **Disks:** one `/` partition with at least 40 GB free, on software RAID-1 when the server has
  two disks. No small separate `/` with everything in `/home`: Docker lives in `/var/lib/docker`
  and Coolify in `/data`.
- A public IPv4 address (IPv6 is fine as well; the DNS records stay A only).
- Before going on: where the provider's **rescue system and out-of-band console** are
  (providers.md). That is the way back in if SSH ever locks out (phase 02).

A reinstall wipes the disks; the provider's panel says so.

### 2. Root access with the key (you)

Record the IP: `. ./lib.sh; state_set VPS_IP <ip>`. Then try root with the key:
`. ./lib.sh; rssh true && echo root-ok`.

If that fails because the provider's image logs in as another user (the panel or its email
says which; OVHcloud and Scaleway images often use a named user **[verify]**), copy that user's
key to root once. `<user>` is the login the provider gave; the user runs it in their own
terminal if `sudo` asks for a password:

```
. ./lib.sh; U="<user>"
ssh -o StrictHostKeyChecking=accept-new "$U@$(state_get VPS_IP)" 'sudo install -d -m 700 /root/.ssh && sudo install -m 600 ~/.ssh/authorized_keys /root/.ssh/authorized_keys'
rssh true && echo root-ok
```

This replaces root's `authorized_keys` (cloud images may put a `command="Please login as ..."`
line there that refuses root **[verify]**). Phase 02 keeps root by key only, which Coolify needs.

### 3. Check the box (you)

```
. ./lib.sh; server_check
```

Expect `OK` lines for `os` (Ubuntu 24.04), `cpu`, `memory`, `disk /`, `network` (the IP on the
interface of the default route, which phase 02 step 4 guards), `machine` (`none` is bare
metal) and `sshd port`. A `FAIL` stops here: tell the user which one and why (reinstall with
another image or layout in the panel, or a bigger server). `WARN network` (the IP is not on the
interface, so the box sits behind NAT): ask the user whether the provider maps the public IP
to this box; the firewall still guards the default route's interface.

Then step 3 below (SSH) and step 4 (DNS). Until phase 02 step 4 the box has no firewall; nothing
listens on it but SSH yet, and Coolify comes only after the firewall (phase 03).

## 3. Check SSH (you)

```
. ./lib.sh; sleep 20; rssh 'cat /etc/os-release | grep PRETTY; nproc; free -h | grep Mem'
```

Expect Ubuntu 24.04, the core count and RAM they chose. "Host key verification failed" for a
reused IP: `ssh-keygen -R <ip>` and retry.

## 4. DNS now, so it propagates while we work

### `DNS_PROVIDER=cloudflare` (you)

```
. ./lib.sh; IP=$(state_get VPS_IP)
for h in "$(state_get COOLIFY_DOMAIN)" "$(state_get APP_DOMAIN)"; do dns_set_a "$h" "$IP"; echo "exit $?"; done
```

Each name prints `A created -> <ip>`, `A unchanged` or `A updated <old> -> <ip>`, always DNS only
(grey cloud), and `exit 0`. Running it again changes nothing. It never deletes a record:

- `exit 1` with `is a CNAME` or `has 2 A records`: nothing changed. Show the user the message;
  they delete the record that should not be there in Cloudflare (DNS → Records), then run it again.
- `exit 2` with `also has an AAAA record`: the A record is right, the AAAA must go (see below).
  The user deletes it in Cloudflare (DNS → Records).
- `Cloudflare rate limit (HTTP 429 ...)`: wait five minutes, run it again.

### Any other DNS provider (user)

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
