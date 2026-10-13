#!/usr/bin/env bash
# Self-test for test/extract-blocks.sh on small fixture files. No server, no network.
# Run from anywhere: bash test/extract-blocks.test.sh
# Fixtures are literal markdown, so $ and backticks stay in single quotes on purpose.
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
fails=0

# expect <name> <want rc: 0|nonzero> <substring of the output> <fixture content (printf format)>
expect() {
  local name=$1 want=$2 needle=$3 out rc ok=1
  # shellcheck disable=SC2059
  printf "$4" > "$dir/$name.md"
  out=$(bash "$REPO/test/extract-blocks.sh" "$dir/$name.md" 2>&1); rc=$?
  if [ "$want" = 0 ]; then [ "$rc" = 0 ] || ok=0; else [ "$rc" != 0 ] || ok=0; fi
  case "$out" in *"$needle"*) ;; *) ok=0 ;; esac
  if [ "$ok" = 1 ]; then echo "ok   $name"; else
    echo "FAIL $name: want rc $want and [$needle], got rc $rc:"; echo "$out"; fails=$((fails + 1)); fi
}

expect good-plain 0 "ALL BLOCKS OK" '```\necho ok\n```\n'
expect json-skipped 0 "checked 0 blocks" '```json\n{"a": 1}\n```\n'
expect long-fence-holds-short 0 "ALL BLOCKS OK" '````text\n```\nif true; then\n```\n````\n'
expect long-fence-bash 1 "never closed" '````bash\necho ok\n```\n'
expect tilde-checked 1 "tilde-checked.md:block 01 (bash -n)" '~~~bash\nif true; then\n~~~\n'
expect tilde-not-closed-by-backticks 1 "tilde-not-closed-by-backticks.md:1: code fence opened here is never closed" '~~~\necho ok\n```\n'
expect crlf-ok 0 "ALL BLOCKS OK" '```bash\r\necho ok\r\n```\r\n'
expect crlf-broken 1 "crlf-broken.md:block 01 (bash -n)" '```\r\nif true; then\r\n```\r\n'
expect unclosed-at-eof 1 "unclosed-at-eof.md:3: code fence opened here is never closed" 'text\n\n```\necho ok\n'
expect indented-checked 1 "(bash -n)" '1. step\n\n    ```\n    if true; then\n    ```\n'
if command -v shellcheck >/dev/null 2>&1; then
  expect rcfile-sc2015-off 0 "ALL BLOCKS OK" '```\n[ -n "$x" ] && echo a || echo b\n```\n'
  expect shellcheck-warning 1 "(shellcheck)" '```\ncd $(foo)\n```\n'
else
  echo "notice: shellcheck not found, shellcheck cases skipped"
fi

echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
