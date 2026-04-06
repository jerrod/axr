# AXR v2 Plan: Competitive Gap Closure

> Based on three-way analysis of axr, [kodustech/agent-readiness](https://github.com/kodustech/agent-readiness), and [Factory.ai Agent Readiness](https://factory.ai/news/agent-readiness).
>
> Rebased on main after Phase 4 (`/axr-diff`, `patch-dimension.sh`, incremental `/axr-check`) landed via PR #6.

## Guiding principle

No users yet means no trend data to protect. The rubric can be restructured freely now; it cannot later. Do everything that requires a `rubric_version` bump in Phase 2A before anyone depends on v1.

---

## Phase 2A: Rubric v2.0 — Style & Validation split + reweight

### Why now

Both Factory (Style & Validation pillar) and kodustech (Style & Linting pillar) treat code style as a first-class dimension. AXR currently folds type-checking and linting into Tooling & Reproducibility, which dilutes two distinct concerns:

- **Style & Validation** = "Does the agent get fast, clear signal when its code doesn't match conventions?" (feedback quality)
- **Tooling & Reproducibility** = "Can the agent set up and build reliably?" (environment correctness)

Splitting them sharpens both dimensions and aligns with the competitive landscape.

### New 9-dimension structure (rubric v2.0)

| # | Dimension | Weight | Change |
|---|-----------|--------|--------|
| 1 | Tests & CI Signal | 18 | -2 |
| 2 | Docs & Agent Context | 18 | -2 |
| 3 | Change Surface Clarity | 14 | -1 |
| 4 | Safety Rails | 14 | -1 |
| 5 | **Style & Validation** | **10** | **new** |
| 6 | Structure & Modularity | 8 | unchanged |
| 7 | Tooling & Reproducibility | 6 | -2 (lost 2 criteria) |
| 8 | Execution Visibility | 6 | -1 |
| 9 | Workflow Realism | 6 | -1 |
| | **Total** | **100** | |

Weight rationale: Style at 10 reflects that noisy lint/format failures waste agent tool-use budget and cause rework — it matters more than environment setup but less than tests or docs.

### Style & Validation criteria (5, all mechanical)

| ID | Name | From | checker_type |
|----|------|------|-------------|
| style_validation.1 | Type checker clean or baselined | was tooling.1 | mechanical |
| style_validation.2 | Linter and formatter in local + CI | was tooling.2 | mechanical |
| style_validation.3 | Formatting actively enforced | new | mechanical |
| style_validation.4 | Static analysis beyond linting | new | mechanical |
| style_validation.5 | Editor/IDE config shared | new | mechanical |

**style_validation.3 — Formatting actively enforced**
Not just "config exists" (that's .2) but "enforcement happens." Evidence: pre-commit hook runs formatter, CI step fails on format drift, or `format-check` script in package.json/Makefile. Score 0 if no enforcement, 2 if local only, 3 if local + CI.

**style_validation.4 — Static analysis beyond linting**
SAST tools (semgrep, CodeQL, sonar), complexity analysis, or language-specific deep checks (e.g., `cargo clippy` goes beyond `rustfmt`). Score 0 if absent, 2 if present locally, 3 if in CI pipeline.

**style_validation.5 — Editor/IDE config shared**
`.editorconfig`, `.vscode/settings.json`, or IDE-specific configs checked in. Agents and humans converge on the same formatting without manual setup. Score 0 if absent, 2 if basic `.editorconfig`, 3 if comprehensive with language-specific rules.

### Revised Tooling & Reproducibility criteria (5, all mechanical)

| ID | Name | From | checker_type |
|----|------|------|-------------|
| tooling.1 | Reproducible hermetic build | was tooling.3 | mechanical |
| tooling.2 | One-command bootstrap | was tooling.4 | mechanical |
| tooling.3 | Pinned dependencies with upgrade path | was tooling.5 | mechanical |
| tooling.4 | Dev container or codespace support | new | mechanical |
| tooling.5 | Build cache or incremental feedback | new | mechanical |

**tooling.4 — Dev container or codespace support**
`.devcontainer/devcontainer.json`, GitHub Codespace config, or Gitpod `.gitpod.yml`. Agents running in cloud environments need a reproducible container. Score 0 if absent, 2 if Dockerfile only, 3 if full devcontainer spec.

**tooling.5 — Build cache or incremental feedback**
Turbo, Nx, Gradle build cache, ccache, or equivalent. Agents iterate frequently — slow rebuilds burn tool-use budget. Score 0 if absent, 2 if partial (e.g., only tests cached), 3 if comprehensive with CI cache.

### File changes required

1. **`rubric/rubric.v2.json`** — new file, full 9-dimension rubric. Do NOT edit v1 in place.
2. **`scripts/check-style-validation.sh`** — new checker. Extract scoring logic for .1 and .2 from `check-tooling.sh`, add .3–.5.
3. **`scripts/check-tooling.sh`** — rewrite. Renumber criteria (old .3→.1, .4→.2, .5→.3), add new .4 and .5.
4. **`commands/axr.md`** — hardcodes `rubric/rubric.v1.json` (line 10) and "all 8 dimensions" (description + step 4). Update rubric path and dimension count references.
5. **`commands/axr-check.md`** — three hardcoded v1 references:
   - Line 10: dimension ID list is hardcoded to 8 values. Add `style_validation`.
   - Line 14: validates against `rubric/rubric.v1.json` path. Change to v2.
   - Line 29: says "all 8 checkers". Change to 9.
   - Line 42: hardcodes `Raw score: <sum>/20`. Make dynamic (criteria count × 4).
6. **`scripts/aggregate.sh`** — already dynamic (reads dimension IDs from rubric). Only needs rubric path updated if it's hardcoded, otherwise just point `$_AXR_RUBRIC_PATH` to v2.
7. **`scripts/patch-dimension.sh`** — already dynamic (reads weight/name from rubric). No code changes needed if `$_AXR_RUBRIC_PATH` points to v2.
8. **`scripts/diff-scores.sh`** — fully dynamic, no changes needed.
9. **`scripts/lib/common.sh`** — update `$_AXR_RUBRIC_PATH` default to `rubric.v2.json`.
10. **`docs/plugin-brief.md`** — update rubric section (dimensions, weights, criteria).
11. **`CLAUDE.md`** (plugin-level) — note rubric version bump.
12. **`bin/validate`** — update to validate rubric v2 schema.
13. **Score bands** — unchanged (they're percentile-based, still 0–100).

### What already works for 9 dimensions (verified post-rebase)

- `aggregate.sh` reads dimension IDs from rubric dynamically (`jq -r '.dimensions[].id'`)
- `patch-dimension.sh` reads weight/name from rubric per-dimension
- `diff-scores.sh` iterates over whatever dimensions exist in the scored JSONs
- The `for checker in scripts/check-*.sh` loop in `axr.md` auto-discovers new checker scripts

### Risk: tests_ci.5 overlap

`tests_ci.5` (fast-fail pre-commit/pre-push checks) overlaps with `style_validation.3` (formatting actively enforced). Resolution: tests_ci.5 covers the *existence* of pre-commit/pre-push hooks generally (lint + type + test). style_validation.3 specifically checks that *formatting* is enforced (formatter in hook or CI check), which is a stricter, narrower claim. A repo can have pre-commit hooks that only run tests (scores well on tests_ci.5, poorly on style_validation.3).

---

## Phase 2B: Ship judgment subagents

### Why this is the highest-leverage work

17 of 45 criteria (38% in v2; was 42% of 40 in v1) default to score 1 with `reviewer: "judgment"`. This means:
- The weighted scoring model (axr's key differentiator) is undermined
- Change Surface Clarity (14pts) has 3/5 criteria inert
- Structure & Modularity (8pts) has 3/5 criteria inert
- Axr is effectively a less-broad kodustech until subagents work

### What exists

5 agent prompt files under `plugins/axr/agents/`:
- `docs-reviewer.md` — docs_context.3, .5
- `architecture-reviewer.md` — change_surface.1, .2, .4; structure.1, .3, .4
- `safety-reviewer.md` — safety_rails.1, .2
- `observability-reviewer.md` — execution_visibility.1, .2, .4
- `workflow-reviewer.md` — tests_ci.2; workflow_realism.1, .2, .4

`SCHEMA.md` defines the output contract. `merge-agents.sh` handles overlay. The `/axr` orchestrator (`commands/axr.md`) already dispatches all 5 agents in parallel via Task tool (wired in Phase 3 / PR #5).

### Work required

1. **Finalize agent prompts.** Each agent needs:
   - Explicit tool-use instructions (Read, Grep, Glob, Bash)
   - Per-criterion scoring rubric with examples for each score level
   - Timebox (3 min per agent, 15 min total for all 5)
   - Output format per SCHEMA.md
2. **Update agent criteria for v2 rubric.** The split creates no new judgment criteria (all Style & Validation is mechanical), but the architecture-reviewer's structure criteria IDs are unchanged so no impact there.
3. **Calibrate on 2–3 reference repos.** Run full `/axr` end-to-end, compare agent scores to manual review, tune prompts.

### Acceptance

- All 17 judgment criteria produce scores with evidence (not defaulted 1s)
- Agent scores are within 1 point of manual review on calibration repos
- Full `/axr` run completes in < 20 min tool-use time

---

## Phase 3: Auto-remediation (`/axr-fix`)

### Why this matters

Factory's killer feature. Neither kodustech nor axr can fix what they find. Axr has a unique advantage: it runs *inside a Claude Code session* — the agent that scored the repo can immediately fix it.

### Design

New command: `/axr-fix [criterion-id | dimension-id | "blockers"]`

Modes:
- `/axr-fix blockers` — fix top 3 blockers from `.axr/latest.json`
- `/axr-fix docs_context.1` — fix a specific criterion
- `/axr-fix safety_rails` — fix all low-scoring criteria in a dimension

For each target criterion:
1. Read `.axr/latest.json` to get current score, evidence, and notes
2. Apply a criterion-specific remediation strategy (see below)
3. Re-run the relevant `check-*.sh` to verify improvement
4. Report delta

### Remediation strategies (starter set, expand over time)

| Criterion | Remediation |
|-----------|-------------|
| docs_context.1 | Generate CLAUDE.md from repo analysis (architecture, conventions, sharp edges) |
| docs_context.2 | Add quickstart section to README with detected setup/test/run commands |
| docs_context.4 | Scaffold `docs/adr/` with template and first ADR |
| safety_rails.3 | Add missing `.gitignore` entries for `.env`, credentials patterns |
| safety_rails.5 | Add agent permissions section to CLAUDE.md |
| style_validation.5 | Generate `.editorconfig` from detected project conventions |
| tooling.2 | One-command bootstrap script from detected setup steps |
| tooling.4 | Generate `.devcontainer/devcontainer.json` from detected stack |

### File changes

1. **`commands/axr-fix.md`** — new command prompt with remediation dispatch logic
2. **`scripts/remediate-*.sh`** — per-criterion remediation scripts (optional, some may be pure agent work)
3. **`docs/plugin-brief.md`** — document `/axr-fix` command

---

## Phase 4: Monorepo awareness + CI fast-path

### Monorepo awareness

Both Factory and kodustech handle monorepos. AXR treats every repo as a single unit, which means:
- Tests in `packages/foo/` aren't found when looking at repo root
- Per-package linter configs are missed
- Docs per-package are invisible to dimension 2

**Approach:**
1. Detect monorepo markers: `lerna.json`, `nx.json`, `turbo.json`, `pnpm-workspace.yaml`, Gradle multi-project (`settings.gradle.kts` with `include`), Cargo workspace (`Cargo.toml` with `[workspace]`)
2. When detected, run mechanical checkers per-package and aggregate:
   - Per-package scores for Tests, Style, Tooling, Docs
   - Repo-level scores for Safety, Structure, Visibility, Workflow, Change Surface
3. Report shows both per-package breakdown and aggregate

**File changes:**
- `scripts/lib/common.sh` — add `axr_detect_monorepo()`, `axr_list_packages()`
- Each `check-*.sh` — add monorepo loop for package-scoped criteria
- `aggregate.sh` — support per-package dimension JSONs
- `templates/report.md.template` — monorepo section

### CI fast-path

A headless mode for CI gates that runs mechanical checks only (no subagents).

**Approach:**
- New script: `scripts/axr-ci.sh` — runs all 9 mechanical checkers, aggregates, outputs JSON, exits with code based on band threshold
- Configuration via `.axr/config.json`: `{ "ci_minimum_band": "Agent-Assisted", "ci_fail_on_blockers": true }`
- Target runtime: < 2 min (no LLM calls, no network calls except `gh api`)

**File changes:**
- `scripts/axr-ci.sh` — new orchestrator for CI mode
- Document in README and plugin-brief

---

## Phase 5: Language coverage expansion

### Current coverage

node, python, kotlin, ruby, rust, go, markdown (7 stacks via `axr_detect_stack`)

### Gaps vs. competitors

| Language | kodustech | Factory | AXR |
|----------|-----------|---------|-----|
| Java | yes | yes | **no** |
| C# / .NET | yes | implied | **no** |
| PHP | yes | implied | **no** |
| Swift | yes | implied | **no** |

### Priority order

1. **Java** — largest enterprise surface, similar to Kotlin (Gradle/Maven), moderate effort
2. **C# / .NET** — growing AI-agent adoption, unique toolchain (dotnet, NuGet, .csproj)
3. **PHP** — large legacy surface, Composer-based, straightforward
4. **Swift** — smallest surface for agent use, lowest priority

### Per-language work

For each new language:
1. Add detection markers to `axr_detect_stack()` in `lib/common.sh`
2. Add language-specific evidence paths to each `check-*.sh` (type checker config, linter config, test runner, lockfiles, etc.)
3. Add to `lib/tooling-helpers.sh` (linter/formatter/type checker detection)
4. Test against a representative open-source repo in that language

---

## Sequencing summary

```
DONE      Phase 1–4 (skeleton, mechanical checkers, judgment scaffolding, /axr-diff + patch-dimension)
─────────────────────────────────────────────────────────────────────────
Phase 2A  Rubric v2.0 (Style split, reweight, new criteria)     ← do first, free restructure window
Phase 2B  Judgment subagents (finalize prompts, calibrate)       ← unlocks core differentiator
Phase 3   /axr-fix (auto-remediation)                            ← unique advantage as Claude Code plugin
Phase 4   Monorepo awareness + CI fast-path                      ← broadens adoption surface
Phase 5   Java, C#, PHP, Swift support                           ← incremental language reach
```

Each phase is independently shippable. Phase 2A must precede 2B (subagents need stable criterion IDs). Phases 3–5 are independent of each other and can be reordered based on user demand.

## Post-rebase notes (PR #6 merged)

Phase 4 of the original plugin-brief (`/axr-diff`, `patch-dimension.sh`, incremental `/axr-check`) shipped in PR #6. Key findings from reviewing the new code:

- **`diff-scores.sh`** and **`aggregate.sh`** are rubric-dynamic — they read dimension IDs and weights from the rubric JSON at runtime. No code changes needed for 9 dimensions.
- **`patch-dimension.sh`** is also dynamic — reads weight/name per-dimension from the rubric.
- **`commands/axr-check.md`** has 4 hardcoded v1 references (dimension list, rubric path, "8 checkers", hardcoded `/20` max) that must be updated in Phase 2A.
- **`commands/axr.md`** has hardcoded `rubric.v1.json` path and "8 dimensions" in its description.
- **`scripts/lib/common.sh`** sets `$_AXR_RUBRIC_PATH` — updating this one location propagates to all dynamic scripts.
