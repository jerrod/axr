# sdlc — Full Development Lifecycle with Quality Gates

Brainstorm, plan, pair-build, review, and ship — every gate is a script, every claim is proven.

## Installation

Install via the Codex plugin browser or add this repo as a plugin source.

## Available Skills

All 24 skills are available. Key entry points:

- `$using-sdlc` — Routing layer, loaded at session start
- `$brainstorm` — Design exploration before implementation
- `$writing-plans` — Create implementation plans from specs
- `$pair-build` — Implement plan items with writer + critic pair
- `$review` — Code review before shipping
- `$ship` — Create PR with proof artifacts
- `$dev` — Detect project state and recommend next phase

## Platform Differences

- **Multi-agent workflows run sequentially.** Pair-build (writer + critic), tech-lead orchestration, and subagent-build dispatch agents one at a time instead of in parallel. Output quality is identical; execution is slower.
- **Mock-detection check runs at commit-time** instead of write-time. The inline prompt hook is converted to a script-based check that runs before `git commit`.
- All git-level enforcement hooks (critic approval, push gates, PR gates, merge blocking) work identically on both platforms.
