# CLAUDE.md — axr

This is the `axr` Claude Code plugin. It scores repositories against the Agent eXecution Readiness (AXR) rubric.

## Contents

- `.claude-plugin/plugin.json` — plugin manifest
- `commands/*.md` — slash command definitions (`/axr`, `/axr-check`, `/axr-diff`, `/axr-fix`)
- `rubric/rubric.v2.json` — versioned rubric, source of truth for scoring (v3.0: 9 dimensions, 45 criteria)
- `rubric/rubric.v1.json` — preserved for history comparison
- `scripts/check-*.sh` — per-dimension deterministic checkers
- `scripts/lib/` — shared bash helpers (common.sh, markdown-helpers.sh, workflow-helpers.sh, tooling-helpers.sh, monorepo-helpers.sh)
- `scripts/axr-ci.sh` — non-interactive CI entry point with config-driven thresholds
- `bin/validate` — plugin-local validator invoked by marketplace `bin/validate` (rubric schema checks)
- `docs/plugin-brief.md` — authoritative spec and operational rules

## Architecture

Scripts-first: per-dimension bash scripts own `checker_type: "mechanical"` criteria and emit per-criterion JSON to stdout, deferring judgment criteria to subagents (Phase 3+). A thin `/axr` command orchestrates them.

Monorepo detection (`scripts/lib/monorepo-helpers.sh`) identifies workspace type (lerna, nx, turbo, pnpm, Gradle, Cargo) and lists packages. Checkers accept `--package <path>` to scope to a single package. The CI script fans out per-package for the 4 per-package dimensions and runs repo-level dimensions once.

## Rubric stability

The rubric is the source of truth. Never edit weights, criteria, or anchor text in place — bump `rubric_version` instead. Trend data depends on version stability.

Current: v3.0 (9 dimensions, 45 criteria). Style & Validation split from Tooling in Phase 2A.

## Testing

This plugin is markdown and JSON. There is no runtime code. "Testing" means:
1. Running marketplace-level `bin/validate`, `bin/lint`, `bin/test` from the repo root
2. Invoking `/axr` against a real target repo and reviewing the output

## Distribution

This plugin ships via the `jerrod/axr` marketplace. Breaking changes to `.axr/latest.json` schema affect downstream consumers (future GitHub App, dashboards).
