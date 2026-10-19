#!/usr/bin/env bash
# vault_export and vault_import (lib.sh, VAULT.md) with the real age, end to end: export from one
# throwaway home, import into a second, empty one, compare. age reads the passphrase from the
# terminal only, so each run goes through script(1), which gives it a pseudo-terminal; the
# passphrase is a throwaway test value. Skips (exit 0) when age or util-linux script is missing.
# No server, no network. Run from anywhere: bash test/vault-roundtrip.sh   (prints ALL PASSED)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
command -v age >/dev/null 2>&1 || { echo "skip: age not installed"; exit 0; }
script --version 2>/dev/null | grep -q util-linux || { echo "skip: util-linux script not found"; exit 0; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fails=$((fails + 1)); fi; }
A=$(mktemp -d) B=$(mktemp -d)
trap 'rm -rf "$A" "$B"' EXIT
PW='roundtrip-test-only-0'

mkdir -p "$A/.config/vps-setup/handover" "$A/.config/coolify" "$A/.ssh"
( umask 077
  printf 'SSH_PUBKEY=%s\nDOMAIN=example.invalid\n' "$A/.ssh/id_test.pub" > "$A/.config/vps-setup/state"
  printf 'S3_KEY=RT-FAKE-KEY\nS3_SECRET=RT-FAKE-SECRET|x\n' > "$A/.config/vps-setup/s3.env"
  printf 'COOLIFY_URL=https://c.example.invalid\nCOOLIFY_TOKEN=9|RT-FAKE-TOKEN\n' > "$A/.config/coolify/config"
  printf 'fake private key\n' > "$A/.ssh/id_test"; printf 'ssh-ed25519 AAAA fake\n' > "$A/.ssh/id_test.pub"
  printf 'old state\n' > "$A/.config/vps-setup/handover/state" )

# run HOME INPUT CMD: CMD in bash with lib.sh, under a pseudo-terminal, INPUT typed into it
run() {
  local h=$1 in=$2; shift 2
  printf '%s' "$in" | HOME=$h script -qefc "bash -c '. \"$REPO/lib.sh\"; $*'" /dev/null > "$h/run.log" 2>&1
}
run "$A" "$PW"$'\n'"$PW"$'\n' vault_export "$A/v.age"; rc=$?
check "export with the real age: exit 0" "$rc" "0"
[ "$rc" = 0 ] || sed 's/^/     /' "$A/run.log"
check "export: age file, passphrase header" "$(head -n 1 "$A/v.age"):$(sed -n 2p "$A/v.age" | cut -c1-10)" "age-encryption.org/v1:-> scrypt "
check "export: no plaintext in the file" "$(grep -c 'RT-FAKE' "$A/v.age")" "0"
check "export: mode 600" "$(stat -c %a "$A/v.age")" "600"
out=$(HOME=$A bash -c ". '$REPO/lib.sh'; vault_check"); rc=$?
check "vault_check after the export" "$rc" "0"
[ "$rc" = 0 ] || echo "     $out"

cp "$A/v.age" "$B/v.age"
run "$B" "wrong-pass"$'\n' vault_import "$B/v.age"; rc=$?
check "import with a wrong passphrase: refused" "$rc" "1"
check "import with a wrong passphrase: nothing unpacked" "$([ -e "$B/.config/vps-setup/state" ] && echo there || echo none)" "none"
run "$B" "$PW"$'\n' vault_import "$B/v.age"; rc=$?
check "import with the real age: exit 0" "$rc" "0"
[ "$rc" = 0 ] || sed 's/^/     /' "$B/run.log"
for f in .config/vps-setup/state .config/vps-setup/s3.env .config/coolify/config .ssh/id_test .ssh/id_test.pub .config/vps-setup/handover/state; do
  check "import: $f the same, mode 600" "$(cmp -s "$A/$f" "$B/$f" && echo same || echo differs):$(stat -c %a "$B/$f" 2>/dev/null)" "same:600"
done
out=$(HOME=$B bash -c ". '$REPO/lib.sh'; vault_check"); rc=$?
check "vault_check on the second machine" "$rc" "0"
[ "$rc" = 0 ] || echo "     $out"

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
