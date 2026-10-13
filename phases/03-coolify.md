# 03 Coolify

**Done when** the `coolify` container runs on the server and the user has registered the admin
account (`ADMIN_REGISTERED=1` in state, set only after they confirm they can see the dashboard).

Tell the user: "Now I install Coolify, the open-source panel that builds and runs your apps.
Then you create your admin account through a private SSH tunnel, so nobody else can reach the
panel before it's secured."

## 1. Install (you, 3-10 minutes)

The official install script from coolify.io:

```
. ./lib.sh; rssh 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash' 2>&1 | tail -25
```

Run it with a long timeout. It installs Docker and starts Coolify. Expect the output to end with
a message that Coolify is ready and a URL on port 8000. Then:

```
. ./lib.sh; rssh "docker ps --format '{{.Names}}\t{{.Status}}' | grep coolify"
```

Expect `coolify`, `coolify-db`, `coolify-redis`, `coolify-realtime` (and `coolify-proxy` after the
first proxy start) with status `Up`.

## 2. Tunnel (you)

Coolify's panel listens on 8000, its realtime websocket on 6001 and its terminal on 6002.
The firewall keeps them closed, so forward them over SSH. Check the local ports are free first:

```
for p in 8000 6001 6002; do lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && echo "local $p BUSY"; done
. ./lib.sh; ssh -fN -M -S ~/.config/vps-setup/tunnel.sock -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -L 8000:localhost:8000 -L 6001:localhost:6001 -L 6002:localhost:6002 "root@$(state_get VPS_IP)" \
  >/dev/null 2>&1 && echo tunnel-up
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000
```

The redirects to `/dev/null` matter: without them your tool call waits for the background ssh
and hangs. Expect `tunnel-up` and a 200 or 302. (`lsof` exists on macOS and most Linux; if it
is missing, `ss -ltn | grep ":$p "` does the same on Linux.) If a local port is busy, ask the user what is using it
(often another dev server) and have them stop it; the panel's websocket expects these exact ports.

Other providers without a cloud firewall: skip the tunnel, the user opens `http://<VPS_IP>:8000`
right now. Registration must happen immediately, because the first visitor becomes the admin.

## 3. Register the admin (user)

They open **http://localhost:8000** in their browser. They should see the Coolify registration
page. They fill in name, email and a strong password (from a password manager), and click
**Register**.

An onboarding screen follows. Guide them through it:
- Choose to deploy to **this machine / localhost** (the server Coolify runs on).
- Let it validate the server (a few seconds; Coolify SSHes into its own host as root, which is
  why phase 02 kept key-only root login).
- Skip or finish the remaining onboarding steps; we create the project via the API later.

When they confirm they see the Coolify dashboard: `. ./lib.sh; state_set ADMIN_REGISTERED 1`.

If the onboarding screens differ from this description (Coolify changes its UI between
versions), ask them to describe or screenshot what they see and adapt; the goal is only
"admin exists, localhost server validated".

Keep the tunnel open; phase 04 needs it once more.

Run `./verify.sh`.
