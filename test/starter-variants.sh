#!/usr/bin/env bash
# The starter variants share the starter's plumbing (R24): starter-auth/ (AUTH.md) is a copy of
# starter/'s Dockerfile, ignores, Next config and the shared UI files, byte for byte, with the
# same dependency versions and the same tsconfig except one key. This catches a fix made in one
# and forgotten in the other. Files that differ on purpose (lib/db.ts, the health route,
# instrumentation.ts, package.json's extra dependency) are mirrored by hand. Also: every
# variable starter-auth reads is in its .env.example. No server, no network, needs jq.
# Usage: bash test/starter-variants.sh   (prints ALL VARIANT FILES OK)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

command -v jq >/dev/null || { echo "FAIL jq is needed for this test"; exit 1; }
fails=0
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
A=starter B=starter-auth

for f in Dockerfile .dockerignore .gitignore next.config.ts app/globals.css app/corners.tsx public/.gitkeep AGENTS.md CLAUDE.md; do
  if [ ! -f "$A/$f" ] || [ ! -f "$B/$f" ]; then fail "$f missing in $A/ or $B/"
  elif ! cmp -s "$A/$f" "$B/$f"; then fail "$B/$f differs from $A/$f (copy the fix over)"
  else echo "ok   $f identical"; fi
done

deps='{d: (.dependencies | {next, pg, react, "react-dom"}), dev: .devDependencies}'
if [ "$(jq -cS "$deps" "$A/package.json")" = "$(jq -cS "$deps" "$B/package.json")" ]; then
  echo "ok   package.json: the shared dependency versions agree"
else
  fail "package.json: next, pg, react, react-dom or a devDependency differs between $A and $B"
fi
jq -e '.dependencies.nodemailer and .scripts.test' "$B/package.json" >/dev/null || fail "$B/package.json: no nodemailer or no test script"
for p in next pg react react-dom; do
  [ "$(jq -r --arg p "node_modules/$p" '.packages[$p].version' "$A/package-lock.json")" = \
    "$(jq -r --arg p "node_modules/$p" '.packages[$p].version' "$B/package-lock.json")" ] || fail "package-lock.json: $p is locked at another version in $B"
done

if [ "$(jq -cS . "$A/tsconfig.json")" = "$(jq -cS 'del(.compilerOptions.allowImportingTsExtensions)' "$B/tsconfig.json")" ]; then
  echo "ok   tsconfig.json: the same apart from allowImportingTsExtensions"
else
  fail "tsconfig.json: $B differs from $A by more than allowImportingTsExtensions"
fi

pool='new Pool({ connectionString: process.env.DATABASE_URL, max: 5, connectionTimeoutMillis: 5000 })'
for d in "$A" "$B"; do grep -qF "$pool" "$d/lib/db.ts" || fail "$d/lib/db.ts: the pool line changed ($pool)"; done
grep -q 'process.exit(1)' "$B/lib/db.ts" || fail "$B/lib/db.ts: migrateOrExit no longer exits"

# Every env.NAME / process.env.NAME the variant reads, apart from what Node and Next set.
missing=$(grep -rhoE '(process\.)?env\.[A-Z][A-Z0-9_]*' "$B/app" "$B/lib" "$B/instrumentation.ts" | sed 's/.*env\.//' | sort -u |
  grep -vxE 'NODE_ENV|NEXT_RUNTIME' | while read -r v; do grep -qE "^#? ?$v=" "$B/.env.example" || echo "$v"; done)
[ -z "$missing" ] && echo "ok   .env.example lists every variable" || fail "$B/.env.example misses: $(paste -sd' ' - <<<"$missing")"

if [ "$fails" = 0 ]; then echo "ALL VARIANT FILES OK"; else echo "$fails VARIANT CHECKS FAILED"; exit 1; fi
