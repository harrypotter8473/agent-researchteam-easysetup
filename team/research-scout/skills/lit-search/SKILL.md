---
name: lit-search
description: How to find and verify CS/AI papers — arXiv, Semantic Scholar, OpenReview, ACL Anthology and DBLP API recipes, coverage discipline, citation walks, and what to extract when reading a paper. Auto-loaded by research-scout and research-reviewer; any profile that must name or check a paper follows it. Used by research-scout and research-reviewer (auto-loaded); research-lead creates a board task for that agent rather than running this itself.
version: 1.0.0
metadata:
  hermes:
    tags: [research, literature, citations]
    category: research-papers
    requires_toolsets: [web, terminal]
---

# Finding and verifying papers

**Never name a paper you did not get from a search result or a page you fetched.** Report
title, authors, venue, year, and arXiv ID / DOI / URL. If you cannot verify a paper exists,
say so instead of guessing — a fabricated citation in a paper or a review is worse than a
missing one.

**Queries leave the machine.** Unless the paper's `CLAUDE.md` marks it `public`, search by
topic terms and known paper titles only — never paste its unpublished text, numbers or
contribution sentence into a search query or a fetched URL.

Work from structured APIs first (fast, gives citation counts and IDs), then targeted web
search for anything missing.

## arXiv API

Categories: cs.AI, cs.LG, cs.CL, cs.CV, cs.CR, cs.SE, cs.DS, …
```
curl -sG "http://export.arxiv.org/api/query" \
  --data-urlencode 'search_query=cat:cs.LG AND all:"speculative decoding"' \
  --data-urlencode 'start=0' --data-urlencode 'max_results=25' \
  --data-urlencode 'sortBy=submittedDate' --data-urlencode 'sortOrder=descending'
```
Fields: `ti:` title, `abs:` abstract, `au:` author, `cat:` category, `all:`. Returns Atom
XML; parse with `"__PYTHON__" -c` or `grep`/`sed`.

## Semantic Scholar Graph API

Best for citation counts, references, and citing papers — use it to find what a seminal
paper led to:
```
curl -sG "https://api.semanticscholar.org/graph/v1/paper/search" \
  --data-urlencode 'query=speculative decoding LLM inference' \
  --data-urlencode 'limit=20' \
  --data-urlencode 'fields=title,year,venue,citationCount,authors,abstract,externalIds,openAccessPdf'
# forward/backward citation walk:
curl -s "https://api.semanticscholar.org/graph/v1/paper/arXiv:2211.17192/citations?fields=title,year,citationCount,venue&limit=50"
curl -s "https://api.semanticscholar.org/graph/v1/paper/arXiv:2211.17192/references?fields=title,year,citationCount,venue&limit=50"
```
If it rate-limits (429), back off once and fall back to WebSearch.

## Other sources, by need

- `openreview.net` — ICLR/NeurIPS submissions *with reviews*; the reviews are often the
  sharpest critique available. API: `https://api2.openreview.net/notes?content.venue=...`
  or fetch the forum page.
- `aclanthology.org` — authoritative for NLP venues (ACL/EMNLP/NAACL/TACL).
- `paperswithcode.com` / GitHub — is there a real implementation? leaderboards.
- `dblp.org/search/publ/api?q=...&format=json` — venue/author disambiguation, and the
  published version of a preprint.
- WebSearch — very recent work, industry tech reports, anything paywalled.

## Coverage discipline

Run several queries with different vocabulary (the field's term, the older term, the
author's term). A topic is under-searched if every hit came from one query. Then do one
citation walk: take the 1–2 most-cited papers and look at what cites them, which surfaces
work published after your search terms were coined. Record the queries you ran — a later
"you missed X" can then be checked against them.

## Reading a paper

Fetch `https://arxiv.org/abs/<id>` for metadata, and `https://arxiv.org/pdf/<id>` or
`https://arxiv.org/html/<id>v1` for the body. Read the paper (abstract + method + results
at minimum), not a blog post or a snippet. For each paper that matters, extract:

- **Problem** it attacks, and why prior work was insufficient (per the authors).
- **Key idea** in one or two sentences, mechanism-level — not the marketing name.
- **Method** — enough to tell it apart from a neighbor's. The assumptions it needs.
- **Evidence** — datasets/benchmarks, baselines, model scale, metrics, headline numbers.
  Ablation? Seed/variance report?
- **Cost** — compute, data, parameters, latency, human labor. Papers routinely bury this.
- **Limitations** — the authors' stated ones plus your own read (weak baselines, eval on
  the training distribution, single seed, unreported hyperparameter search, contamination).
- **Reproducibility** — code? weights? data? or claims only.

Separate what a paper **claims** from what it **shows**, and date everything: say when it
appeared and whether newer work supersedes it.

Downloaded PDFs and parsing scratch go in `${TMPDIR:-/tmp}/research-scratch/`, not the
project.
