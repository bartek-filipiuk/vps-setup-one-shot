#!/usr/bin/env bash
# Pulls the shell code blocks out of the runbooks (phases/*.md, SETUP.md, PREPARE-APP.md) and
# checks each one with `bash -n` and shellcheck. Untagged, bash and sh fences are checked; other
# tags (text, json, ...) are skipped. ``` and ~~~ fences, any length >= 3, may be indented; a
# fence closes only on the same character, at least as long; CRLF is fine. A fence still open at
# the end of a file is a failure. No server, no network.
# Usage: bash test/extract-blocks.sh [file.md ...]   (default: the runbooks; prints ALL BLOCKS OK)
# Shellcheck uses the repo .shellcheckrc plus -e SC2034,SC2154 (blocks set and read state
# variables across blocks), at severity warning.
files=()
for a in "$@"; do case "$a" in /*) files+=("$a") ;; *) files+=("$PWD/$a") ;; esac; done
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
[ "${#files[@]}" -gt 0 ] || files=(phases/*.md SETUP.md PREPARE-APP.md)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
k=0
names=()
for md in "${files[@]}"; do
  [ -f "$md" ] || continue
  k=$((k + 1)); names[k]=${md#"$REPO"/}
  # One file per kept block: <k>.<nn>.sh
  if ! awk -v out="$tmp/$k" -v md="${names[k]}" '
    function fence(s,   c, n) {          # 1 if s is a fence line; sets fch, flen, frest
      sub(/^[ \t]*/, "", s); c = substr(s, 1, 1)
      if (c != "`" && c != "~") return 0
      n = 0; while (substr(s, n + 1, 1) == c) n++
      if (n < 3) return 0
      fch = c; flen = n; frest = substr(s, n + 1); return 1
    }
    { sub(/\r$/, "") }
    !inb {
      if (fence($0) && !(fch == "`" && index(frest, "`"))) {
        tag = frest; sub(/^[ \t]*/, "", tag); sub(/[ \t].*$/, "", tag)
        inb = 1; ofch = fch; oflen = flen; start = NR
        keep = (tag == "" || tag == "bash" || tag == "sh")
        if (keep) { nb++; f = sprintf("%s.%02d.sh", out, nb); printf "" > f }
      }
      next
    }
    {
      if (fence($0) && fch == ofch && flen >= oflen && frest ~ /^[ \t]*$/) {
        inb = 0; if (keep) close(f); next
      }
      if (keep) print > f
    }
    END { if (inb) { printf "FAIL %s:%d: code fence opened here is never closed\n", md, start; exit 2 } }
  ' "$md"; then
    fails=$((fails + 1))
  fi
done

shopt -s nullglob
blocks=("$tmp"/*.sh)
have_sc=1
command -v shellcheck >/dev/null 2>&1 || { have_sc=0; echo "notice: shellcheck not found, running bash -n only"; }

for f in "${blocks[@]}"; do
  base=${f##*/}; nn=${base%.sh}; nn=${nn#*.}
  label="${names[${base%%.*}]}:block $nn"
  if ! msg=$(bash -n "$f" 2>&1); then
    echo "FAIL $label (bash -n)"; echo "${msg//"$tmp"\//}"; fails=$((fails + 1)); continue
  fi
  if [ "$have_sc" = 1 ] &&
     ! msg=$(shellcheck --rcfile "$REPO/.shellcheckrc" -S warning -e SC2034,SC2154 "$f" 2>&1); then
    echo "FAIL $label (shellcheck)"; echo "${msg//"$tmp"\//}"; fails=$((fails + 1))
  fi
done

echo "checked ${#blocks[@]} blocks"
if [ "$fails" = 0 ]; then echo "ALL BLOCKS OK"; else echo "$fails BLOCKS FAILED"; exit 1; fi
