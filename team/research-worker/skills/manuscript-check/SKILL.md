---
name: manuscript-check
description: The mechanical checks research-worker runs before any draft goes to review — clean LaTeX build at paper/main.pdf, unresolved refs/cites, overfull boxes, leftover TODO/??/\pending placeholders, page count — plus the by-hand arithmetic and cross-reference pass. Used by research-worker (load only for LaTeX manuscript tasks); research-lead creates a board task for that agent rather than running this itself.
version: 1.0.0
metadata:
  hermes:
    tags: [latex, writing]
    category: research-papers
    requires_toolsets: [terminal]
---

# Manuscript check

These checks need no judgment, so a script does them the same way every time:

```bash
bash "__SKILLS_DIR__/manuscript-check/scripts/check.sh" .
```
Each line is PASS / FAIL / SKIP / INFO; it exits non-zero on any FAIL.
It builds with `latexmk -cd`, so the PDF lands at `paper/main.pdf` — where
reviewers read it. If it reports `latexmk not installed`, say so in your report; do not
claim a clean build.

`\pending{C<n>}` is a FAIL on purpose: a draft with pending results is not review-ready.
During drafting it is expected — report which are left instead of treating it as an error.

## By hand, after the script passes

- Table arithmetic is internally consistent: means, deltas, percentages, row/column totals.
- Every number quoted in prose matches its table, and every table matches its artifact in
  `evidence/` (the artifact path is in a LaTeX comment above each tabular).
- Figures are referenced in the text and legible in greyscale.
- Page count is within the limit in `CLAUDE.md`, counting what the venue counts.
- The abstract and introduction assert only `supported` rows of `claims.md`.

These are arithmetic and cross-reference checks. Whether a number *supports the claim it is
attached to* is not the writer's call — leave that to the reviewer.
