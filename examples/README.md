# Examples

Worked examples demonstrating axr usage and extension.

## Scoring a repo

```bash
# Install the axr plugin
# In Claude Code: /plugin → Add Marketplace → jerrod/axr

# Run a full assessment
/axr

# Check a single dimension
/axr-check docs_context

# Compare to previous run
/axr-diff

# Fix low-scoring criteria
/axr-fix blockers
```

## CI integration

```bash
# Run mechanical-only scoring in CI (no LLM needed)
plugins/axr/scripts/axr-ci.sh

# With a config file
echo '{"ci_minimum_band": "Agent-Assisted", "ci_fail_on_blockers": true}' > .axr/config.json
plugins/axr/scripts/axr-ci.sh --config .axr/config.json

# Exit code: 0 = pass, 1 = below threshold
```

## Adding a new dimension checker

See `examples/custom-checker.sh` for a template.

## Sample `.axr/config.json`

```json
{
  "ci_minimum_band": "Agent-Assisted",
  "ci_fail_on_blockers": true
}
```
