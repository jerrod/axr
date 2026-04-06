# axr

Agent eXecution Readiness scoring for Claude Code.

## What it does

Grades a repository against a 100-point rubric across 9 dimensions:

| Dimension | Weight | Question |
|---|---|---|
| Tests & CI Signal | 18 | Can the agent trust feedback when it changes code? |
| Docs & Agent Context | 18 | Does the repo explain itself to a cold-start agent? |
| Change Surface Clarity | 14 | Can the agent find the right place to change and understand the blast radius? |
| Safety Rails | 14 | What stops the agent when it is wrong? |
| Style & Validation | 10 | Is code quality enforced mechanically before review? |
| Structure & Modularity | 8 | Can the agent change one thing without breaking ten? |
| Tooling & Reproducibility | 6 | Are local feedback loops fast, reproducible, unambiguous? |
| Execution Visibility | 6 | Can the agent see what it did and what happened afterward? |
| Workflow Realism | 6 | Can the agent safely rehearse real work? |

Each dimension has 5 criteria scored 0–4. Mechanical criteria are resolved by deterministic bash checkers; judgment criteria are resolved by specialized review subagents with draft-flagged output for human confirmation.

## Commands

- `/axr` — full assessment on the current repo
- `/axr-check <dimension>` — single-dimension assessment
- `/axr-diff` — compare current run to previous
- `/axr-fix <target>` — auto-remediation for low-scoring criteria (`blockers`, criterion id, or dimension id)

## Supported Stacks

Python, Node/TypeScript, Kotlin, Java, Ruby, Rust, Go, C#/.NET, PHP, Swift, Markdown (fallback).

Stack detection is automatic — axr reads manifest files (package.json, pyproject.toml, pom.xml, *.csproj, composer.json, Package.swift, etc.) to determine the active stack and select appropriate linter, formatter, type-checker, and test runner evidence.

## Output

Every run writes:
- `.axr/latest.json` — machine-readable per-criterion scores, evidence, and aggregation
- `.axr/latest.md` — human-readable report with band (`Agent-Native` through `Agent-Hostile`), top blockers, and next improvements
- `.axr/history/<timestamp>.json` — archive for trend tracking

## Monorepo

AXR auto-detects monorepo workspaces (lerna, nx, turbo, pnpm, Gradle multi-project, Cargo workspace). Per-package dimensions (tests_ci, docs_context, style_validation, tooling) are scored independently for each package; repo-level dimensions are scored once at the root. Scores are averaged across packages.

## CI Integration

`scripts/axr-ci.sh` runs a non-interactive assessment for CI pipelines. Configure thresholds via `.axr/config.json` (`ci_minimum_band`, `ci_fail_on_blockers`). See `docs/plugin-brief.md` for details.

```bash
scripts/axr-ci.sh --config .axr/config.json
```

## Status

**Rubric v2.0.** All 9 dimensions have deterministic checkers for mechanical criteria; 5 judgment subagents score the 17 judgment criteria. See `docs/plugin-brief.md` for the authoritative spec.

## Authoritative spec

`docs/plugin-brief.md` — rubric, scoring passes, stack detection, operational rules, orchestrator performance requirements.
