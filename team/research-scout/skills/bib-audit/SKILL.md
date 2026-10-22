---
name: bib-audit
description: How research-scout audits our own manuscript's bibliography — every \cite resolves, every entry is a real paper with correct metadata, every cited paper actually says what the sentence claims, plus required prior art that is missing. Writes reviews/round-<N>/bibliography.md. Used by research-scout, bibliography-audit mode; research-lead creates a board task for that agent rather than running this itself.
version: 1.0.0
metadata:
  hermes:
    tags: [research, citations, review]
    category: research-papers
    requires_toolsets: [terminal, web]
---

# Bibliography audit

Same rule as always: **never invent a citation, and never confirm one you did not verify.**
A citation you could not check is reported as unchecked, not as fine.

Read-only on `paper/`. Write one file: `reviews/round-<N>/bibliography.md`.

## Procedure

1. Key hygiene — mechanical, so run the script rather than re-deriving it:
   ```bash
   bash "__SKILLS_DIR__/bib-audit/scripts/cite_keys.sh" .
   ```
   It prints cited-but-undefined keys (render as `[?]`) and defined-but-never-cited keys.
2. Resolve each bib entry against a real record — arXiv, Semantic Scholar, ACL Anthology,
   DBLP (recipes in `lit-search`, auto-loaded). Confirm title, authors, venue and year; flag a preprint
   cited where a published version exists.
3. For each citation, read the sentence that cites it and check the cited work supports
   **that specific sentence**. Fetch the paper when the claim is load-bearing. This is the
   part that matters most and the part no other agent does.
4. Search for prior art the draft should cite and does not: the obvious neighbors of our
   method, and anything a referee in this subfield would consider required reading. Several
   vocabularies, then one citation walk from the two most-cited neighbors.

## Report

```
## Bibliography audit -- round <N>, as of <date>

**Bottom line:** 1-3 sentences. Anything here that would embarrass us in review?

### Broken (fix before submission)
Cited keys with no bib entry; bib entries that resolve to no real paper.

### Misattributed (most serious)
Citation -- the sentence it supports -- what the cited paper actually says. One entry per
claim the source does not establish.

### Wrong metadata
Venue, year, authors; preprint cited where a published version exists.

### Missing prior art
Paper (authors, venue, year, arXiv ID/DOI) -- where it belongs -- why a referee would
expect it. Ranked by how badly its absence reads.

### Unused entries
Defined but never cited.

### Unchecked
Entries you could not verify, and why.
```

Rank by damage: a misattributed citation is a soundness problem; a wrong year is a typo.
