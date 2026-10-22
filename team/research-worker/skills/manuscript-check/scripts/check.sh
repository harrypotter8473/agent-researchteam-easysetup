#!/bin/bash
# Usage: check.sh <paper-folder>
# Mechanical pre-review checks. Each line is PASS / FAIL / SKIP; exit 1 if any FAIL.
p="${1:?paper folder}"; fail=0
say(){ echo "$1  $2"; [ "$1" = FAIL ] && fail=1; }

if command -v latexmk >/dev/null; then
  # -cd: build inside paper/ so main.pdf lands at paper/main.pdf, where reviewers read it
  if latexmk -cd -pdf -interaction=nonstopmode -halt-on-error "$p/paper/main.tex" >/dev/null 2>&1; then
    say PASS "build: $p/paper/main.pdf"
  else
    say FAIL "build — see $p/paper/main.log"; grep -m5 -A2 '^!' "$p/paper/main.log" 2>/dev/null
  fi
  log="$p/paper/main.log"
  if [ -f "$log" ]; then
    n=$(grep -c 'undefined' "$log" || true); [ "$n" -gt 0 ] && say FAIL "$n undefined refs/citations in log" || say PASS "refs and citations resolve"
    n=$(grep -c '^Overfull' "$log" || true); [ "$n" -gt 0 ] && say FAIL "$n overfull hboxes" || say PASS "no overfull hboxes"
  fi
else
  say FAIL "latexmk not installed — cannot build (macOS: brew install --cask mactex-no-gui)"
fi

hits=$(grep -rnE 'TODO|FIXME|XXX|\\ref\{\?\}|\?\?|\\pending\{' "$p/paper" --include='*.tex' | grep -v 'newcommand{\\pending}' || true)
[ -n "$hits" ] && { say FAIL "placeholders left:"; echo "$hits"; } || say PASS "no TODO/FIXME/??/\\pending"

if command -v pdfinfo >/dev/null && [ -f "$p/paper/main.pdf" ]; then
  say INFO "pages: $(pdfinfo "$p/paper/main.pdf" | awk '/^Pages/{print $2}') (compare with the limit in $p/CLAUDE.md)"
else
  say SKIP "page count (pdfinfo missing or no PDF)"
fi
exit $fail
