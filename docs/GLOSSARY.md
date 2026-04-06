# AXR Glossary

| Term | Definition |
|------|-----------|
| **Agent ROI Predictor** | A band-to-impact mapping in the AXR report that translates the overall score band into a research-backed statement about expected agent productivity and cost impact |
| **AXR** | Agent eXecution Readiness — a 100-point rubric measuring how safely and productively a repository can be operated by coding agents |
| **Band** | Score range label: Agent-Native (85-100), Agent-Ready (70-84), Agent-Assisted (50-69), Agent-Hazardous (30-49), Agent-Hostile (0-29) |
| **Blocker** | A criterion scoring ≤1 in a high-weight dimension, surfaced in the top-3 blockers list as the highest-leverage improvement target |
| **Checker** | A bash script (`check-*.sh`) that scores one dimension's mechanical criteria deterministically |
| **Comprehension Debt Index** | A composite metric (0-10 scale) computed as the harmonic mean of four criterion scores (context-window-fit, decision-coverage, decision-log, single-approach), measuring how much understanding debt the codebase carries for agents |
| **Criterion** | A single scoreable item within a dimension, scored 0-4 (Absent → Exemplary) |
| **Deferred** | A judgment criterion not yet scored by a subagent, defaulted to score 1 with `defaulted_from_deferred: true` |
| **Dimension** | One of 12 scoring categories (e.g., Tests & CI Signal, Docs & Agent Context), each with a weight and 5 criteria |
| **Evidence** | Concrete file paths, patterns, or observations supporting a criterion's score |
| **Judgment criterion** | A criterion requiring qualitative LLM assessment (vs mechanical/deterministic) |
| **Legibility** | An AXR rubric dimension (weight 8) measuring whether an agent can read and navigate the codebase without human explanation. Includes context window fit, tiered context, instruction consistency, convention enforcement, and decision coverage |
| **Mechanical criterion** | A criterion scored deterministically by a bash checker script |
| **Monorepo** | A repository containing multiple packages; axr detects lerna, nx, turbo, pnpm-workspace, Gradle multi-project, and Cargo workspace layouts |
| **Patterns** | An AXR rubric dimension (weight 8) measuring whether the codebase uses one way to do each thing. Includes duplication scanning, single approach, competing patterns, import depth, and error consistency |
| **Rubric** | The versioned JSON document defining dimensions, criteria, weights, and score bands |
| **Scorer / Subagent** | An LLM agent dispatched by `/axr` to assess judgment criteria for a specific dimension cluster |
| **Stack** | The detected programming language/framework (Python, Node, Java, etc.) used to select relevant evidence paths |
| **Supply Chain** | An AXR rubric dimension (weight 6) measuring whether dependencies are managed, audited, and current. Includes vulnerability scanning, lockfile verification, automated upgrades, freshness, and minimal surface |
| **Weight** | A dimension's contribution to the 100-point total (e.g., Tests & CI = 14, Docs = 14) |
