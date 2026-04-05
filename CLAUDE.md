# CLAUDE.md — axr marketplace

This repo is a Claude Code plugin marketplace. It currently hosts `rq-axr` with room for more plugins.

## Layout

- `.claude-plugin/marketplace.json` — marketplace manifest listing all plugins
- `plugins/<name>/` — each plugin self-contained (manifest, commands, scripts, docs, README, CLAUDE.md)
- `bin/` — marketplace-level gate scripts that validate every plugin
- `rq.config.json` — rq gate thresholds

## Workflow

All work uses the rq plugin: `/rq:writing-plans` → `/rq:pair-build` → `/rq:review` → `/rq:ship`. Never commit directly to main. Every change goes on a feature branch with a plan.

## Gates

- `bin/validate` — marketplace manifest + every plugin's manifest, rubric, commands, and script executability
- `bin/lint` — shellcheck on every script under `bin/` and `plugins/*/scripts/`, jq parse on every `*.json`, YAML frontmatter check on every `plugins/*/commands/*.md`
- `bin/test` — runs `bin/validate` plus every plugin's `scripts/check-*.sh`, verifies each emits schema-valid JSON

Always use the `bin/` scripts — never run the underlying tools directly.

## Adding a new plugin

1. Create `plugins/<new-name>/` with its own `.claude-plugin/plugin.json`, `commands/`, `scripts/`, `docs/`, `README.md`, `CLAUDE.md`.
2. Add an entry to `.claude-plugin/marketplace.json` under `plugins[]`.
3. Run `bin/validate` to confirm the new plugin integrates.

## Rubric stability (plugins that carry rubrics)

Rubrics are versioned source-of-truth documents. Never edit weights, criteria, or anchor text in place — bump `rubric_version` instead. Trend data depends on version stability.
