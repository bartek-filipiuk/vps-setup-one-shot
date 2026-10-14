#!/usr/bin/env bash
# Checks the real state of the setup and prints the next phase to run.
# Run from the repo root on YOUR machine: ./verify.sh
# Exit code: 0 when everything is done, 1 otherwise.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
next() { printf '\nNEXT: %s\n' "$1"; exit 1; }

echo "00 preflight"
missing=""
for t in ssh git gh jq curl dig openssl; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ "$(state_get PROVIDER)" = hetzner ] && { command -v hcloud >/dev/null || missing="$missing hcloud"; }
[ -z "$missing" ] && ok "tools installed" || { bad "missing tools:$missing"; next phases/00-preflight.md; }
gh auth status >/dev/null 2>&1 && ok "gh logged in" || { bad "gh not logged in"; next phases/00-preflight.md; }
ls ~/.ssh/id_*.pub >/dev/null 2>&1 && ok "ssh key exists" || { bad "no ssh key in ~/.ssh"; next phases/00-preflight.md; }
keys="PROVIDER DOMAIN COOLIFY_DOMAIN APP_DOMAIN APP_NAME SSH_PUBKEY SETUP_DIR"
[ "$(state_get PROVIDER)" = hetzner ] && [ "$(state_get SERVER_EXISTS)" != 1 ] && keys="$keys HCLOUD_LOCATION"
for k in $keys; do
  [ -n "$(state_get "$k")" ] || { bad "$k not set in $VPS_STATE"; next phases/00-preflight.md; }
done
ok "answers recorded (domain $(state_get DOMAIN))"

echo "01 server"
IP=$(state_get VPS_IP)
[ -n "$IP" ] && ok "VPS_IP $IP" || { bad "no VPS yet"; next phases/01-server.md; }
rssh true 2>/dev/null && ok "ssh root@$IP with key" || { bad "cannot ssh root@$IP with key"; next phases/01-server.md; }
for h in "$(state_get COOLIFY_DOMAIN)" "$(state_get APP_DOMAIN)"; do
  [ "$(dig +short A "$h" @1.1.1.1 | tail -1)" = "$IP" ] && ok "DNS $h -> $IP" || bad "DNS $h does not point to $IP yet (checked again in phase 04)"
done

echo "02 harden"
rssh "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'" && ok "password SSH login disabled" || { bad "password SSH login still enabled"; next phases/02-harden.md; }
rssh "swapon --show --noheadings | grep -q ." && ok "swap enabled" || { bad "no swap"; next phases/02-harden.md; }
rssh "dpkg -s unattended-upgrades >/dev/null 2>&1" && ok "unattended-upgrades installed" || { bad "unattended-upgrades missing"; next phases/02-harden.md; }

echo "03 coolify"
rssh "docker ps --format '{{.Names}}' | grep -qx coolify" && ok "coolify container running" || { bad "Coolify not running"; next phases/03-coolify.md; }
[ "$(state_get ADMIN_REGISTERED)" = 1 ] && ok "admin account registered" || { bad "admin not registered yet"; next phases/03-coolify.md; }

echo "04 domain + API"
CD=$(state_get COOLIFY_DOMAIN)
# curl fails on an invalid cert, so any status below 400 means "served over valid HTTPS".
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$CD" || true)
[ "${code:-000}" -ge 200 ] && [ "$code" -lt 400 ] && ok "https://$CD serves Coolify with a valid cert" || { bad "https://$CD not reachable with a valid cert"; next phases/04-domain.md; }
# 7 = refused, 28 = timed out (firewall drop): closed. 0 = it answered. Anything else is not proof either way.
curl -s -o /dev/null --max-time 5 "http://$IP:8000"; rc=$?
case $rc in
  0) bad "port 8000 is publicly reachable"; next phases/04-domain.md ;;
  7|28) ok "port 8000 closed to the internet" ;;
  *) bad "could not check port 8000 (curl exit $rc), check your own network and run again"; next phases/04-domain.md ;;
esac
capi GET /version >/dev/null 2>&1 && ok "API token works (Coolify $(capi GET /version 2>/dev/null | tr -d '"'))" || { bad "API token missing or rejected"; next phases/04-domain.md; }
[ -n "$(coolify_get COOLIFY_SERVER_UUID)" ] && ok "server uuid saved" || { bad "COOLIFY_SERVER_UUID missing"; next phases/04-domain.md; }

echo "05 starter app"
AD=$(state_get APP_DOMAIN)
[ -n "$(state_get APP_UUID)" ] && ok "app created" || { bad "starter app not created"; next phases/05-starter.md; }
curl -sf --max-time 10 "https://$AD/api/health" | grep -q '"db":"ok"' && ok "https://$AD/api/health -> db ok" || { bad "https://$AD/api/health is not healthy"; next phases/05-starter.md; }
[ -n "$(state_get WEBHOOK)" ] && ok "push-to-deploy: $(state_get WEBHOOK)" || { bad "push-to-deploy not set up or decided"; next phases/05-starter.md; }
[ -f "$(state_get APP_DIR)/.coolify.env" ] && ok ".coolify.env written" || { bad ".coolify.env missing in $(state_get APP_DIR)"; next phases/05-starter.md; }

echo "06 handover"
[ -f "$HOME/.config/vps-setup/SERVER.md" ] && [ "$(state_get HANDOVER_DONE)" = 1 ] && ok "SERVER.md written, backups and alerts decided" || { bad "handover not done"; next phases/06-handover.md; }

printf '\nALL DONE. To deploy another app: read PREPARE-APP.md\n'
