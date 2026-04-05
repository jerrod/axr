# axr

Claude Code plugin marketplace by [jerrod](https://github.com/jerrod).

## Plugins

### axr

Agent eXecution Readiness scoring. Grades a repository against a 100-point rubric across 8 dimensions (tests & CI, docs, change surface, safety rails, structure, tooling, execution visibility, workflow realism) using deterministic bash checkers and judgment subagents. Produces a machine-readable JSON report and a human-readable markdown report per run.

See `plugins/axr/README.md` for details.

## Installation

In Claude Code:

1. `/plugin` → Add Marketplace → `jerrod/axr`
2. Choose the plugin(s) you want to install

## For contributors

The marketplace is structured as:

- `plugins/<name>/` — each plugin self-contained
- `bin/` — marketplace-level gate scripts
- `.claude-plugin/marketplace.json` — marketplace manifest

See `CLAUDE.md` for workflow conventions. All changes go through the rq workflow: plan → build → review → ship.
