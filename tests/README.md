# tests/

Test fixtures and validation data for the axr plugin's dimension checkers.

## Structure

- `fixtures/` — sample repo structures for testing checkers against known configurations
- The primary test runner is `bin/test` which validates all `check-*.sh` scripts produce schema-valid JSON

## Running tests

```bash
bin/test
```

This runs `bin/validate` first, then executes every `plugins/axr/scripts/check-*.sh` script and verifies:
1. Each produces valid JSON to stdout
2. Each JSON has `dimension_id` (string) and `criteria` (array of 5)
3. Each criterion has `id`, `name`, `score` (or null if deferred), and `evidence` (array)
