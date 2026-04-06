# agents/

Judgment subagent definitions. Each `.md` file is auto-discovered by the plugin loader. The `/axr` orchestrator dispatches these via the Task tool to score criteria that require qualitative assessment.

| Agent | Criteria |
|-------|----------|
| docs-reviewer | docs.subsystem-readmes, .5 |
| architecture-reviewer | change.locatable-logic, .2, .4; structure.module-boundaries, .3, .4 |
| safety-reviewer | safety.hitl-checkpoints, .2 |
| observability-reviewer | visibility.structured-logging, .2, .4 |
| workflow-reviewer | tests.boundary-coverage; workflow.fixtures, .2, .4 |

All agents output a JSON array of criterion objects per `docs/agent-output-schema.md`. Agents have Read/Grep/Glob tools only (no Bash — removed for security in Phase 2B).
