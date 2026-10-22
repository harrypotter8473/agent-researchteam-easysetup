# Shared reports

**Sensitivity:** public

Only public authorized material belongs here. Confidential requests need their own
project and a suitable configured local model route; never silently downgrade sensitivity.

Each request has a unique topic slug. Do not overwrite another request.
- notes/<slug>/brief.md: exact request, scope, acceptance criteria (lead).
- notes/<slug>/: search/extraction records (scout).
- sources/<slug>/: original evidence and provenance (scout).
- reports/<slug>/: analysis, written report and revisions (worker).
- evidence/<slug>/, experiments/<slug>/: calculations, code and output (worker).
- reviews/<audit-task-id>/verdict.json: structured independent audit (reviewer).
- .tasks/: runner-managed tasks, checkpoints, hash-chain ledger and audit receipts.

Load research-orchestrate for the runtime protocol. Dependent work requires current-version
intermediate audit approval. Final delivery requires final approval and downloaded-file
hash verification. Audit done does not mean pass. Never copy another request's approval.
