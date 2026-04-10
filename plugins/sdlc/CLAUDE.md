# CLAUDE.md — sdlc

This is the `sdlc` Claude Code plugin. It enforces a full development lifecycle with executable quality gates: brainstorm → plan → pair-build → review → ship, with hooks blocking every shortcut in between.

## Contents

- `.claude-plugin/plugin.json` — plugin manifest
- `commands/sdlc-update.md` — single slash command (self-update probe)
- `skills/<name>/SKILL.md` — 24 user-facing skills
- `agents/<name>.md` — 23 specialized subagents
- `hooks/hooks.json` + `hooks/*` — 8 lifecycle hooks
- `scripts/*.sh` (50) — gate scripts and utilities
- `scripts/*.py` (62) — gate helpers and test suite
- `scripts/test_*.{sh,py}` (47) — test files

## Origin: hard fork of upstream `rq` v1.29.8

`sdlc` is a **hard fork** of [arqu-co/claude-skills/plugins/rq](https://github.com/arqu-co/claude-skills/tree/main/plugins/rq) at v1.29.8. Unlike the `revue` port (which stays byte-identical with upstream), sdlc is deliberately diverged and does NOT maintain parity with the upstream rq plugin. Upstream changes are NOT back-ported. The fork evolves independently.

### Rename mapping

Every user-visible and internal reference changed during the fork:

| Upstream | sdlc |
|---|---|
| `plugin.json` name `rq` | `sdlc` |
| Slash commands `/rq:foo` | `/sdlc:foo` |
| Subagent types `rq:foo` | `sdlc:foo` |
| Plugin paths `plugins/rq/` | `plugins/sdlc/` |
| Env vars `RQ_*` (30+ distinct) | `SDLC_*` (EXCEPT `RQ_METRICS_DIR` which is a user-scoped env var unrelated to plugin identity) |
| Config file `rq.config.json` | `sdlc.config.json` |
| State dir `~/.claude/plugins/data/rq` | `~/.claude/plugins/data/sdlc` |
| Visual-companion dir `.rq/brainstorm/` | `.sdlc/brainstorm/` |
| Skill dir `skills/using-rq/` | `skills/using-sdlc/` |
| Script `rq-update.sh` | `sdlc-update.sh` |
| Schema `schemas/rq-config.json` | `schemas/sdlc-config.json` |
| Command `commands/rq-update.md` | `commands/sdlc-update.md` |

### Cross-platform test fixes applied

Three upstream tests had pre-existing macOS compatibility issues that were fixed during the port:

1. **`test_audit_trail.sh` flock dependency.** The "Log command" tests read `trail.json` directly after calling `audit-trail.sh log`, which only works on Linux (where `flock` is available). On macOS, the log fallback writes per-entry files to `$AUDIT_DIR/entries/` that only get merged via `report`/`show`. Fix: added `AUDIT_SYNC_WRITES=1` opt-in to `audit-trail.sh` that triggers `merge_pending_entries` after each log in the no-flock path. Test exports this env var. Production MUST NOT set it — it re-introduces the concurrent-write race the fallback is designed to prevent.

2. **`test_audit_trail.sh` wc -l whitespace.** BSD `wc -l` pads output with leading spaces; GNU `wc -l` does not. Fix: pipe through `tr -d '[:space:]'` before string comparison.

3. **`test_gate_cache_patterns.sh` awk markers drifted.** The test extracts `_gate_patterns` / `_files_changed_for_gate` via an awk window bounded by comment markers that no longer exist in `run-gates.sh`. Fix: anchor the window to function declarations (`^_gate_patterns\(\) \{` to `^_gate_cached\(\) \{`) which are stable.

## No parity maintenance

Do NOT re-port from upstream `arqu-co/claude-skills/plugins/rq` without a deliberate review. The rename mappings must be re-applied to any incoming changes, and upstream may have regressed the macOS test fixes we applied above. Treat upstream as inspiration, not authoritative source.

If you ever need to pull an upstream feature manually, the workflow is:

1. Diff upstream `plugins/rq/` against this `plugins/sdlc/` tree for the file(s) in question.
2. Apply the upstream changes, then re-run the Phase-2 rename regexes used during the original import to rename every `rq` reference to `sdlc` (see the rename mapping table above for the full substitution set).
3. Run the full test suite: `bin/validate && bin/lint && bin/test && pytest plugins/sdlc/scripts/`.
4. Manually verify any new env vars / config keys / skill cross-references were renamed.

## Source

Imported from `arqu-co/claude-skills` `plugins/rq` at v1.29.8 and end-to-end renamed to the `sdlc` brand. This marketplace-specific `CLAUDE.md` replaces upstream's `README.md` and `CHANGELOG.md`, which were intentionally excluded from the import (their prose referenced `rq` extensively and would have required their own rename pass).
