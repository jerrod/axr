# axr

Claude Code plugin (`axr`) that scores a repository's **Agent eXecution Readiness** against a defined rubric.

Distributed alongside target-org's `rq` plugin. Produces a human-readable report and a machine-readable JSON artifact per run, stored in `.axr/`.

## Status

v1 in development. See the implementation brief and plan for scope.

## Commands (planned)

- `/axr` — Run full assessment on current repo
- `/axr-check <dimension>` — Run only one dimension
- `/axr-diff` — Compare current score to previous run

## Rubric

100 points across 8 dimensions, scored 0–4 per criterion. See `rubric/rubric.v1.json` once implemented.
