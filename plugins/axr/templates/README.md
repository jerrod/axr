# templates/

Markdown templates used by `render-report.sh` to generate `.axr/latest.md`.

| File | Purpose |
|------|---------|
| `report.md.template` | Human-readable scoring report with dimension table, blockers, and agent-draft section |

Templates use `{{placeholder}}` syntax. The `write_token` helper in `render-report.sh` handles substitution with template-injection sanitization.
