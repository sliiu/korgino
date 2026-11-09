#!/bin/bash
# Every key passed to L() must have an entry in every language bundle.
# zh-Hans has no bundle: the Chinese source string is the key itself.
# Run from the repo root. Exit 1 (listing the gaps) when a key is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Keys as written in the source: L("..."). Indirect keys are invisible here, so
# a helper that localizes its own arguments must take text already run through L().
grep -rhoE 'L\("[^"]*"' Engine/*.swift Sources/*.swift \
  | sed 's/^L("//; s/"$//' \
  | sort -u > "$tmp/used"

if [[ ! -s "$tmp/used" ]]; then
  echo "check-strings: found no L() keys; the extractor is broken" >&2
  exit 1
fi

status=0
for dir in Resources/*.lproj; do
  lang="$(basename "$dir" .lproj)"
  file="$dir/Localizable.strings"
  [[ -f "$file" ]] || { echo "check-strings: $dir has no Localizable.strings" >&2; status=1; continue; }
  # The .strings files are UTF-16; iconv first so the byte patterns line up.
  iconv -f UTF-16 -t UTF-8 "$file" \
    | grep -oE '^"[^"]*"' \
    | sed 's/^"//; s/"$//' \
    | sort -u > "$tmp/have"

  missing="$(comm -23 "$tmp/used" "$tmp/have")"
  if [[ -n "$missing" ]]; then
    count="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
    echo "check-strings: $lang is missing $count key(s):" >&2
    printf '%s\n' "$missing" | sed 's/^/    /' >&2
    status=1
  fi

  unused="$(comm -13 "$tmp/used" "$tmp/have")"
  if [[ -n "$unused" ]]; then
    count="$(printf '%s\n' "$unused" | wc -l | tr -d ' ')"
    echo "check-strings: $lang has $count unused key(s) (harmless, worth deleting):" >&2
    printf '%s\n' "$unused" | head -20 | sed 's/^/    /' >&2
  fi
done

if [[ $status -ne 0 ]]; then
  echo "check-strings: FAILED" >&2
  exit 1
fi
echo "check-strings: all $(wc -l < "$tmp/used" | tr -d ' ') keys present in every language"
