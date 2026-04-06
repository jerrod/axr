# Rubric v4 Design: Legibility, Patterns, Supply Chain

**Date:** 2026-04-06
**Status:** Approved
**Branch:** feat/rubric-v4-research-gaps (to be recreated from main)

## Summary

Add 3 new dimensions to the AXR rubric based on research into agent failure modes (Columbia DAPLab, GitClear, Addy Osmani, competitive analysis of Factory.ai/Microsoft AgentRC/kodustech). Reweight to 100 points across 12 dimensions, 60 criteria. Also add a Comprehension Debt Index (cross-dimensional composite metric) and Agent ROI Predictor (cost mapping in summary output).

## Research Basis

- **Columbia DAPLab:** 9 failure patterns of coding agents. #1 is error suppression. Agents misimplement business rules silently. Context window overflow causes degraded output.
- **GitClear 2025:** 8x increase in duplicated code from AI agents. "Copy/paste" exceeds "moved" code for first time.
- **Addy Osmani:** "Comprehension Debt" — the invisible gap between how much code exists and how much anyone understands. Teams hit a wall at ~week 7.
- **Competitive gaps:** Factory.ai has Issue Management + Analytics pillars. Microsoft AgentRC checks instruction consistency. kodustech checks dependency freshness. None have judgment subagents or weighted scoring.

## Rubric v4 Structure

### Dimensions and Weights

| # | Dimension | ID | Weight | Status |
|---|-----------|-----|--------|--------|
| 1 | Tests & CI Signal | tests | 14 | existing (-4) |
| 2 | Docs & Agent Context | docs | 14 | existing (-4) |
| 3 | Change Surface Clarity | change | 10 | existing (-4) |
| 4 | Safety Rails | safety | 10 | existing (-4) |
| 5 | Legibility | legibility | 8 | **NEW** |
| 6 | Patterns | patterns | 8 | **NEW** |
| 7 | Style & Validation | style | 8 | existing (-2) |
| 8 | Structure & Modularity | structure | 6 | existing (-2) |
| 9 | Tooling & Reproducibility | tooling | 6 | existing (=) |
| 10 | Supply Chain | supply-chain | 6 | **NEW** |
| 11 | Execution Visibility | visibility | 5 | existing (-1) |
| 12 | Workflow Realism | workflow | 5 | existing (-1) |
| | **Total** | | **100** | |

Weight rationale: Tests/docs still #1/#2 (28 combined = 28% of total). New dimensions total 22 points — meaningful but not dominant. Legibility and patterns at 8 each reflect research finding that comprehension debt and code duplication are the top 2 agent failure modes. Supply chain at 6 matches tooling (adjacent concern).

### New Dimension 1: Legibility (weight 8)

*Question: "Can an agent read and navigate the codebase without human explanation?"*

| ID | Name | Type | What it measures |
|---|---|---|---|
| `legibility.scannable-files` | Files sized for agent context windows | mechanical | Median file LOC <200, no god-files >500 |
| `legibility.tiered-context` | Tiered context strategy | mechanical | Root CLAUDE.md + subsystem READMEs + context-map/repomix config |
| `legibility.instruction-consistency` | Agent instructions don't contradict | mechanical | Multiple instruction files (CLAUDE.md, .cursorrules, AGENTS.md) cross-referenced. Single unified file scores HIGHER than fragmented files. |
| `legibility.convention-enforced` | Conventions enforced not just documented | mechanical | CLAUDE.md conventions backed by lint rules or CI checks |
| `legibility.decision-coverage` | Non-obvious decisions documented | judgment | ADRs/comments cover architectural choices, commit messages explain "why" |

4 mechanical, 1 judgment. Checker: `check-legibility.sh` (~150 lines). Agent: `legibility-reviewer.md` (1 criterion).

**Design notes:**
- `instruction-consistency`: A single authoritative CLAUDE.md scores HIGHER than multiple fragmented files. The scoring was inverted in the cowboy-coded branch — fix this.
- `convention-enforced`: Stays mechanical. Checks for lint config presence matching documented conventions. Moved from the patterns dimension per Engineering's recommendation.

### New Dimension 2: Patterns (weight 8)

*Question: "Does the codebase follow consistent patterns, or has agent drift created competing approaches?"*

| ID | Name | Type | What it measures |
|---|---|---|---|
| `patterns.duplication-scanning` | Duplication detection configured | mechanical | jscpd, PMD CPD, sonar duplication config present; in CI = higher score |
| `patterns.single-approach` | One pattern per concern | judgment | Consistent error handling, auth, API clients — not competing patterns |
| `patterns.naming-greppable` | Architecture follows naming | judgment | Concept names map to file paths, grep for X finds the right file |
| `patterns.import-depth` | Shallow import graph | mechanical | Average direct import path depth <3 hops |
| `patterns.error-consistency` | Error handling follows one pattern | judgment | Consistent error types, reporting, recovery across modules |

2 mechanical, 3 judgment. Checker: `check-patterns.sh` (~190 lines). Agent: `patterns-reviewer.md` (3 criteria).

**Design notes:**
- `duplication-scanning`: Named for what we CAN measure (tooling presence), not what we can't (actual duplication requires AST analysis). Per Engineering's finding that bash can't do real clone detection.
- `import-depth`: Samples direct relative import paths. Python `from ....module`, JS `../../../`, Go package depth. Directional, not precise.
- This dimension is ~60% judgment. That's architecturally valid — check-change.sh and check-structure.sh already defer 3 of 5.

### New Dimension 3: Supply Chain (weight 6)

*Question: "Are dependencies healthy, secure, and maintained?"*

| ID | Name | Type | What it measures |
|---|---|---|---|
| `supply-chain.no-vulnerabilities` | No known dependency vulnerabilities | mechanical | Audit config (npm audit, pip-audit, cargo-audit, Snyk) + CI integration |
| `supply-chain.lockfile-integrity` | Lockfiles committed and CI-verified | mechanical | Lockfile present, committed, CI checks --frozen-lockfile/npm ci |
| `supply-chain.automated-upgrades` | Automated upgrade pipeline active | mechanical | Renovate/Dependabot config + CI references |
| `supply-chain.freshness` | Dependencies reasonably current | mechanical | Lockfile age <90 days (separate from upgrade tooling — no double-counting) |
| `supply-chain.minimal-surface` | Lean dependency tree | judgment | No bloat, abandoned packages, or redundant deps |

4 mechanical, 1 judgment. Checker: `check-supply-chain.sh` (~200 lines + `lib/deps-helpers.sh`). Agent: `supply-chain-reviewer.md` (1 criterion).

**Design notes:**
- `freshness` and `automated-upgrades` MUST be clearly differentiated — the branch had a redundancy where both checked for renovate.json. Freshness = lockfile age only. Upgrades = tooling presence only.
- `check-supply-chain.sh` will exceed 300 lines without extraction. Plan `lib/deps-helpers.sh` from the start.

## Cross-Dimensional Features

### Comprehension Debt Index

A composite metric derived from signals across multiple dimensions:
- `legibility.scannable-files` score (file size distribution)
- `legibility.decision-coverage` score (documented rationale)
- `docs.decision-log` score (ADR coverage)
- `patterns.single-approach` score (pattern consistency)
- Code-to-documentation ratio (new mechanical signal in the report)

Formula: weighted harmonic mean of the contributing criteria scores. Harmonic mean penalizes weak dimensions aggressively (per Jentic JAIRF's approach) — a repo with great docs but terrible file sizes still gets a low comprehension debt index.

Displayed in the report as a secondary metric: `Comprehension Debt: <index>/10 (<label>)`. Labels: 8-10 "Agent-Clear", 5-7 "Agent-Readable", 2-4 "Agent-Murky", 0-1 "Agent-Opaque".

### Agent ROI Predictor

Maps the AXR score to expected agent productivity outcomes based on published research data:

| AXR Band | Expected Impact (from research) |
|----------|-------------------------------|
| Agent-Native (85+) | Agents productive with light supervision |
| Agent-Ready (70-84) | ~35-40% fewer agent-generated bugs vs Agent-Hazardous (Ox Security) |
| Agent-Assisted (50-69) | Agents useful for scoped tasks; 12% first-year cost overhead (Codebridge) |
| Agent-Hazardous (30-49) | 1.7x more issues, agents create more cleanup than value (Ox Security) |
| Agent-Hostile (<30) | 4x maintenance cost by year 2 (Codebridge); comprehension wall at week 7 (Osmani) |

Displayed in the summary after the score: `At this score, research suggests: <impact statement>`.

## Implementation Constraints

- **300-line gate**: All checker scripts must stay under 300 lines. `check-supply-chain.sh` needs `lib/deps-helpers.sh` extraction proactively.
- **5 criteria per dimension**: The bin/validate invariant stays. No variable criteria counts.
- **Dimension count**: bin/validate hardcodes the count — update from 9 to 12.
- **Rubric versioning**: Create `rubric.v4.json`. Preserve v1, v2, v3 for history.
- **Score drift**: v3→v4 reweight means scores change without code changes. The report MUST include a version note: "Rubric v4 rebalances toward operational readiness. Compare with /axr-diff."

## Files to Create/Modify

### New files
- `plugins/axr/rubric/rubric.v4.json`
- `plugins/axr/scripts/check-legibility.sh`
- `plugins/axr/scripts/check-patterns.sh`
- `plugins/axr/scripts/check-supply-chain.sh`
- `plugins/axr/scripts/lib/deps-helpers.sh`
- `plugins/axr/agents/legibility-reviewer.md`
- `plugins/axr/agents/patterns-reviewer.md`
- `plugins/axr/agents/supply-chain-reviewer.md`

### Modified files
- `plugins/axr/scripts/lib/common.sh` — rubric path v3→v4
- `plugins/axr/bin/validate` — dimension count 9→12, rubric path
- `plugins/axr/scripts/axr-ci.sh` — dimension arrays (add 3 new)
- `plugins/axr/commands/axr.md` — rubric path, dispatch 8 agents (not 5)
- `plugins/axr/commands/axr-check.md` — rubric path
- `plugins/axr/commands/axr-fix.md` — rubric path, add remediation strategies for new criteria
- `plugins/axr/docs/remediation-strategies.md` — add strategies for new mechanical criteria
- `plugins/axr/docs/plugin-brief.md` — dimension table, Phase entry
- `plugins/axr/README.md` — dimension table
- `plugins/axr/CLAUDE.md` — rubric version
- `plugins/axr/scripts/render-report.sh` — comprehension debt index + ROI predictor in template
- `plugins/axr/templates/report.md.template` — new sections

## Known Risks

1. **check-supply-chain.sh line count**: Needs lib extraction before language-specific deprecated-API detection expands. Plan `lib/deps-helpers.sh` from day 1.
2. **Patterns is 60% judgment**: The checker is thin but architecturally valid. Existing checkers (change, structure) set the precedent.
3. **Score drift on reweight**: Repos will see score changes from v3→v4 without code changes. Mitigated by version note in report and /axr-diff.
4. **Agent count increases 5→8**: Full /axr run dispatches 8 judgment agents instead of 5. Wall-clock time may increase. The orchestrator already dispatches in parallel.
5. **Comprehension Debt Index is a derived metric**: It depends on criteria from 3+ dimensions being scored. If some are deferred, the index degrades gracefully (uses available scores only).
