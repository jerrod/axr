---
description: Re-run a single dimension checker against the current repo (scheduled for Phase 2).
argument-hint: "<dimension-id>"
---

`/axr-check` is scheduled for **Phase 2** of the axr plugin. Once the eight dimension checkers land, this command will accept a single dimension id (for example `docs_context`, `tests_ci`, `safety_rails`) and re-run only that checker, updating the corresponding slice of `.axr/latest.json` without re-scoring the rest of the repo.

For Phase 1, use `/axr` — it exercises the orchestrator end-to-end against the one dimension that currently has a deterministic checker (`docs_context`). When all eight scripts exist, this command will be implemented as a thin wrapper around the same orchestration logic.
