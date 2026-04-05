# CLAUDE.md — axr

This is the `axr` Claude Code plugin. It scores repositories against the Agent eXecution Readiness (AXR) rubric.

## Contents

- `.claude-plugin/plugin.json` — plugin manifest
- `commands/*.md` — slash command definitions (`/axr`, `/axr-check`, `/axr-diff`)
- `rubric/rubric.v1.json` — versioned rubric, source of truth for scoring
- `scripts/check-*.sh` — per-dimension deterministic checkers
- `scripts/lib/` — shared bash helpers (common.sh, markdown-helpers.sh, shell-helpers.sh)
- `docs/plugin-brief.md` — authoritative spec and operational rules

## Architecture

Scripts-first: per-dimension bash scripts own `checker_type: "mechanical"` criteria and emit per-criterion JSON to stdout, deferring judgment criteria to subagents (Phase 3+). A thin `/axr` command orchestrates them.

## Rubric stability

The rubric is the source of truth. Never edit weights, criteria, or anchor text in place — bump `rubric_version` instead. Trend data depends on version stability.

## Testing

This plugin is markdown and JSON. There is no runtime code. "Testing" means:
1. Running marketplace-level `bin/validate`, `bin/lint`, `bin/test` from the repo root
2. Invoking `/axr` against a real target repo and reviewing the output

## Distribution

This plugin ships via the `jerrod/axr` marketplace. Breaking changes to `.axr/latest.json` schema affect downstream consumers (future GitHub App, dashboards).
