---
name: exp-run
description: How research-worker executes an approved, frozen protocol — launch mode (verify approval, check out the pinned code, smoke-test, start every run as a capped detached job with launch.py, record runs.md) and collect mode (gather every run into evidence/, compute the analysis with a saved script, compare mechanically against the pre-written criteria in result.md). Used by research-worker in launch and collect tasks.
version: 1.0.0
metadata:
  hermes:
    tags: [research, experiments]
    category: research-papers
    requires_toolsets: [terminal]
---

# Running an approved experiment

Scripts (no scheduler needed; the job format is scheduler-agnostic):

```bash
LAUNCH=(env RESEARCH_TEAM_HOME="__TEAM_HOME__" "__PYTHON__" "__SKILLS_DIR__/exp-run/scripts/launch.py")
JOBSTAT=(env RESEARCH_TEAM_HOME="__TEAM_HOME__" "__PYTHON__" "__SKILLS_DIR__/exp-run/scripts/jobstat.py")
"${LAUNCH[@]}" x1 seed0-method --max-hours 6 --gpus 0 --cwd <code checkout> -- python train.py --seed 0 ...
"${JOBSTAT[@]}" x1            # state of every run: running / done / failed / capped / lost
```

Run both from the paper folder (your working directory) — the paper name comes from it.

## Launch mode (`x<k>-launch`)

1. **Check the approval.** `experiments/x<k>/approval.md` must exist, and its last protocol
   line must name the current protocol: compare its blob hash with
   `git rev-parse HEAD:experiments/x<k>/protocol.md`. Missing or different → `STATUS:
   blocked — protocol x<k> not approved`. Launch nothing.
2. **Read the protocol and any approved amendments** (`amendments.md` entries that
   `approval.md` lists). That is the complete specification. Nothing else is.
3. **Check out the pinned code** at the protocol's commit, in its own directory
   (`~/.hermes-research-team/code/<repo>@<short-sha>`), clean. Set up the environment it needs.
4. **Smoke-test** one run's command for a few steps on toy input, to catch a broken
   environment before hours of compute. Discard its output.
5. **Check the machine:** free GPUs (`nvidia-smi`), disk for outputs, jobs already running
   (`"${JOBSTAT[@]}"`). If the runs cannot all start (not enough GPUs), start what fits and list
   the rest under **Queued** in `runs.md` — the collect task starts them when GPUs free up.
   Do not stack jobs on a busy GPU unless the protocol says so.
6. **Launch every run exactly as listed** — the protocol's run name, command, GPUs and
   `--max-hours`. The only permitted substitutions are local paths. Anything else that
   must differ (a flag that no longer exists, an OOM at the stated batch size) is an
   amendment: write it to `amendments.md` and block **before** launching anything.
7. **Write `experiments/x<k>/runs.md`:** for each run the name, exact command, seed, GPUs,
   cap, job directory, start time; the code commit and whether the checkout was clean;
   environment (Python, framework, CUDA, GPU model); the budget committed (Σ cap × GPUs).
8. Report the jobs started and the budget committed. `STATUS: done`. Do not wait for the
   jobs — the collect task starts by itself when they finish.

## Collect mode (`x<k>-collect`)

1. **Queued runs first.** If `runs.md` lists runs under **Queued**, launch them now exactly
   as in launch mode (step 6), move them to the launched list, and block with `STATUS:
   blocked — launched queued runs <names>; re-queue collect`. The lead sets this task ready
   again and it waits for those jobs by itself.
2. `"${JOBSTAT[@]}" x<k> --json` — every run and its state. Every run appears in the evidence and
   the result, including `failed`, `capped` and `lost` ones. **Retry only per the protocol's
   retry policy**, under a new run name, then block the same way (`relaunched <runs> per
   retry policy; re-queue collect`). Anything outside the policy is an amendment.
3. **Build `evidence/<YYYY-MM-DD>-x<k>/`** following the paper's evidence conventions
   (`CLAUDE.md`): per run its `meta.json`, config, `metrics.json` (as the code wrote it),
   `stdout.log`/`stderr.log` (the last 5 MB each if larger), exit code. Large artifacts
   (checkpoints, predictions) stay on this machine or in object storage: list them in
   `artifacts.txt` with path, size and sha256.
4. **Write the analysis script** into the evidence folder (`analysis.py`) implementing the
   protocol's analysis plan exactly, reading only the evidence folder. Run it; save its
   output as `analysis.json` and the table it prints. Numbers are never transcribed by hand.
5. **Write `experiments/x<k>/result.md`:**
   - the per-run table and the aggregate, as produced by `analysis.py`;
   - each pre-written criterion (supports / refutes / inconclusive) copied verbatim, with
     **MET / NOT MET** and the numbers that decide it — one verdict overall;
   - deviations: every amendment, every failed / capped / lost run and what its absence
     does to the analysis;
   - the evidence path.

   No statement about the paper's claim beyond the criterion verdict. No adjectives.
6. Report the verdict in one line and the failed runs. `STATUS: done`.
