# AXR Glossary

| Term | Definition |
|------|-----------|
| **AXR** | Agent eXecution Readiness — a 100-point rubric measuring how safely and productively a repository can be operated by coding agents |
| **Band** | Score range label: Agent-Native (85-100), Agent-Ready (70-84), Agent-Assisted (50-69), Agent-Hazardous (30-49), Agent-Hostile (0-29) |
| **Blocker** | A criterion scoring ≤1 in a high-weight dimension, surfaced in the top-3 blockers list as the highest-leverage improvement target |
| **Checker** | A bash script (`check-*.sh`) that scores one dimension's mechanical criteria deterministically |
| **Criterion** | A single scoreable item within a dimension, scored 0-4 (Absent → Exemplary) |
| **Deferred** | A judgment criterion not yet scored by a subagent, defaulted to score 1 with `defaulted_from_deferred: true` |
| **Dimension** | One of 9 scoring categories (e.g., Tests & CI Signal, Docs & Agent Context), each with a weight and 5 criteria |
| **Evidence** | Concrete file paths, patterns, or observations supporting a criterion's score |
| **Judgment criterion** | A criterion requiring qualitative LLM assessment (vs mechanical/deterministic) |
| **Mechanical criterion** | A criterion scored deterministically by a bash checker script |
| **Monorepo** | A repository containing multiple packages; axr detects lerna, nx, turbo, pnpm-workspace, Gradle multi-project, and Cargo workspace layouts |
| **Rubric** | The versioned JSON document defining dimensions, criteria, weights, and score bands |
| **Scorer / Subagent** | An LLM agent dispatched by `/axr` to assess judgment criteria for a specific dimension cluster |
| **Stack** | The detected programming language/framework (Python, Node, Java, etc.) used to select relevant evidence paths |
| **Weight** | A dimension's contribution to the 100-point total (e.g., Tests & CI = 18, Docs = 18) |
