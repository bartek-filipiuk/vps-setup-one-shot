# 02 Harden

**Done when** `./verify.sh` shows: password SSH login disabled, swap enabled,
unattended-upgrades installed.

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

1. Prove key login works in a **fresh** connection: `. ./lib.sh; rssh 'echo key-login-ok'`.
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

3. Prove it again in a fresh connection: `. ./lib.sh; rssh 'echo still-in'`.
   If that fails, stop. Hetzner users can recover: server → tab **Rescue** → **Reset root
   password** (copy it), then the **Console** button (top right), log in as root and delete
   `/etc/ssh/sshd_config.d/00-hardening.conf`.

Run `./verify.sh`.
