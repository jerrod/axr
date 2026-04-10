# sdlc

Full development lifecycle with executable quality gates. Brainstorm, plan, pair-build, review, and ship — every gate is a script, every claim is proven.

`sdlc` is the agent-plugins marketplace's own branded full-lifecycle plugin: 24 user-facing skills, 23 specialized subagents, 50 shell scripts + 62 Python scripts, and 8 lifecycle hooks that enforce discipline at every Claude Code session.

## What it does

- **Skills cover every phase of development:**
  - `/sdlc:brainstorm` — product/engineering/design persona debate → spec
  - `/sdlc:writing-plans` — spec → bite-sized TDD implementation plan
  - `/sdlc:pair-build` — writer + critic pairs implement plan items
  - `/sdlc:review` — four specialized reviewers (architect, security, correctness, style) walk findings
  - `/sdlc:ship` — full PR lifecycle with embedded quality proof
  - `/sdlc:dev` — state-detection orchestrator that routes you to the right phase
  - Plus: `/sdlc:qa`, `/sdlc:design-audit`, `/sdlc:threat-model`, `/sdlc:investigate`, `/sdlc:finish-branch`, and more
- **Agents enforce standards:** file size (300 lines), function length (50 lines), cyclomatic complexity (<8), test coverage (95%), lint/format/typecheck (zero errors), mock policy (boundaries only), plan-proof-anchored commits.
- **Hooks keep you honest:** SessionStart auto-loads the routing discipline layer; PreToolUse blocks git commit without a plan checkpoint, git push without review proof, and `gh pr create` without PROOF.md; PostToolUse catches rationalization patterns in real time.
- **Gates are executable, not advisory:** every quality claim in a PR is backed by a proof artifact (`.quality/proof/*.json`) any reviewer can re-run and verify.

## Installation

In Claude Code:

1. `/plugin` → Add Marketplace → `jerrod/agent-plugins`
2. Enable `sdlc` in the plugin list

## Configuration

`sdlc` reads per-repo gate thresholds from `sdlc.config.json` at the repo root. Default thresholds:

| Metric | Threshold |
|---|---|
| Line coverage | 95% per file |
| File size | 300 lines |
| Function length | 50 lines |
| Cyclomatic complexity | 8 |
| Lint/format/typecheck | zero errors |

Create `sdlc.config.json` at your repo root to override thresholds (see [this repo's sdlc.config.json](../../sdlc.config.json) for an example). Without it, built-in defaults apply.

## Skills inventory

Run `/sdlc:using-sdlc` at session start (the SessionStart hook does this automatically) to load the routing table. Full skill catalog documented at `skills/using-sdlc/SKILL.md`.

## Origin

`sdlc` is a hard fork of [arqu-co/claude-skills/plugins/rq](https://github.com/arqu-co/claude-skills/tree/main/plugins/rq) at v1.29.8, renamed end-to-end and adopted as the agent-plugins marketplace's own full-lifecycle plugin. See `CLAUDE.md` for the full rename mapping and drift status.
