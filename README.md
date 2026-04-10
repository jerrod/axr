# agent-plugins

Claude Code plugin marketplace by [jerrod](https://github.com/jerrod). Tools for agent-operated software engineering — readiness scoring, code review, and behavioral correction.

## Plugins

### axr — Agent eXecution Readiness scoring

Grades a repository against a 100-point rubric across 12 dimensions using deterministic bash checkers and judgment subagents. Produces a machine-readable JSON report and a human-readable markdown report per run.

See `plugins/axr/README.md` for details.

### revue — Enterprise code review by a four-agent team

Runs four specialized reviewers — **architect**, **security**, **correctness**, **style** — against a pull request diff in parallel, then aggregates findings into a single verdict with deduplication and severity sorting.

> **⚠ Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.** revue depends on Claude Code's experimental agent-team feature to spawn its four reviewers concurrently. Without this env var set, the `review-pr` skill cannot dispatch subagents. Add the export to your shell profile so every session has it:
>
> ```bash
> export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
> ```

See `plugins/revue/README.md` for details.

### therapist — Diagnose and fix persistent rationalization patterns

A CBT-adapted intervention framework for sessions where Claude repeatedly violates explicit rules. Bundles a `/therapist` slash command, ambient hooks that catch rationalization phrases live at `Write`/`Edit`/`Bash` tool use, and a reference toolbox of eleven techniques.

See `plugins/therapist/README.md` for details.

### sdlc — Full development lifecycle with executable quality gates

Enforces the brainstorm → plan → pair-build → review → ship workflow with 24 skills, 23 subagents, 8 lifecycle hooks, and executable gates at every checkpoint. File size, coverage, complexity, lint, and test-quality are all script-verified. PR descriptions embed proof artifacts any reviewer can independently re-run. Hard fork of [`arqu-co/rq`](https://github.com/arqu-co/claude-skills/tree/main/plugins/rq) at v1.29.8.

See `plugins/sdlc/README.md` for details.

## Quickstart

```bash
# Install the marketplace in Claude Code
# /plugin → Add Marketplace → jerrod/agent-plugins

# Validate the marketplace + every plugin
bin/validate

# Run linting (shellcheck + JSON + frontmatter)
bin/lint

# Run tests (validates all checkers produce schema-valid JSON)
bin/test
```

## Installation

In Claude Code:

1. `/plugin` → Add Marketplace → `jerrod/agent-plugins`
2. Choose the plugin(s) you want to install
3. **For revue:** also set `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your shell profile

## For contributors

The marketplace is structured as:

- `plugins/<name>/` — each plugin self-contained (manifest, commands/skills/agents, scripts, docs, README, CLAUDE.md)
- `bin/` — marketplace-level gate scripts that validate every plugin
- `.claude-plugin/marketplace.json` — marketplace manifest

Plugins may use any of `commands/`, `skills/`, or `agents/` as their entry point. `scripts/` is optional (agent-team plugins like revue have none).

See `CLAUDE.md` for workflow conventions. All changes go through the rq workflow: plan → build → review → ship.
