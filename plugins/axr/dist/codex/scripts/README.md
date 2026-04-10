# scripts/

Executable bash scripts for scoring, aggregation, and CI.

| Script | Purpose |
|--------|---------|
| `check-*.sh` (9) | Per-dimension mechanical checkers. Each scores 5 criteria, emits JSON to stdout. |
| `aggregate.sh` | Reads dimension JSONs, computes weighted scores/band/blockers, writes `.axr/latest.{json,md}` |
| `merge-agents.sh` | Overlays agent-draft scores onto mechanical dimension JSONs |
| `patch-dimension.sh` | Replaces one dimension's scores incrementally (used by `/axr-check`) |
| `render-report.sh` | Template rendering for `.axr/latest.md` (sourced by aggregate.sh) |
| `diff-scores.sh` | Compares two scoring JSONs, outputs structured delta |
| `axr-ci.sh` | CI fast-path: mechanical-only scoring with monorepo fan-out and configurable threshold |

All checkers source `lib/common.sh` and accept `--package <path>` for monorepo per-package scoring. See `lib/README.md` for the shared helper library.
