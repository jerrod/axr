---
description: Show dimension-level score changes between two AXR runs (scheduled for Phase 4).
argument-hint: "[<from-sha>] [<to-sha>]"
---

`/axr-diff` is scheduled for **Phase 4** of the rq-axr plugin. Once `.axr/history/` archival lands, this command will compare two runs (by sha, timestamp, or file path) and surface which dimensions moved, which criteria flipped, and which blockers were resolved or introduced.

For Phase 1, use `/axr` — it runs the orchestrator against the current working tree and prints a summary table. Diff semantics require at least two historical runs on disk, which Phase 1 does not yet produce.
