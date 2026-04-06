# AXR Plugin: Implementation Brief

> This is the authoritative specification for the `axr` plugin. The plan in `.quality/plans/` references this document for rubric content and scoring anchors.

## Context

Building `axr`, a Claude Code plugin that scores a repository's **Agent eXecution Readiness (AXR)** against a defined rubric. v1 of a larger initiative — a GitHub App will follow later, so scoring logic should be extractable.

The plugin must work today for a single repo, run from inside a Claude Code session, and produce both a human-readable report and a machine-readable JSON artifact. Do not build the GitHub App, a shared `axr-core` library, or a dashboard in this phase. Inline the logic; premature abstraction is the enemy.

## The Rubric (v1.0, finalized)

100 points across 8 dimensions. Each criterion scored 0–4. Dimension score = `(sum of criteria / max possible) × weight`.

### Scoring scale (applies universally)

- **0 — Absent:** Nothing in place. Agents operate blind.
- **1 — Ad hoc:** Exists but inconsistent, stale, or unreliable.
- **2 — Functional:** Works, but agents need human scaffolding.
- **3 — Strong:** Agents can use it autonomously in most cases.
- **4 — Exemplary:** Intentionally designed for agentic consumption.

### Dimensions

#### 1. Tests & CI Signal — 20 pts

1. Test suite runs deterministically in under 10 min (local + CI)
2. Coverage meaningful at module boundaries, not vanity %
3. Flaky tests tracked and quarantined
4. CI failures map to precise, actionable messages
5. Fast-fail pre-commit/pre-push checks (lint, format, type)

#### 2. Docs & Agent Context — 20 pts

1. Root CLAUDE.md / AGENTS.md with architecture, conventions, sharp edges
2. README covers setup/run/test/deploy in ≤5 commands
3. Non-obvious subsystems have local READMEs
4. ADRs or decision log for important tradeoffs
5. Domain glossary for business language

#### 3. Change Surface Clarity — 15 pts

1. Business logic locatable by responsibility
2. Module boundaries and public interfaces explicit
3. Integration points, schemas, contracts documented
4. Examples/fixtures/reference implementations for key workflows
5. Context packing: repo supports bounded context maps (repo tree, module summaries, repomix/llm-tree output) that fit agent windows

#### 4. Safety Rails — 15 pts

1. HITL checkpoints on destructive ops (migrations, prod writes, external APIs)
2. Reversible-by-default: migrations, deploys, data changes
3. Secrets never in repo; scoped via env/vault
4. Branch protection + required review on main
5. Agent permissions/boundaries documented

#### 5. Structure & Modularity — 8 pts

1. Clear module boundaries, sane dependency direction
2. Circular dependencies prevented
3. Files/functions scoped for local reasoning
4. Consistent, searchable naming conventions
5. Dead code removed

#### 6. Tooling & Reproducibility — 8 pts

1. Type checker clean or baselined
2. Linter/formatter in local + CI
3. Reproducible, hermetic build
4. One-command bootstrap (`make dev`, `bin/setup`)
5. Dependencies pinned; upgrade path documented

#### 7. Execution Visibility — 7 pts

1. Structured logging with consistent fields
2. Agent-touchable paths expose logs/traces/metrics
3. Errors route to single searchable place
4. Local dev preserves diagnostic output
5. Test failures preserve logs, stack traces, artifacts

#### 8. Workflow Realism — 7 pts

1. Representative fixtures/sample data for core workflows
2. Sandbox flows mirror production behavior
3. External integrations stubable/simulatable
4. Golden-path scenarios for critical flows
5. Regression artifacts / before-after comparisons

### Score bands

- **85–100:** Agent-Native
- **70–84:** Agent-Ready
- **50–69:** Agent-Assisted
- **30–49:** Agent-Hazardous
- **0–29:** Agent-Hostile

## Command surface

- `/axr` — Run full assessment on current repo. Default command.
- `/axr-check <dimension>` — Run only one dimension. Used for iteration and debugging.
- `/axr-diff` — Compare current score to `.axr/latest.json` and surface what changed.

## Output artifacts

Every run writes two files to `.axr/` at repo root.

### `.axr/latest.json` — structured, diffable

```json
{
  "rubric_version": "1.0",
  "scored_at": "2026-04-05T14:30:00Z",
  "repo": "example-org/example-repo",
  "total_score": 73,
  "band": "Agent-Ready",
  "dimensions": {
    "tests_ci": {
      "weight": 20,
      "raw_score": 14,
      "max_raw": 20,
      "weighted_score": 14.0,
      "criteria": [
        {
          "id": "tests_ci.1",
          "name": "Test suite runs deterministically under 10min",
          "score": 3,
          "evidence": [
            "CI run: .github/workflows/test.yml (avg 6m42s last 10 runs)",
            "pytest config: pyproject.toml line 42"
          ],
          "notes": "Flaky tests in tests/integration/test_sync.py occasionally add 2–3min",
          "reviewer": "script"
        }
      ]
    }
  },
  "blockers": [
    "No CLAUDE.md at root (docs_context.1)",
    "No branch protection on main (safety_rails.4)"
  ],
  "trend": {
    "previous_score": 68,
    "delta": 5,
    "previous_date": "2026-01-05T10:15:00Z"
  }
}
```

### `.axr/latest.md` — human-readable

Score, band, per-dimension breakdown, top blockers, recommended next 3 improvements.

### `.axr/history/<timestamp>.json` — trend tracking

Archive of prior runs, preserved on each new run.

## Scoring engine — three passes

### Pass 1 — Mechanical checks

For every criterion resolvable from the filesystem, use tools (Read, Bash with `gh`, `grep`, `fd`) to collect evidence and assign a score. Examples:

- **docs_context.1:** Does `CLAUDE.md` or `AGENTS.md` exist at repo root? If yes, is it >500 chars and does it contain sections for "architecture", "conventions", "gotchas/sharp edges"? Score 0 (absent), 2 (exists, thin), or 3 (present with required sections). 4 requires human confirmation.
- **tooling.4:** Does `bin/setup`, `Makefile` with `dev` target, `scripts/bootstrap`, or equivalent exist? Does running it succeed in a clean environment? Score based on presence and documented runtime.
- **safety_rails.4:** Use `gh api "repos/$REPO_SLUG/branches/main/protection"` to check branch protection. Score 0–4 based on required reviews, required status checks, admin enforcement.

  **Security requirement:** derive `REPO_SLUG` via `gh repo view --json nameWithOwner -q .nameWithOwner` (gh-native — no manual URL parsing) and validate it matches `^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$` before interpolating into any `gh api` call. Never interpolate raw `git remote get-url` output into shell commands.
- **tests_ci.1:** Parse `.github/workflows/*.yml` for test jobs. Use `gh run list --workflow=<test> --limit 10 --json conclusion,createdAt,updatedAt` for avg duration and flake rate.
- **structure.2:** Run static analysis for the stack (`madge` for JS/TS, `pydeps` for Python, Gradle reports for Kotlin) to detect circular imports.

### Pass 2 — Judgment checks (Phase 3)

5 specialized subagents under `plugins/axr/agents/` score the 17 judgment criteria:

| Agent | Criteria |
|---|---|
| `docs-reviewer` | docs_context.3, .5 |
| `architecture-reviewer` | change_surface.1, .2, .4; structure.1, .3, .4 |
| `safety-reviewer` | safety_rails.1, .2 |
| `observability-reviewer` | execution_visibility.1, .2, .4 |
| `workflow-reviewer` | tests_ci.2; workflow_realism.1, .2, .4 |

Agents score 0-3 autonomously. Score 4 requires human confirmation. Every agent-emitted criterion carries `reviewer: "agent-draft"` so downstream consumers know to confirm before treating as final.

### Pass 2.5 — Agent merge

`aggregate.sh --merge-agents <agent-dir>` overlays agent-draft scores onto the per-dimension JSONs into a temp merged directory (never mutating the original mechanical outputs). Each agent criterion is matched by `id`, validated (score 0-3, known id), and overlaid. Criteria not covered by any agent remain at their defaulted score of 1 with `reviewer: "judgment"`.

### Pass 3 — Aggregation

Compute weighted scores, determine band, identify top 3 blockers (criteria scoring 0-1 in high-weight dimensions), compute delta vs. previous run if `.axr/latest.json` exists, write both output files.

### `reviewer` field values

| Value | Meaning |
|---|---|
| `"script"` | Scored by a mechanical check script (deterministic). |
| `"agent-draft"` | Scored by a judgment subagent (needs human confirmation). |
| `"judgment"` | Deferred to judgment but no agent scored it yet (defaulted to 1). |
| `"human-confirmed"` | Agent-draft score confirmed by a human reviewer. |

## Orchestrator performance requirements

The 20-minute tool-use budget is not achievable with serial dispatch of 8 check scripts + up to 18 judgment subagent calls. The orchestrator (`commands/axr.md` in Phase 2) MUST:

1. **Run mechanical check scripts concurrently.** All 8 `scripts/check-*.sh` scripts are read-only, independent, and safe to fan out in parallel. Target: all 8 scripts run simultaneously, elapsed time = slowest script, not sum.
2. **Batch judgment subagents per dimension.** Dispatch ONE judgment subagent per dimension that has ≥1 deferred criterion, passing all of that dimension's deferred criteria in a single call. Never dispatch one subagent per criterion.
3. **Expose a mechanical-only fast path.** Support a mode that skips judgment entirely and returns in under 2 minutes against any repo. Useful for CI gates and for quick feedback during iteration.
4. **Honor the timebox as a hard stop.** If 20 minutes elapse before all dimensions complete, emit `.axr/latest.json` with the partial results and flag incomplete dimensions explicitly.

## Handling unknown/unresolvable criteria

If evidence cannot be found, score defaults to **1**, not higher. This is the "unknown ≠ strong" rule. The criterion is flagged `evidence: []` and `notes: "No evidence found — defaulted to 1"` so reviewers can investigate rather than inflate.

## Stack detection

Before running, detect the repo's stack to pick the right tools:

- **Python:** `pyproject.toml`, `requirements.txt`, `setup.py`
- **Node:** `package.json`
- **Kotlin/JVM:** `build.gradle.kts`, `build.gradle`, `pom.xml`
- **Ruby:** `Gemfile`
- **Multi-language:** detect all, run appropriate checkers per subtree

Fall back to language-agnostic checks on unsupported stacks and note the limitation in the report.

## Operational rules (enforced by command prompts)

1. **Evidence required for scores ≥ 2.** Every criterion scoring 2+ must have at least one concrete evidence entry.
2. **Unknown defaults to 1**, never higher. Criterion scores 1 with a note.
3. **Anchors used literally.** Score 4 requires intentional agent-oriented design, not "pretty good."
4. **Timebox awareness.** Target 20 minutes of tool-use time per run. If exceeded, complete current dimension and note incomplete dimensions.
5. **Carryover supported.** If `.axr/latest.json` exists with same `rubric_version`, offer to reuse evidence for criteria where underlying files haven't changed (check via `git log --since=<last_run>` on evidence paths).

## NOT in this phase

- No GitHub App
- No shared `axr-core` library (inline everything)
- No dashboard or cross-repo aggregation
- No CI integration
- No automated remediation
- No policy enforcement

## Build phases

### Phase 1 — Skeleton

1. Create plugin directory structure
2. Write `plugin.json` manifest
3. Write `rubric/rubric.v1.json` — the full rubric (source of truth)
4. Write `commands/axr.md` with a minimal command that reads the rubric and prints it

### Phase 2 — Mechanical checkers

1. Stack detection prompt
2. Implement mechanical checks for highest-value criteria:
   - All of Docs & Agent Context (filesystem)
   - All of Safety Rails (mostly `gh api` + filesystem)
   - `tests_ci.1`, `tests_ci.4` (CI introspection via `gh`)
   - `tooling.4`, `tooling.5` (bootstrap script, pinned deps)
   - `change_surface.5` (context packing)
3. For each check, define: what evidence to collect, how to score 0–4, what counts as each level.
4. Run against one target repo, inspect output, tune.

**Stop at end of Phase 2 for human review.**

### Phases 3–6 (deferred)

- Phase 3: Judgment checkers
- Phase 4: Output generation (templates, history archival, `/axr-diff`)
- Phase 5: Calibration pilot on two reference repos
- Phase 6: Distribution via the jerrod/axr marketplace

## Success criteria for v1

1. `/axr` produces a complete report on a representative repo in <20 min of tool-use time.
2. Scores for calibration pilot repos are within one band of independent human reviewer.
3. `/axr-diff` correctly surfaces changes between runs.
4. JSON output format is stable enough for a future GitHub App to consume unchanged.
5. A cold-start engineer can read `.axr/latest.md` and understand what to fix first.
