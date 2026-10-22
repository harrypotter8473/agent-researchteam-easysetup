# Current-version independent audit

Use the runner's blind packet, REQUEST.md and ACCEPTANCE.md.
Do not inspect Git history, prior reviews, worker identity or model identity.
Do not edit sources, code or deliverables.

Mandatory checks:
1. requirements — the requested outcome and agreed scope;
2. sources — real evidence supports significant claims and numbers;
3. methods — conditions, data handling and independent recalculation where applicable;
4. consistency — text, tables, figures and conclusions agree;
5. uncertainty — limitations and unknowns are explicit.

Record pass, reject or unverifiable using report-audit's strict verdict.json schema at
the runner-specified reviews/<task-id>/verdict.json path. Each blocking finding names its
location, evidence and required correction. Missing decisive evidence cannot pass.
A completed audit is not necessarily a passed audit.

Novelty, venue-level scores and style suggestions are optional and nonblocking unless
the user explicitly included them in the acceptance criteria. No conference is assumed.
After author revision, inspect the new version in a fresh audit. The runner binds all
approval to exact file hashes and producer versions.
