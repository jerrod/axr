# Integration Points

How axr's components connect to each other and to external systems.

## Internal Contracts

### Checker → Aggregate Pipeline

```
check-*.sh → stdout JSON → aggregate.sh → .axr/latest.{json,md}
```

Each checker emits a JSON object with fields: `dimension_id`, `stack`, `reviewer`, `criteria[]`. The `criteria` array contains objects with: `id`, `name`, `score`, `evidence[]`, `notes`, `reviewer`. Schema documented in `plugins/axr/docs/agent-output-schema.md`.

### Agent → Merge Pipeline

```
agent-*.md → Task tool → JSON array → merge-agents.sh → overlay onto dimension JSON
```

Agents emit a bare JSON array of criterion objects (same schema as checker criteria, but `reviewer: "agent-draft"`). `merge-agents.sh` validates: id format `^[a-z_]+\.[0-9]+$`, score 0-3, reviewer "agent-draft", evidence is array of strings (max 20, each ≤500 chars), notes ≤500 chars.

### Orchestrator → Checker Dispatch

```
/axr command → for checker in check-*.sh → parallel background → wait → validate → aggregate
```

The `/axr` command auto-discovers checkers by globbing `${CLAUDE_PLUGIN_ROOT}/scripts/check-*.sh`. Adding a new dimension = adding a new checker script. No registration needed.

## External Contracts

### Claude Code Plugin Loader

- Commands: auto-discovered from `commands/*.md` (must have YAML frontmatter with `description`)
- Agents: auto-discovered from `agents/*.md` (must have YAML frontmatter — files without frontmatter break discovery for the entire directory)
- Manifest: `.claude-plugin/plugin.json` with `name`, `version`, `description`

### `.axr/latest.json` Schema

Consumed by: `/axr-diff`, `/axr-fix`, `/axr-check`, `axr-ci.sh`, future GitHub App.

Top-level fields: `rubric_version`, `total_score`, `band`, `scored_at`, `dimensions{}`, `blockers[]`.

### `.axr/config.json` (CI)

Optional configuration for `axr-ci.sh`: `ci_minimum_band` (string), `ci_fail_on_blockers` (boolean).
