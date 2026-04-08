# CLAUDE.md — therapist

This is the `therapist` Claude Code plugin. It diagnoses and interrupts rationalization patterns that cause Claude to repeatedly violate explicit rules.

## Contents

- `.claude-plugin/plugin.json` — plugin manifest
- `commands/therapist.md` — `/therapist` slash command (wraps the skill)
- `skills/therapist/SKILL.md` — full CBT-adapted intervention runbook
- `hooks/hooks.json` — SessionStart / PreToolUse / PostToolUse hook wiring
- `scripts/*.sh` — hook scripts, library helpers, and tests
- `references/*.md` — CBT framework, distortion catalogue, exposure deck, exemplars, toolbox guide

## Architecture

The plugin is hook-driven. Ambient hooks fire on tool use and shell out to scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/`. Scripts read / write state under `.therapist/` in the target repo so analytics, journal entries, and graduation state persist across sessions. The `/therapist` command and the `therapist` skill are the explicit entry points when a user reports misbehavior directly.

## Script conventions

- Scripts prefixed with `_` (e.g. `_lib.sh`, `_lib_analytics.sh`, `_lib_queries.sh`, `_journal_cmds.sh`) are libraries meant to be sourced, not invoked directly.
- Scripts prefixed with `test_` are bash test harnesses and safe to run standalone.
- All scripts resolve paths via `${CLAUDE_PLUGIN_ROOT}` so they do not depend on install location.
- All scripts must be executable (`chmod +x`) — the marketplace validator enforces this.

## Safety

Hooks run at `PreToolUse` for `Write|Edit` and for `git commit|git push`. They are interrupts, not blockers — they surface rationalization patterns via stderr without failing the tool call. If a script ever exits non-zero from a hook, investigate before silencing: a failing hook is a real signal, not noise.

## Source

This plugin was ported from `arqu-co/claude-skills` into the `jerrod/axr` marketplace. Keep behavioral parity with the upstream plugin; do not drift the toolbox, rubric of distortions, or hook dispatch without re-syncing.
