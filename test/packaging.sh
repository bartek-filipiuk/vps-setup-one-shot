#!/usr/bin/env bash
# Checks that the agent packaging agrees with the runbooks: the "Entry points" table in AGENTS.md,
# the Claude Code plugin and marketplace manifests (.claude-plugin/), the plugin skills
# (skills/<cmd>/SKILL.md) and the Cursor rule (.cursor/rules/*.mdc). The pointers only name a
# runbook; they never repeat a step, so they carry no code fences, no lib.sh helper names and no
# server commands. No server, no network.
# Usage: bash test/packaging.sh   (prints ALL POINTERS OK)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fails=0
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

command -v jq >/dev/null || { echo "FAIL jq is needed for this test"; exit 1; }

# --- a. the Entry points table: "| what | `FILE` | `/cmd` |" rows -> "FILE cmd" ---
rows=$(awk '
  /^## / { on = ($0 == "## Entry points"); next }
  on && /^\|/ {
    n = split($0, c, "|"); if (n < 5) next
    f = c[3]; m = c[4]; gsub(/[ `]/, "", f); gsub(/[ `]/, "", m)
    if (f == "Runbook" || f ~ /^-+$/) next
    sub(/^\//, "", m); print f, m
  }' AGENTS.md)
[ -n "$rows" ] || fail "AGENTS.md: no rows in the \"## Entry points\" table"
cmds=" "
while read -r file cmd; do
  [ -n "$file" ] || continue
  [ -f "$file" ] || fail "AGENTS.md: entry point $file does not exist"
  [ -n "$cmd" ] || fail "AGENTS.md: entry point $file has no command"
  cmds="$cmds$cmd "
done <<<"$rows"

# --- b. manifests ---
plugin=.claude-plugin/plugin.json
market=.claude-plugin/marketplace.json
if [ -f "$plugin" ]; then
  jq -e '.name == "vps-setup-one-shot"' "$plugin" >/dev/null || fail "$plugin: name is not vps-setup-one-shot"
  jq -e 'has("version") | not' "$plugin" >/dev/null || fail "$plugin: has a version (updates must follow commits)"
else
  fail "$plugin missing"
fi
if [ -f "$market" ]; then
  jq -e '(.owner.name // "") != ""' "$market" >/dev/null || fail "$market: owner.name is empty"
  jq -e '[.plugins[]? | select(.name == "vps-setup-one-shot" and .source == ".")] | length == 1' "$market" >/dev/null ||
    fail "$market: no single vps-setup-one-shot entry with source \".\""
  jq -e '[.plugins[]? | select(has("version"))] | length == 0' "$market" >/dev/null ||
    fail "$market: an entry has a version (updates must follow commits)"
else
  fail "$market missing"
fi

# --- c. every row has a skill and a Cursor bullet pointing at its file ---
rule=.cursor/rules/vps-setup-one-shot.mdc
[ -f "$rule" ] || fail "$rule missing"
while read -r file cmd; do
  [ -n "$cmd" ] || continue
  skill="skills/$cmd/SKILL.md"
  if [ -f "$skill" ]; then
    # shellcheck disable=SC2016 # the literal placeholder, expanded by Claude Code, not here
    grep -qF '${CLAUDE_PLUGIN_ROOT}/'"$file" "$skill" || fail "$skill does not point at \${CLAUDE_PLUGIN_ROOT}/$file"
  else
    fail "$skill missing for $file"
  fi
  [ -f "$rule" ] && { grep -qF "\`$file\`" "$rule" || fail "$rule does not name $file"; }
done <<<"$rows"

# --- d. every skill is in the table, with the frontmatter the plugin needs ---
for skill in skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  dir=${skill#skills/}; dir=${dir%/SKILL.md}
  case "$cmds" in *" $dir "*) ;; *) fail "$skill is not in the AGENTS.md Entry points table" ;; esac
  [ "$(head -n1 "$skill")" = "---" ] || fail "$skill: first line is not ---"
  front=$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$skill")
  grep -qx "name: $dir" <<<"$front" || fail "$skill: frontmatter has no \"name: $dir\""
  grep -qE '^description: *[^ ]' <<<"$front" || fail "$skill: frontmatter has no description"
  grep -qx 'disable-model-invocation: true' <<<"$front" || fail "$skill: not disable-model-invocation: true"
done

# --- e. pointers carry no runbook content ---
# helper-shaped names only (with an underscore), so plain words like line or section stay usable
funcs=$(grep -oE '^[a-z0-9_]+\(\)' lib.sh | tr -d '()' | grep '_' | paste -sd'|')
[ -n "$funcs" ] || fail "lib.sh: no helper names found for the banned list"
banned="(^|[^A-Za-z_])($funcs|ssh|docker|hcloud|curl|apt-get|jq)([^A-Za-z_]|$)"
for p in skills/*/SKILL.md .cursor/rules/*.mdc; do
  [ -f "$p" ] || continue
  if grep -nE '^[[:space:]]*(```|~~~)' "$p" >/dev/null; then fail "$p: has a code fence"; fi
  hits=$(grep -noE "$banned" "$p" | head -3 | tr '\n' ' ')
  [ -z "$hits" ] || fail "$p: names a helper or a server command: $hits"
  n=$(wc -l <"$p" | tr -d ' ')
  [ "$n" -le 25 ] || fail "$p: $n lines, a pointer has at most 25"
  # shellcheck disable=SC2016 # the literal placeholder
  while read -r ref; do
    [ -n "$ref" ] || continue
    path=${ref#'${CLAUDE_PLUGIN_ROOT}/'}; path=${path%.}
    [ -e "$path" ] || fail "$p: \${CLAUDE_PLUGIN_ROOT}/$path does not exist"
  done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+' "$p")
done

echo "checked $(grep -c . <<<"$rows") entry points"
if [ "$fails" = 0 ]; then echo "ALL POINTERS OK"; else echo "$fails FAILED"; exit 1; fi
