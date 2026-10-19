#!/usr/bin/env bash
# Secrets never go on a command line (AGENTS.md rule 2): anything in argv shows up in `ps` and
# /proc/*/cmdline. This greps the runbooks (the files test/extract-blocks.sh checks) and the
# scripts, with backslash-continued lines joined, for:
#   jq --arg/--argjson NAME VALUE, -H/--header VALUE (and any Authorization header with a $),
#   and on a line with `gh ` or `curl `: -f/-F/--field/--raw-field/-d/--data*/-u/--user/-b/--body VALUE,
# where VALUE expands a secret-named variable (S, W, PW, PASS*, SECRET*, TOKEN*, KEY but not
# KEY_UUID, URL (a DATABASE_URL with the password), each with an optional FOO_ prefix; token,
# secret, pw, pass*), $(openssl rand, a credential getter ($(cf_cred, $(s3_cred, $(notify_cred,
# $(kuma_cred, $(coolify_get COOLIFY_TOKEN) or $(cat .
# The fix is the value on stdin: `printf '%s' "$S" | jq -Rs '{x:.}'`, `openssl rand -hex 24 |
# jq -Rn '{p:input}'`, `... | gh api --input -`, curl -K <(printf ...).
# A name-based heuristic, no server, no network. Usage: bash test/no-secret-argv.sh [file ...]
# (prints NO SECRETS IN ARGV).
cd "$(dirname "$0")/.." || exit 1
files=("$@")
[ "${#files[@]}" -gt 0 ] || files=(phases/*.md SETUP.md PREPARE-APP.md STAGING.md ROLLBACK.md RESTORE.md DOCTOR.md
  HANDOVER.md SERVICES.md UPGRADE.md REBUILD.md CHECKUP.md UPTIME.md VAULT.md lib.sh verify.sh status.sh checkup.sh)

vars='(([A-Z0-9_]*_)?(S|W|PW|PASS[A-Z0-9_]*|SECRET[A-Z0-9_]*|TOKEN[A-Z0-9_]*|KEY|URL)|token|secret|pw|pass[a-z0-9_]*)'
getters='(openssl rand|cf_cred |s3_cred |notify_cred |kuma_cred |coolify_get COOLIFY_TOKEN|cat )'
sp='[[:space:]]+'
pre='(^|[[:space:](])'
secret="(\\\$\\{?$vars([^A-Za-z0-9_]|$)|\\\$\\($getters)"
val="[\"']?[^[:space:]\"']*$secret"
hval="([\"'][^\"']*$secret|$val)"   # a header value may hold spaces inside its quotes
anyline="$pre((--arg|--argjson)${sp}[A-Za-z_][A-Za-z0-9_]*$sp$val|(-H|--header)$sp$hval|(-H|--header)${sp}[\"']?Authorization[^\"']*\\\$)"
tool='(^|[^A-Za-z0-9_-])(gh|curl)[[:space:]]'
toolflag="$pre(-f|-F|--field|--raw-field|-d|--data[a-z-]*|-u|--user|-b|--body)$sp$hval"

# Allowlist: "file:line text" (no line number, so edits elsewhere do not break it; a continued
# line is the joined text) for a match that carries no secret, each with a comment saying why.
# Empty on the current tree.
allow=()

# file:first-line:logical line, continuation lines (ending in \) joined with a space.
logical() {
  awk '{ sub(/\r$/, "") }
    FNR == 1 { if (buf != "") print name ":" start ":" buf; buf = "" }
    { if (buf == "") { start = FNR; name = FILENAME }
      if (sub(/\\$/, "")) { buf = buf $0 " "; next }
      print name ":" start ":" buf $0; buf = "" }
    END { if (buf != "") print name ":" start ":" buf }' "$@"
}

fails=0
while IFS= read -r hit; do
  f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; text=${rest#*:}
  grep -qE "$anyline" <<<"$text" || { grep -qE "$tool" <<<"$text" && grep -qE "$toolflag" <<<"$text"; } || continue
  for a in ${allow[@]+"${allow[@]}"}; do [ "$f:$text" = "$a" ] && continue 2; done
  echo "FAIL $f:$n: secret on a command line: ${text#"${text%%[![:space:]]*}"}"
  fails=$((fails + 1))
done < <(logical "${files[@]}" | grep -E "$anyline|$toolflag")

if [ "$fails" = 0 ]; then echo "NO SECRETS IN ARGV"; else echo "$fails LINES WITH A SECRET IN ARGV"; exit 1; fi
