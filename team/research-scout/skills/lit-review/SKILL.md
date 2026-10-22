---
name: lit-review
description: How research-scout turns searched papers into a literature review — group by approach, trace lineage, compare on a common axis, consensus vs. disputes, open problems — and the report format. Used in discovery mode (lit reviews, state of the art, prior art for a new paper). Used by research-scout, discovery mode; research-lead creates a board task for that agent rather than running this itself.
version: 1.0.0
metadata:
  hermes:
    tags: [research, literature]
    category: research-papers
    requires_toolsets: [web]
---

# Literature review

Search and read per `lit-search` first (auto-loaded). Then synthesize — do not hand back a stack of
summaries.

## Scope before depth

When a topic is much larger than one review can hold, say so early, propose a scoping
(subfield, time window, or specific question), and deliver the best review of the narrowed
scope rather than a thin skim of everything. Adapt depth to the ask — "find me the paper on
X" gets a short answer; "review the literature on X" gets the full structure below.

When the request is **prior art for a paper we are writing**, aim at the 5–10 papers closest
to the candidate contribution, and for each state the mechanism-level difference. Say
plainly if one of them already does it.

## Analysis across papers

- **Group by approach**, not chronology — rival families of solution, with the tradeoff axis
  that separates them named explicitly.
- **Trace the lineage**: which paper introduced the idea, which refined it, which
  contradicted it. Disagreements are the most useful thing you can surface — when two
  papers report conflicting results, dig into the experimental difference that explains it.
- **Compare on a common axis** where the papers permit it (same benchmark). When results are
  not comparable, say so rather than tabling numbers that mislead.
- **Consensus vs. contested**: what is settled, what is actively disputed, what is untested.
- **Open problems** and where the field is heading.

## Report format

```
## <Topic> — <N> papers reviewed, as of <date>

**Bottom line:** 2-4 sentences. What someone working on this needs to know.

### Landscape
Approach families and the tradeoff that separates them.

### Key papers
For each — grouped by family, most important first:

**<Title>** (<first author> et al., <venue> <year>) — arXiv:<id>
- Idea: ...
- Method: ...
- Results: <numbers, on which benchmark, vs. which baseline>
- Limitations: ...
- Code: <link or "none released">

### Comparison
Table when the papers share a benchmark; prose when they do not.

### Consensus and disputes
### Open problems
### Reading order
3-5 papers for someone starting here, and why that order.

### Coverage
Queries and sources used; what was not covered.
```

Write the report into the project only when asked for a saved report (e.g.
`notes/prior-art.md`); when asked, also save verified BibTeX for every paper named,
built from the API record, never typed from memory.
