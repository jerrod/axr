# 2. Scripts-First Architecture

**Status:** Accepted

## Context

The axr rubric could be evaluated by: (a) a single monolithic LLM prompt that reads everything, (b) language-specific libraries (Python, Node, etc.), or (c) deterministic bash scripts per dimension with LLM judgment subagents for qualitative criteria.

## Decision

Use bash scripts for all mechanical (deterministic) criteria and Claude Code subagents for judgment (qualitative) criteria. Scripts emit per-criterion JSON to stdout. The `/axr` command orchestrates both layers.

## Consequences

- Mechanical scores are reproducible and auditable (same input = same output)
- No runtime dependencies beyond bash + jq + git
- Plugin works on any OS with a POSIX shell
- Judgment criteria can improve independently as LLM capabilities evolve
- Scripts must stay under 300 lines (enforced by filesize gate)
- Adding a new language means touching multiple scripts, not writing a new library
