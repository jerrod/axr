# CLAUDE.md — agent-plugins marketplace

This repo is a Claude Code plugin marketplace named `agent-plugins`. It currently hosts `axr`, `revue`, and `therapist`, with room for more plugins.

## Layout

- `.claude-plugin/marketplace.json` — marketplace manifest listing all plugins
- `plugins/<name>/` — each plugin self-contained (manifest, commands, scripts, docs, README, CLAUDE.md)
- `bin/` — marketplace-level gate scripts that validate every plugin
- `rq.config.json` — rq gate thresholds

## Workflow

All work uses the rq plugin: `/rq:writing-plans` → `/rq:pair-build` → `/rq:review` → `/rq:ship`. Never commit directly to main. Every change goes on a feature branch with a plan.

## Gates

- `bin/validate` — marketplace manifest + every plugin's manifest, rubric, commands, and script executability
- `bin/lint` — shellcheck on every script under `bin/`, `plugins/*/scripts/`, and `plugins/*/bin/`; jq parse on every `*.json`; YAML frontmatter check on every `plugins/*/commands/*.md`
- `bin/test` — runs `bin/validate` plus every plugin's `scripts/check-*.sh`, verifies each emits schema-valid JSON

Always use the `bin/` scripts — never run the underlying tools directly.

## Adding a new plugin

All paths here are **repo-root-relative** (paths inside a plugin's own docs are plugin-root-relative).

1. Create `plugins/<new-name>/` with its own `.claude-plugin/plugin.json`, `commands/`, `scripts/`, `docs/`, `README.md`, `CLAUDE.md`.
2. Add an entry to `.claude-plugin/marketplace.json` under `plugins[]` including `name`, `description`, `source` (relative path starting `./`), and `category`.
3. If the plugin needs schema checks the marketplace validator doesn't cover (e.g., rubric integrity), add an executable `plugins/<new-name>/bin/validate` — marketplace `bin/validate` will invoke it automatically.
4. Run `bin/validate` at repo root to confirm the new plugin integrates.

## Agent Boundaries

**Agents SHOULD:** write code, run bin/ gate scripts, create feature branches, create PRs, run `/axr` scoring.

**Agents MUST NOT:** push directly to main, delete branches without confirmation, modify `.claude-plugin/marketplace.json` plugin entries without review, edit rubric JSON files in place (bump version instead), run `git push --force` to main.

**Review checkpoints:** all PRs require human merge approval. The rq workflow enforces build → review → ship with proof at each stage.

## Rubric stability (plugins that carry rubrics)

Rubrics are versioned source-of-truth documents. Never edit weights, criteria, or anchor text in place — bump `rubric_version` instead. Trend data depends on version stability.
