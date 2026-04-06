# agents/

Judgment subagent definitions. Each `.md` file is auto-discovered by the plugin loader. The `/axr` orchestrator dispatches these via the Task tool to score criteria that require qualitative assessment.

| Agent | Criteria |
|-------|----------|
| docs-reviewer | docs_context.3, .5 |
| architecture-reviewer | change_surface.1, .2, .4; structure.1, .3, .4 |
| safety-reviewer | safety_rails.1, .2 |
| observability-reviewer | execution_visibility.1, .2, .4 |
| workflow-reviewer | tests_ci.2; workflow_realism.1, .2, .4 |

All agents output a JSON array of criterion objects per `docs/agent-output-schema.md`. Agents have Read/Grep/Glob tools only (no Bash — removed for security in Phase 2B).
