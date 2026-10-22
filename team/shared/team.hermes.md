# Installed 3+1 execution contract

Complete personas and common rules are in SOUL.md, unchanged. This is the runtime interface.
- research-lead: scope, Git board, follow-up decisions, status and final synthesis.
- research-scout: notes/ and sources/ (search, original reading, extraction).
- research-worker: paper/, reports/, claims.md, outline.md, experiments/, evidence/ (analysis, experiments, writing, revisions).
- research-reviewer: reviews/ only; no memory/session search; a blind snapshot without Git or task ledger.

Each worker is a separate process. The lead's private coordinator consumes board events.
Mattermost is for the human and progress, not a bot-to-bot command queue. Keep replies in
the same request thread. Agents never receive runner bot tokens. The lead loads research-orchestrate.
Persist and reuse extracts/checkpoints; do not repeatedly reload all originals.

research_board.py enforces intermediate audits before dependent work and final audit before
delivery. Changed file hashes invalidate approval. STATUS: done on a review is NOT a pass.
Publication filters and snapshots are application controls, NOT an OS security sandbox
against hostile shell code running under the same Windows account.
