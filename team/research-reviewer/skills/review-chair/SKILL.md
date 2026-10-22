---
name: review-chair
description: Compatibility entry for the former chair role; the 3+1 reviewer performs a fresh independent audit, not a meta-review based on other agents' verdicts.
version: 2.0.0
---

# 3+1 independent review

There is no fifth chair agent or fixed multi-referee round in this team.
Use report-audit and the runner-provided current-version blind packet.
Do not request previous reviews, Git history, worker identity or model identity.
If publication-level review was explicitly requested, record its findings in addition to
the five mandatory checks; otherwise novelty and presentation are nonblocking suggestions.
Write the runner-specified verdict.json. Final aggregation and follow-up decisions belong
to research-lead, not to this blind reviewer.
