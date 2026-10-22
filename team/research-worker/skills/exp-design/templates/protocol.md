# Protocol x<k> — <short name>

> Pre-registration. Written before any result exists. Frozen once `approval.md` sits next to
> it; every later change is an amendment in `amendments.md`, approved by the user.

## Claim under test

- **Ledger row:** C<n> — "<the claim, verbatim from claims.md>"
- **Requested by:** <experiment plan row | chair item, quoted verbatim | user request>
- **What this experiment can and cannot establish:** <scope in one or two sentences>

## Prediction

<If the claim holds, what we expect to observe, in numbers where possible.>

## Setup

- **Code:** <repo URL> @ <commit SHA> (entry point: `<script>`)
- **Data:** <dataset, version/hash, splits; which split is the evaluation set>
- **Model(s):** <architecture, size, initialization/checkpoint>
- **Hyperparameters:** <values, and how they were chosen — the same search budget for the
  method and every baseline>
- **Environment:** <device, GPU model, framework versions>

## Baselines

| Baseline | Source (run by us / reported in arXiv:… with setting …) | Tuning | Why a referee would accept it |
|---|---|---|---|
| | | | |

## Metrics

- **Primary:** <metric> — computed by `<script/function>` on <split>. Higher/lower is better.
- **Secondary:** <…> (reported, not used for the criterion)

## Runs

| Run name | What | Seed | Command | GPUs | Max hours |
|---|---|---|---|---|---|
| | | | | | |

- **Seeds:** <n per configuration, fixed list>
- **Retry policy:** <e.g. a run that crashes before step 100 for an infrastructure reason may
  be relaunched once under a new run name; any other failure is reported as is>

## Analysis plan

<Exactly how the numbers become the comparison: aggregate (mean ± std over seeds, median,
…), the statistical test if any, the comparison against each baseline. The analysis script
that will do this: `<name>`.>

## Criteria — fixed now

- **Supports the claim if:** <a concrete, checkable condition on the primary metric>
- **Refutes the claim if:** <a concrete, checkable condition>
- **Inconclusive if:** <everything in between, e.g. difference within seed variance>

## Budget

- **Per run:** max hours × GPUs (table above)
- **Total cap:** <Σ> GPU-hours ≤ approved budget of <B> GPU-hours
- **Expected wall-clock:** <estimate, from the smoke test>

## Risks

<What could go wrong, and what each failure would mean for the claim (e.g. "if the baseline
does not reproduce the reported number within 1 point, the comparison is reported against
our reproduction and flagged").>

## Feasibility checks done

<Smoke tests only: what ran, on what toy input, for how long, what it told us about cost.
No result-bearing runs, never the evaluation set.>
