# axr — Agent eXecution Readiness Scorer

Scores repositories against a 100-point rubric across 12 dimensions with deterministic bash checkers and judgment agents.

## Installation

Install via the Codex plugin browser or add this repo as a plugin source.

## Available Skills

- `$axr` — Score the current repository against the full AXR rubric (all 12 dimensions).
- `$axr-check` — Re-run a single dimension checker and update .axr/latest.json incrementally.
- `$axr-diff` — Compare two AXR scoring runs and surface what changed.
- `$axr-fix` — Fix low-scoring AXR criteria by applying automated remediations.
- `$axr-badge` — Generate an AXR score badge for your README.

## Platform Differences

On Codex, dimension reviewer agents run sequentially rather than in parallel. Scoring output is identical. The review takes longer but produces the same 12-dimension assessment.
