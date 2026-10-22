#!/bin/bash
# Usage: cite_keys.sh <paper-folder>
# Prints cited-but-undefined keys (render as [?]) and defined-but-unused keys (dead weight).
set -euo pipefail
p="${1:?paper folder}"; tex=$(find "$p/paper" -name '*.tex'); bib="$p/paper/refs.bib"
used=$(grep -hoE '\\(cite|citep|citet|citealp|citeauthor|citeyear|autocite|parencite|textcite)\*?(\[[^]]*\])*\{[^}]*\}' $tex \
  | grep -oE '\{[^}]*\}$' | tr -d '{}' | tr ',' '\n' | sed 's/ //g' | grep -v '^$' | sort -u || true)
defined=$( { grep -oE '^@[a-zA-Z]+\{[^,]+' "$bib" 2>/dev/null || true; } | sed 's/^@[a-zA-Z]*{//' | grep -viE '^(comment|string|preamble)$' | sort -u || true)
echo "cited: $(grep -c . <<<"$used" || true)  defined: $(grep -c . <<<"$defined" || true)"
echo "## cited but undefined"; comm -23 <(echo "$used") <(echo "$defined") | grep . || echo "(none)"
echo "## defined but never cited"; comm -13 <(echo "$used") <(echo "$defined") | grep . || echo "(none)"
