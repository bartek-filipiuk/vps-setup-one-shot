#!/usr/bin/env bash
# Pulls the shell code blocks out of the runbooks (phases/*.md, SETUP.md, PREPARE-APP.md) and
# checks each one with `bash -n` and shellcheck. Untagged, bash and sh fences are checked; other
# tags (text, json, ...) are skipped. No server, no network.
# Usage: bash test/extract-blocks.sh   (from anywhere; prints ALL BLOCKS OK or the failing blocks)
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for md in phases/*.md SETUP.md PREPARE-APP.md; do
  [ -f "$md" ] || continue
  # One file per block: <md with / -> _>.<nn>.sh. Fences may be indented (inside list items).
  awk -v out="$tmp/$(echo "$md" | tr '/' '_')" '
    !inb && /^[ \t]*```/ {
      tag = $0; sub(/^[ \t]*```[ \t]*/, "", tag); sub(/[ \t].*$/, "", tag)
      inb = 1; keep = (tag == "" || tag == "bash" || tag == "sh")
      if (keep) { n++; f = sprintf("%s.%02d.sh", out, n); printf "" > f }
      next
    }
    inb && /^[ \t]*```[ \t]*$/ { inb = 0; if (keep) close(f); next }
    inb && keep { print > f }
  ' "$md"
done

shopt -s nullglob
blocks=("$tmp"/*.sh)
have_sc=1
command -v shellcheck >/dev/null 2>&1 || { have_sc=0; echo "notice: shellcheck not found, running bash -n only"; }

fails=0
for f in "${blocks[@]}"; do
  base=${f##*/}; name="${base%.*.sh}"; nn="${base%.sh}"; nn="${nn##*.}"
  label="${name/_//}:block $nn"
  if ! msg=$(bash -n "$f" 2>&1); then
    echo "FAIL $label (bash -n)"; echo "${msg//"$tmp"\//}"; fails=$((fails + 1)); continue
  fi
  if [ "$have_sc" = 1 ] && ! msg=$(shellcheck -s bash -S warning -e SC1091,SC2034,SC2154 "$f" 2>&1); then
    echo "FAIL $label (shellcheck)"; echo "${msg//"$tmp"\//}"; fails=$((fails + 1))
  fi
done

echo "checked ${#blocks[@]} blocks"
if [ "$fails" = 0 ]; then echo "ALL BLOCKS OK"; else echo "$fails BLOCKS FAILED"; exit 1; fi
