# CLAUDE.md — axr

This repo is the source of the `rq-axr` Claude Code plugin. The plugin scores repositories against the Agent eXecution Readiness rubric.

## What this repo contains

- `.claude-plugin/plugin.json` — plugin manifest
- `commands/*.md` — slash command definitions (`/axr`, `/axr-check`, `/axr-diff`)
- `rubric/rubric.v1.json` — versioned rubric, source of truth
- `checkers/*.md` — scoring prompts (mechanical + judgment)
- `templates/*.template` — output formats

The plugin itself is markdown and JSON. There is no runtime code to compile or test. "Testing" means invoking `/axr` against a real repo and reviewing the output.

## Workflow

All work uses the rq plugin: `/rq:writing-plans` → `/rq:pair-build` → `/rq:review` → `/rq:ship`. Even small changes go on a feature branch with a plan. Never commit to main.

## Gate discipline (adapted for a plugin repo)

Traditional code gates (coverage %, cyclomatic complexity, test presence) do not apply to markdown/JSON plugin content. The relevant gates here are:

- **Structure:** `plugin.json` is valid and conforms to Claude Code plugin schema
- **JSON validity:** all `.json` files parse cleanly
- **Rubric integrity:** rubric totals equal 100 pts, every criterion scored 0–4, every dimension has explicit weight
- **Command frontmatter:** every `commands/*.md` has valid frontmatter
- **Lint:** markdown renders cleanly; no broken internal links

When `bin/lint` and `bin/validate` exist, ALWAYS use them.

## Rubric changes

The rubric is the source of truth. Never edit weights, criteria, or anchor text in place — bump `rubric_version` instead. Trend data depends on version stability.

## Testing the plugin

To verify a change works, run `/axr` against a target repo (typically an ARQU repo) and compare the output to expectations. Manual verification is the only test.

## Distribution

This plugin ships via ARQU's managed settings alongside `rq`. Breaking changes to output format (`result.json` schema) affect downstream consumers (future GitHub App, dashboards).

## Quality Gates (rq)

This project uses rq quality gates. Before your first code change in any session, detect the gate scripts:

```bash
PLUGIN_DIR=$(find . -path "*/rq/scripts/run-gates.sh" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -path "*/rq/scripts/run-gates.sh" -exec dirname {} \; 2>/dev/null | head -1)
fi
```

Run `bash "$PLUGIN_DIR/run-gates.sh" all` before any commit or push. Gate scripts produce proof artifacts in `.quality/proof/` — use these instead of manual quality checks.

**Project-specific gate mapping:**
- `bin/lint` → shellcheck on scripts + jq parse on JSON + YAML frontmatter on `commands/*.md`
- `bin/test` → runs `bin/validate` + schema-invariant check on each `scripts/check-*.sh` JSON output
- `bin/validate` (human-facing debug tool) — verbose per-check pass/fail listing
- No `bin/typecheck`, `bin/coverage`, or `bin/format` — project is bash + JSON + markdown with no language runtime
