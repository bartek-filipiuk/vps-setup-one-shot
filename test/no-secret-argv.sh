#!/usr/bin/env bash
# Secrets never go on a command line (AGENTS.md rule 2): anything in argv shows up in `ps` and
# /proc/*/cmdline. This greps the runbooks (the files test/extract-blocks.sh checks) and the
# scripts for a jq --arg, a gh -f/-F/--field/--raw-field, a curl -d/--data* or an Authorization
# -H whose value expands a secret-named variable (S, W, PW, PASS*, SECRET*, TOKEN*, KEY but not
# KEY_UUID, URL (a DATABASE_URL with the password), token, secret, pw, pass*) or $(openssl rand.
# The fix is the value on stdin: `printf '%s' "$S" | jq -Rs '{x:.}'`, `openssl rand -hex 24 |
# jq -Rn '{p:input}'`, `... | gh api --input -`, curl -K <(printf ...).
# A name-based heuristic, no server, no network. Usage: bash test/no-secret-argv.sh [file ...]
# (prints NO SECRETS IN ARGV).
cd "$(dirname "$0")/.." || exit 1
files=("$@")
[ "${#files[@]}" -gt 0 ] || files=(phases/*.md SETUP.md PREPARE-APP.md STAGING.md ROLLBACK.md RESTORE.md DOCTOR.md
  HANDOVER.md SERVICES.md UPGRADE.md REBUILD.md CHECKUP.md lib.sh verify.sh status.sh checkup.sh)

vars='(S|W|PW|PASS[A-Z0-9_]*|SECRET[A-Z0-9_]*|TOKEN[A-Z0-9_]*|KEY|URL|token|secret|pw|pass[a-z0-9_]*)'
val="[\"']?[^[:space:]\"']*(\\\$\\{?$vars([^A-Za-z0-9_]|$)|\\\$\\(openssl rand)"
flags='(--arg[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|-f|-F|--field|--raw-field|-d|--data[a-z-]*)'
re="(^|[[:space:](])(${flags}[[:space:]]+$val|-H[[:space:]]+[\"']?Authorization[^\"']*\\\$)"

# Allowlist: "file:line text" (no line number, so edits elsewhere do not break it) for a match
# that carries no secret, each with a comment saying why. Empty on the current tree.
allow=()

fails=0
while IFS= read -r hit; do
  f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; text=${rest#*:}
  for a in ${allow[@]+"${allow[@]}"}; do [ "$f:$text" = "$a" ] && continue 2; done
  echo "FAIL $f:$n: secret on a command line: ${text#"${text%%[![:space:]]*}"}"
  fails=$((fails + 1))
done < <(grep -nE "$re" "${files[@]}" /dev/null)

if [ "$fails" = 0 ]; then echo "NO SECRETS IN ARGV"; else echo "$fails LINES WITH A SECRET IN ARGV"; exit 1; fi
