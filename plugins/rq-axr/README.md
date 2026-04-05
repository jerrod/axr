# rq-axr

Agent eXecution Readiness scoring for Claude Code.

## What it does

Grades a repository against a 100-point rubric across 8 dimensions:

| Dimension | Weight | Question |
|---|---|---|
| Tests & CI Signal | 20 | Can the agent trust feedback when it changes code? |
| Docs & Agent Context | 20 | Does the repo explain itself to a cold-start agent? |
| Change Surface Clarity | 15 | Can the agent find the right place to change and understand the blast radius? |
| Safety Rails | 15 | What stops the agent when it is wrong? |
| Structure & Modularity | 8 | Can the agent change one thing without breaking ten? |
| Tooling & Reproducibility | 8 | Are local feedback loops fast, reproducible, unambiguous? |
| Execution Visibility | 7 | Can the agent see what it did and what happened afterward? |
| Workflow Realism | 7 | Can the agent safely rehearse real work? |

Each dimension has 5 criteria scored 0–4. Mechanical criteria are resolved by deterministic bash checkers; judgment criteria are resolved by specialized review subagents with draft-flagged output for human confirmation.

## Commands

- `/axr` — full assessment on the current repo (Phase 1: `docs_context` only)
- `/axr-check <dimension>` — single-dimension assessment (Phase 2)
- `/axr-diff` — compare current run to previous (Phase 4)

## Output

Every run writes:
- `.axr/latest.json` — machine-readable per-criterion scores, evidence, and aggregation
- `.axr/latest.md` — human-readable report with band (`Agent-Native` through `Agent-Hostile`), top blockers, and next improvements
- `.axr/history/<timestamp>.json` — archive for trend tracking

## Status

**Phase 1.** One dimension (`docs_context`) has a deterministic checker; the other 7 are scaffolded but not yet implemented. See `docs/plugin-brief.md` for the authoritative spec and phase roadmap.

## Authoritative spec

`docs/plugin-brief.md` — rubric, scoring passes, stack detection, operational rules, orchestrator performance requirements.
