# OpenAI Codex Compatibility for agent-plugins Marketplace

**Date:** 2026-04-10
**Status:** Proposed
**Author:** Boardroom (Product + Engineering + Design)

## Problem

The agent-plugins marketplace hosts 4 Claude Code plugins (axr, revue, therapist, sdlc). These plugins are locked to Claude Code — they cannot be installed or used in OpenAI Codex CLI. Users who work across both platforms must choose one ecosystem or maintain separate tooling.

## Goal

Make all 4 plugins installable and functional in OpenAI Codex CLI while making **zero changes that break Claude Code compatibility**.

## Constraints

- No modifications to existing Claude-facing files (skills, commands, agents, hooks)
- Claude Code remains the source of truth for all plugin definitions
- Codex support is additive — layered alongside, never instead
- No new runtime dependencies

## Research Findings

Claude Code and Codex share remarkably similar primitives:

| Primitive | Claude Code | Codex | Compatibility |
|-----------|------------|-------|---------------|
| Skills (`SKILL.md`) | YAML frontmatter | YAML frontmatter | Near-identical |
| Hooks (`hooks.json`) | SessionStart, PreToolUse, PostToolUse | SessionStart, PreToolUse, PostToolUse, UserPromptSubmit, Stop | Compatible (Codex has more events) |
| Hook scope | Any tool matcher | Bash only for Pre/PostToolUse | Partial — Write/Edit hooks need remapping |
| Agents | `.md` with YAML frontmatter | `.toml` with structured fields | Different format, same semantics |
| Commands | `commands/*.md` via `/slash` invocation | No equivalent | Commands must become skills |
| Subagent dispatch | `Agent(subagent_type=...)` parallel | No plugin-namespaced dispatch | Parallel workflows degrade to sequential |
| Custom instructions | `CLAUDE.md` | `AGENTS.md` | Different filenames |
| Config format | JSON (`settings.json`) | TOML (`config.toml`) | Different formats |
| MCP support | First-class | First-class | Compatible |
| Plugin path variable | `${CLAUDE_PLUGIN_ROOT}` | TBD | Needs verification |

## Architecture: Generate, Don't Shim

Each plugin remains Claude-native as the source of truth. A marketplace-level build script (`bin/build-codex`) generates Codex-compatible artifacts into `dist/codex/` within each plugin.

```
plugins/<name>/                    <- source of truth (Claude format, unchanged)
  .claude-plugin/plugin.json       <- add `platforms` field
  commands/*.md                    <- Claude only
  skills/*/SKILL.md                <- shared (copied to dist as-is)
  agents/*.md                      <- Claude only
  hooks/hooks.json                 <- Claude only
  scripts/                         <- shared (copied to dist)
  CLAUDE.md                        <- Claude only
  AGENTS.md                        <- Codex only (new, additive)
  dist/
    codex/
      skills/*/SKILL.md            <- copied from source
      agents/*.toml                <- generated from agents/*.md
      hooks/hooks.json             <- event-remapped from source
      scripts/                     <- copied from source
```

### Build Script: `bin/build-codex`

A generic, plugin-agnostic script that performs 5 transforms:

1. **Skills** — copy all `SKILL.md` files as-is (format is already compatible)
2. **Agents** — parse YAML frontmatter from `.md`, emit `.toml`:
   - `name`, `description` to TOML fields
   - Body content to `developer_instructions`
   - Apply tool name mapping from `tool-mapping.json`
   - Remap `tools` array names
3. **Hooks** — generate Codex-specific `hooks.json`:
   - Response schema: `decision/reason` to `continue/stopReason`
   - Remap Write|Edit matchers per event type (see Hook Remapping below)
   - Drop unsupported matchers
4. **Commands to Skills** — wrap command `.md` body as `SKILL.md` with frontmatter
5. **Scripts** — copy as-is, replace `${CLAUDE_PLUGIN_ROOT}` with Codex equivalent

The build script is generic for the common transforms (skills, agents, scripts, commands). Hooks require a per-plugin override mechanism for two cases:

1. **Prompt-type hooks** — sdlc uses `"type": "prompt"` hooks (inline model prompts) for mock-detection. Codex hook support for `"type": "prompt"` is unverified. If unsupported, the build script converts the prompt hook to a `"type": "command"` equivalent that runs a script performing the same check. Each plugin may include a `codex-hook-overrides.json` file that the build script merges into the generated `hooks.json`.

2. **Semantic retiming** — sdlc's mock-detection retimes from `Write|Edit` to `Bash(git commit*)` rather than the generic `UserPromptSubmit` mapping because commit-time is the correct enforcement boundary for that check. The override file handles this.

### Tool Name Mapping

A shared lookup table (`tool-mapping.json`) applied to all agent body text during generation. Initial mapping (needs verification against live Codex):

| Claude Code | Codex | Notes |
|------------|-------|-------|
| `Bash` | `Bash` | Identical |
| `Read` | `Read` | Likely identical |
| `Write` | `Write` | Likely identical |
| `Edit` | `Edit` | Likely identical |
| `Glob` | `Glob` | Needs verification |
| `Grep` | `Grep` | Needs verification |
| `Agent` | Sequential dispatch | Rewritten in generated instructions |
| `WebFetch` | `WebFetch` | Needs verification |
| `WebSearch` | `WebSearch` | Codex has web search support |

### Hook Remapping Rules

Generic default rules (plugins may override via `codex-hook-overrides.json`):

| Claude hook matcher | Claude event | Codex remapping |
|---|---|---|
| `Bash(*)` | PreToolUse | Keep as-is |
| `Bash(*)` | PostToolUse | Keep as-is |
| `Write\|Edit` | PreToolUse | UserPromptSubmit |
| `Write\|Edit` | PostToolUse | Stop |
| `SessionStart` | SessionStart | Keep as-is |

**Rationale for Write|Edit remapping:**
- `PreToolUse(Write|Edit)` to `UserPromptSubmit`: The check fires at the start of the next turn instead of before each write. Reviews previous turn's output before new work begins. Still preventive — catches issues before they compound.
- `PostToolUse(Write|Edit)` to `Stop`: Fires at turn-end instead of per-write. Provides holistic review of everything the agent did — arguably richer context than per-file checks.

**Per-plugin hook mapping results:**

| Plugin | Hook | Claude Event | Codex Event | Character |
|--------|------|-------------|-------------|-----------|
| therapist | `affirmation.sh` | SessionStart | SessionStart | Identical |
| therapist | `rubber-band.sh` | PreToolUse(Write\|Edit) | UserPromptSubmit | Catches distortions at turn boundary |
| therapist | `pause.sh` | PreToolUse(Bash(git commit*)\|Bash(git push*)) | PreToolUse(Bash(git commit*)\|Bash(git push*)) | Identical (compound matcher) |
| therapist | `mirror.sh` | PostToolUse(Bash) | PostToolUse(Bash) | Identical |
| therapist | `reframe.sh` | PostToolUse(Bash) async | PostToolUse(Bash) | Identical |
| therapist | `activate.sh` | PostToolUse(Bash) async | PostToolUse(Bash) | Identical |
| therapist | `socratic.sh` | PostToolUse(Write\|Edit) | Stop | Reflects on full turn |
| sdlc | `session-start` | SessionStart | SessionStart | Identical |
| sdlc | `require-critic-approval` | PreToolUse(Bash(git commit*)) | PreToolUse(Bash(git commit*)) | Identical |
| sdlc | `run-gates.sh` | PreToolUse(Bash(git push*)) | PreToolUse(Bash(git push*)) | Identical |
| sdlc | `enforce-review-before-pr` | PreToolUse(Bash(gh pr*)) | PreToolUse(Bash(gh pr*)) | Identical |
| sdlc | `block-merge-without-ci` | PreToolUse(Bash(gh pr merge*)) | PreToolUse(Bash(gh pr merge*)) | Identical |
| sdlc | mock-detection prompt | PreToolUse(Write\|Edit) | PreToolUse(Bash(git commit*)) | Retimed to commit-time |
| sdlc | `enforce-fixes` | PostToolUse(Bash) | PostToolUse(Bash) | Identical |

## Compatibility Tier System

Each plugin's `.claude-plugin/plugin.json` gets a `platforms` field:

```json
{
  "platforms": {
    "claude": { "status": "supported" },
    "codex": { "status": "skill-compatible" }
  }
}
```

### Tier Definitions

| Tier | Meaning | Validator Rule | Plugins |
|------|---------|----------------|---------|
| `skill-compatible` | Skills + agents work, no hooks required | Passes if no hooks or all hooks are Bash-scoped | revue, axr |
| `hook-dependent` | Full functionality with remapped hooks; differences documented | Passes, requires "Codex limitations" section in README | therapist, sdlc |
| `unsupported` | Explicit opt-out | No checks | Any future plugin |

### Validator Enforcement

`bin/validate` enforces tier rules mechanically:
- Checks `platforms.codex.status` field exists and is a valid tier
- For `hook-dependent`: requires "Codex limitations" or "Codex differences" section in README
- Confirms `dist/codex/` exists and is not stale. Staleness is determined by comparing mtimes of source files against `dist/codex/.build-stamp` (a timestamp file written by `bin/build-codex` on each run). Watched source files: `agents/*.md`, `skills/*/SKILL.md`, `commands/*.md`, `hooks/hooks.json`, `scripts/**/*.sh`, `.claude-plugin/plugin.json`, `codex-hook-overrides.json` (if present), `AGENTS.md`
- Validates generated TOML parses, generated hooks.json is valid JSON, generated skills have required frontmatter

## Per-Plugin Adaptations

### revue (MVP — ship first)

- **Tier:** `skill-compatible`
- Copy 2 skills (`review-pr`, `respond`) as-is
- Generate 4 agent TOMLs (architect, security, correctness, style)
- Codex version of `review-pr` skill dispatches reviewers sequentially instead of parallel
- Preserve security isolation: Claude's `review-pr` skill excludes `Bash` and `Agent` from `allowed-tools` as anti-injection defense. Codex equivalent must maintain the same tool restrictions on reviewer agents to prevent untrusted diff content from triggering shell execution
- Add `AGENTS.md` with Codex-specific install/invoke instructions (`$review-pr`)
- No hooks, no scripts, no commands

### axr

- **Tier:** `skill-compatible`
- Generate 5 wrapper skills from 5 commands (`axr`, `axr-check`, `axr-diff`, `axr-fix`, `axr-badge`). Command-to-skill conversion: copy the command body verbatim as the skill body; map `description` to skill frontmatter `description`; map `argument-hint` to skill frontmatter `argument-hint`; replace `/command` invocation references in the body with `$skill-name` invocation syntax
- Generate 8 agent TOMLs (dimension reviewers)
- Copy all `scripts/check-*.sh` and library scripts
- Codex scoring orchestration runs reviewers sequentially
- Add `AGENTS.md`

### therapist

- **Tier:** `hook-dependent`
- Copy 1 skill (`therapist`) as-is
- Generate Codex `hooks.json` with remapped events (rubber-band to UserPromptSubmit, socratic to Stop, all Bash hooks identical)
- Copy all scripts
- Add `AGENTS.md`
- Document in README: "On Codex, rubber-band fires at turn boundary (UserPromptSubmit) and socratic fires at turn-end (Stop) instead of per-file-write"

### sdlc

- **Tier:** `hook-dependent`
- Copy all 24 skills as-is
- Generate 23 agent TOMLs
- Generate Codex `hooks.json` (mock-detection retimed to Bash(git commit*), all other Bash hooks identical)
- Copy all scripts
- Codex versions of pair-build/tech-lead/subagent-build skills dispatch agents sequentially
- Add `AGENTS.md`
- Document in README: "On Codex, mock-detection check runs at commit-time instead of write-time. Multi-agent workflows run sequentially."

## Ship Order

1. **revue** — cleanest port (no hooks, no scripts, no commands), proves the pattern
2. **axr** — adds command-to-skill conversion, script copying
3. **therapist** — adds hook remapping
4. **sdlc** — largest surface area, most agent conversions, most skill rewrites

## File Changes Summary

### New files (additive only)

| File | Purpose |
|------|---------|
| `bin/build-codex` | Marketplace-level generator script |
| `tool-mapping.json` | Shared Claude-to-Codex tool name lookup table |
| `plugins/*/AGENTS.md` | Codex-specific instructions (one per plugin) |
| `plugins/*/dist/codex/` | Generated output directories |
| `plugins/*/codex-hook-overrides.json` | Per-plugin hook remapping overrides (only for plugins that need non-default remapping) |

### Modified files (minimal)

| File | Change |
|------|--------|
| `plugins/*/.claude-plugin/plugin.json` | Add `platforms` field |
| `bin/validate` | Add `--codex` flag for dist freshness/validity checks |
| `bin/test` | Add Codex structural validation |

### Unchanged

- All existing skills, commands, agents, hooks
- `.claude-plugin/marketplace.json` structure
- How Claude Code discovers or loads plugins

## dist/ — Committed, Not Gitignored

Generated `dist/codex/` directories are committed to the repo. Codex users can install directly from the repo without a build step. `bin/validate --codex` fails if dist files are stale (source newer than dist), preventing drift. Same pattern as lockfiles.

## Testing Strategy

- `bin/test` gains Codex validation: confirms generated TOML parses, generated hooks.json is valid JSON, generated skills have required frontmatter
- Structural tests only — no end-to-end Codex testing without a Codex install
- Manual smoke test on a real Codex install before first release
- Tool name mapping verified against live Codex before first ship

## AGENTS.md Specification

Each plugin gets an `AGENTS.md` file (Codex's equivalent of `CLAUDE.md`). Required sections:

1. **Plugin name and description** — what this plugin does
2. **Installation** — how to install in Codex (platform-specific path, not Claude's `/plugin` TUI)
3. **Available skills** — list of `$skill-name` invocations with one-line descriptions
4. **Platform differences** — what works differently on Codex vs Claude Code (sequential agents, retimed hooks, etc.)
5. **Codex limitations** (hook-dependent tier only) — explicit list of hooks that behave differently

The `AGENTS.md` must NOT reference: `CLAUDE.md`, Claude-specific env vars (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`), `/slash` command syntax, or Claude Code TUI navigation.

## Prerequisites (must resolve before implementation)

1. **Codex plugin installation path** — how does a Codex user actually install from this repo? The plugin directory GUI browser may require a specific packaging format. This determines whether `dist/codex/` layout is correct. **Blocker for implementation.**
2. **Exact Codex tool names** — Glob, Grep, WebFetch, WebSearch need verification against a live install. The `tool-mapping.json` table is updatable without code changes. **Blocker for agent generation (revue, axr).**

## Open Questions

1. **`${CLAUDE_PLUGIN_ROOT}` Codex equivalent** — does Codex provide a plugin root path variable? If not, the build script needs to generate a wrapper that sets it.
2. **Codex `"type": "prompt"` hook support** — does Codex support inline model prompt hooks? If not, sdlc's mock-detection hook must be converted to a script-based equivalent.
3. **SessionStart matcher string compatibility** — Claude's therapist hooks use matcher `"startup|resume|clear|compact"`. Codex SessionStart supports `source: "startup"` or `source: "resume"`. Verify matcher format compatibility or generate Codex-specific matcher strings.
4. **Codex concurrent hook ordering** — multiple hooks on the same event run concurrently in Codex (no ordering guarantees). For therapist's three `PostToolUse(Bash)` hooks (mirror, reframe, activate), confirm that concurrent execution is acceptable (all three are independent, so this should be fine).
5. **Subagent dispatch evolution** — if Codex adds `Agent(subagent_type=...)` support, the sequential fallback skills should be updated to use parallel dispatch. Track Codex changelog for this.

## Non-Goals

- No runtime transpilation or install-time conversion
- No unified manifest format that both runtimes parse
- No Codex-specific features that don't exist in Claude Code
- No breaking changes to existing plugin structure
