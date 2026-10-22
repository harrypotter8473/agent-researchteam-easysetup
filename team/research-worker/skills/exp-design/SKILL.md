---
name: exp-design
description: How research-worker writes an experiment protocol — a pre-registration that fixes the claim under test, setup, baselines, metric, seeds, runs, analysis plan, budget and the support/refute criteria before any result exists. Writes experiments/x<k>/protocol.md from templates/protocol.md. Used by research-worker in a design task; research-lead creates the task rather than designing experiments itself.
version: 1.0.0
metadata:
  hermes:
    tags: [research, experiments]
    category: research-papers
    requires_toolsets: [terminal]
---

# Designing an experiment

Output: one file, `experiments/x<k>/protocol.md`, filled from
`__SKILLS_DIR__/exp-design/templates/protocol.md`. Every section filled; a section that
does not apply says why.

## Inputs — read first

1. `CLAUDE.md` — venue, notation, claims the project will not make, **Code repo** (the URL
   of external experiment code, only if actually needed). For supplied data or self-contained analysis, write the code locally; ask only when a missing external dependency is essential.
2. `claims.md` — the ledger row(s) the task names, and its **Experiment plan** row: the
   planned setup and refutation criterion written with the user. Your protocol makes that
   plan executable; it does not replace its criterion with a weaker one. If the plan's
   criterion is not checkable as written, sharpen it and say so in the report.
3. The source the task quotes — a chair's EVIDENCE-NEEDED item, a referee's question — and
   `notes/prior-art.md` for the baselines a referee in this subfield expects.
4. The code: clone the repo (under `~/.hermes-research-team/code/`), pick the commit to pin, read the
   entry point, the config, the data loading and the metric implementation. A metric you
   have not read the code of is a metric you cannot vouch for.
5. The budget cap in the task (GPU-hours) and this machine: `nvidia-smi` (or the platform
   equivalent), free disk, what is already running (`jobstat.py`).

## Procedure

1. **Name the claim and its scope.** Quote the ledger row verbatim. Say what a positive
   result would and would not establish ("establishes the gain on X at 7B; says nothing
   about scale").
2. **Choose baselines a referee would accept.** The strongest reasonable ones, not the
   easiest to beat. Same tuning budget as the method. A number taken from a paper is only
   comparable if the setting matches — state the setting, with the paper's arXiv ID from a
   search (per `lit-search`); otherwise run it.
3. **One primary metric,** computed by code you have read, on a split the method never
   trained or tuned on. Secondary metrics are reported, not decisive.
4. **Seeds and runs.** Enough seeds that the effect you predict is larger than seed
   variance (three is a floor, not a default, when margins are small). List every run with
   its exact command, GPUs and `--max-hours` cap. Include a retry policy.
5. **Analysis plan** precise enough that two people would compute the same number: the
   aggregate, the test, the comparison. It will be executed by a script at collect time.
6. **Criteria, written now:** supports / refutes / inconclusive, each a checkable condition
   on the primary metric. "Inconclusive" must exist — it is what a small, noisy effect is.
7. **Budget:** Σ over runs of cap × GPUs, within the task's cap. If the experiment that
   would settle the claim does not fit, say so and propose the smallest design that does,
   plus what it would leave unsettled. Never quietly shrink seeds or baselines to fit.
8. **Feasibility, smoke tests only:** a few steps on toy input to confirm the code runs and
   to time a step. Never the evaluation set, never a result-bearing run, outputs discarded.

## Before you finish

- Could a referee object that the baseline is weak, the metric is gamed, the split leaks, or
  the seeds are too few for the margin? Fix it now or name it under Risks.
- Does the "refutes" criterion describe an outcome that could actually happen with this
  design? A criterion that cannot fail is not a criterion.
- Report: runs (count), GPU-hours, the three criteria in one line each, anything you
  assumed. `STATUS: done`.
