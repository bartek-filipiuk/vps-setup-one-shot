# 02 Harden

**Done when** `./verify.sh` shows: password SSH login disabled, swap enabled,
unattended-upgrades installed, and on `PROVIDER=other` the host firewall active and persisted.

Tell the user: "Basic hygiene: install updates, turn on automatic security updates, add swap so
builds don't run out of memory, and make sure only your SSH key can log in."

All commands run on the server through `rssh`. Each step is safe to re-run.

## 1. Updates and automatic security updates

```
. ./lib.sh; rssh 'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
O="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
apt-get update -q && apt-get -y -q $O upgrade && apt-get -y -q $O install unattended-upgrades
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
test -f /var/run/reboot-required && echo REBOOT-NEEDED || echo no-reboot'
```

This can take a few minutes. The dpkg options keep existing config files when a package update
ships a new version (otherwise dpkg waits for an answer nobody can give). If it prints `REBOOT-NEEDED`:
`rssh reboot; sleep 60; rssh uptime` (the ssh to `reboot` may report a closed connection; that is expected).

## 2. Swap (4 GB)

```
. ./lib.sh; rssh 'if swapon --show --noheadings | grep -q .; then echo "swap already on"; else
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile &&
{ grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab; }; fi; free -h | grep Swap'
```

## 3. Key-only SSH

Order matters, so nobody gets locked out:

1. Prove key login works in a **fresh** connection: `. ./lib.sh; rssh_fresh 'echo key-login-ok'`.
2. Only then write the drop-in. It is named `00-` because sshd uses the first value it reads,
   and cloud images ship their own `50-cloud-init.conf`.

```
. ./lib.sh; rssh 'cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && systemctl reload ssh && sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "'
```

Expect `passwordauthentication no` and `permitrootlogin without-password`
(that is how sshd prints `prohibit-password`).

Do **not** set `PermitRootLogin no`: Coolify manages the server by SSH-ing into it as root with
its own key. Key-only root login is the secure setting that keeps Coolify working.

3. Prove it again in a fresh connection: `. ./lib.sh; rssh_fresh 'echo still-in'`.
   If that fails, stop. Hetzner users can recover: server → tab **Rescue** → **Reset root
   password** (copy it), then the **Console** button (top right), log in as root and delete
   `/etc/ssh/sshd_config.d/00-hardening.conf`. Other providers: their rescue system or
   out-of-band console (`references/providers.md`), the same file.

## 4. Host firewall (`PROVIDER=other` only; Hetzner has the cloud firewall of phase 01)

Docker publishes container ports with its own iptables rules, which bypass `ufw`; so the
firewall goes into Docker's `DOCKER-USER` chain and into `INPUT`, for IPv4 and IPv6, as a
small script on the server (`vps-hostfw`) with a boot unit. Every rule matches only the public
interface (the default route's), so traffic between containers is never touched, and it lets
in only TCP 22, 80, 443 and ICMP, like the cloud firewall. Tell the user: "Now the firewall on
the server. It is tried for at most five minutes first and removes itself unless I confirm
it, so a mistake cannot lock us out."

Before step 1: `server_check` (phase 01) warns when `ufw` or `nftables.service` is active.
Disable it first, after the user's yes (`rssh 'ufw disable'`, `rssh 'systemctl disable --now
nftables'`): its rules would mix with these, and `ufw`'s never see Docker's ports anyway.

1. Install it (nothing is applied yet):

```
. ./lib.sh; hostfw_install
```

Expect `installed: PORTS="22 80 443" in /etc/vps-hostfw.conf` (plus sshd's port if it is not 22).

2. The trial. It schedules the automatic revert first, then applies the rules:

```
. ./lib.sh; hostfw_apply
```

Expect `trial: in tcp/22 tcp/80 tcp/443 icmp on <iface> (IPv4 and IPv6); reverts at <time> UTC
unless confirmed`. It refuses, and changes nothing, when sshd listens on a port not in the
list, when the default route is unclear (or IPv6 uses another interface), or when Docker runs
its nftables firewall backend (no `DOCKER-USER` there). Show the user the message; do not work
around it.

3. Prove the way in, in **fresh** connections, before the deadline:

```
. ./lib.sh; rssh_fresh 'echo still-in' && hostfw_probe
```

`rssh_fresh` opens a new connection even when the user's ssh config shares one (ControlMaster).
Expect `still-in` and `tcp/22 open (want open)` (sshd's port, read from the server), and
`closed` for 8000, 6001, 6002 and 8080 (nothing listens there yet; phase 04 step 5 proves 8000
again once Coolify runs). From a VPN or a filtered network the probe may say `unknown`, or even
report 22 as `closed`: then only `still-in` counts.

4. Only if step 3 passed, keep it:

```
. ./lib.sh; hostfw_confirm && hostfw_status | tail -n 1
```

Expect `confirmed: ... vps-hostfw.service enabled` and `hostfw short active persisted`.

If step 3 fails, do nothing: the rules remove themselves at the time step 2 printed (five
minutes), and the box is as before. Then `rssh 'echo back'` again and tell the user what failed.
Locked out after that time too: the provider's rescue system or console (providers.md), then
`/usr/local/sbin/vps-hostfw off` there.

The box is unfiltered for a few seconds at boot, until the unit has run after Docker.

Run `./verify.sh`.
