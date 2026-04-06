# Context Map — axr marketplace

## Repository Structure (bounded context summary)

```
axr/
├── .claude-plugin/marketplace.json   # Marketplace manifest (plugin registry)
├── .github/workflows/ci.yml          # CI: validate, lint, test, axr-score
├── bin/                               # Marketplace-level gate scripts
│   ├── validate                       # Structure + schema validation
│   ├── lint                           # Shellcheck + JSON + frontmatter
│   └── test                           # Run all checkers, verify JSON output
├── docs/                              # Repo-level documentation
│   ├── adr/                           # Architecture Decision Records
│   ├── GLOSSARY.md                    # Domain term definitions
│   └── integration-points.md          # Internal + external contracts
├── examples/                          # Usage examples + templates
└── plugins/axr/                       # The axr plugin
    ├── .claude-plugin/plugin.json     # Plugin manifest
    ├── commands/                       # Slash commands (/axr, /axr-check, /axr-diff, /axr-fix)
    ├── agents/                        # Judgment subagent definitions (5 agents, 17 criteria)
    ├── scripts/                       # Bash checkers (9) + aggregation + CI script
    │   ├── check-*.sh                 # Per-dimension mechanical scorers
    │   ├── aggregate.sh               # Score computation + report generation
    │   ├── axr-ci.sh                  # CI fast-path (mechanical only)
    │   └── lib/                       # Shared helpers (common, markdown, workflow, tooling, monorepo)
    ├── rubric/                        # Versioned rubric JSON (v1, v2)
    ├── docs/                          # Plugin docs (brief, schema, remediation strategies)
    └── templates/                     # Report markdown template
```

## Key Concepts

- **9 dimensions**, each with 5 criteria (45 total), weighted to 100 points
- **Mechanical criteria**: scored by bash scripts deterministically
- **Judgment criteria**: scored by LLM subagents with human confirmation
- **Score bands**: Agent-Native (85+), Agent-Ready (70+), Agent-Assisted (50+), Agent-Hazardous (30+), Agent-Hostile (<30)

## Module Boundaries

- `scripts/check-*.sh` → `scripts/lib/common.sh` (one-way dependency)
- `scripts/aggregate.sh` → `scripts/lib/common.sh` + `scripts/render-report.sh`
- `commands/*.md` → `scripts/check-*.sh` + `scripts/aggregate.sh` (via shell invocation)
- `agents/*.md` → target repo files (read-only, no dependency on plugin scripts)
