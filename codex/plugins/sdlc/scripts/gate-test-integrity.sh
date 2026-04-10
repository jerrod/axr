#!/usr/bin/env bash
# Gate: Test Integrity — detect weakened pre-implementation tests
# Checks if assertion lines from the test-writer commit were deleted or changed.
# Task-scoped — only runs when a test-writer commit exists for the current task.
# Produces: .quality/proof/test-integrity.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Accept task number as argument (optional — used by subagent-build controller)
TASK_NUM="${1:-}"

# Trap: produce proof JSON on unexpected crash (inline to avoid SC2329)
trap 'printf "{\"gate\":\"test-integrity\",\"status\":\"fail\",\"error\":\"script crashed\"}\n" >"$PROOF_DIR/test-integrity.json"; echo "GATE FAILED: script crashed" >&2' ERR

# Find the test-writer commit
if [ -n "$TASK_NUM" ]; then
  TEST_AGENT_COMMIT=$(git log --oneline --grep="test: write failing tests for task $TASK_NUM" | head -1 | awk '{print $1}')
else
  # Fall back to most recent test-writer commit
  TEST_AGENT_COMMIT=$(git log --oneline --grep="test: write failing tests" | head -1 | awk '{print $1}')
fi

# If no test-writer commit found, gate is not applicable — pass
if [ -z "$TEST_AGENT_COMMIT" ]; then
  cat >"$PROOF_DIR/test-integrity.json" <<SKIPJSON
{
  "gate": "test-integrity",
  "sha": "$(git rev-parse HEAD)",
  "test_agent_sha": null,
  "status": "pass",
  "message": "No test-writer commit found — gate not applicable",
  "weakened_assertions": [],
  "deleted_assertions": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
SKIPJSON
  cat "$PROOF_DIR/test-integrity.json"
  exit 0
fi

# Get test files from the test-writer commit
TEST_FILES=$(git diff-tree --no-commit-id --name-only -r "$TEST_AGENT_COMMIT" -- \
  '*.test.ts' '*.test.tsx' '*.test.js' '*.test.jsx' \
  '*.spec.ts' '*.spec.tsx' '*.spec.js' '*.spec.jsx' \
  '*_test.py' '*test_*.py' \
  '*_test.go' '*_test.rb' '*_spec.rb' \
  '*Test.java' '*Test.kt' \
  2>/dev/null || true)

DELETED=()

if [ -n "$TEST_FILES" ]; then
  # Check for deleted or weakened assertion lines
  ASSERTION_PATTERN='expect\|assert\|toBe\|toEqual\|toThrow\|toMatch\|toContain\|assertEqual\|assertRaises\|assertTrue\|assertFalse\|assertIn\|should\|must'

  while IFS= read -r test_file; do
    [ -f "$test_file" ] || continue

    # Get deleted assertion lines (lines starting with - that contain assertion keywords)
    DELETED_LINES=$(git diff "$TEST_AGENT_COMMIT" HEAD -- "$test_file" | grep "^-" | grep -v "^---" | grep -i "$ASSERTION_PATTERN" || true)

    if [ -n "$DELETED_LINES" ]; then
      while IFS= read -r line; do
        DELETED+=("{\"file\": \"$test_file\", \"line\": \"$(echo "$line" | sed 's/"/\\"/g' | cut -c1-120)\"}")
      done <<<"$DELETED_LINES"
    fi
  done <<<"$TEST_FILES"
fi

# Clear crash trap
trap - ERR

# Build result
if [ ${#DELETED[@]} -gt 0 ]; then
  STATUS="fail"
  VIOLATIONS=$(printf '%s,' "${DELETED[@]}")
  VIOLATIONS="[${VIOLATIONS%,}]"
else
  STATUS="pass"
  VIOLATIONS="[]"
fi

cat >"$PROOF_DIR/test-integrity.json" <<RESULTJSON
{
  "gate": "test-integrity",
  "sha": "$(git rev-parse HEAD)",
  "test_agent_sha": "$TEST_AGENT_COMMIT",
  "status": "$STATUS",
  "weakened_assertions": $VIOLATIONS,
  "deleted_assertions": $VIOLATIONS,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
RESULTJSON

cat "$PROOF_DIR/test-integrity.json"

if [ "$STATUS" = "fail" ]; then
  echo ""
  echo "GATE FAILED: Pre-implementation test assertions were weakened or deleted."
  echo "The following assertion lines from the test-writer commit ($TEST_AGENT_COMMIT) were removed:"
  printf '%s\n' "${DELETED[@]}"
  echo ""
  echo "Implementers may ADD tests but must NOT modify or delete pre-written test assertions."
  echo "If a test assumption is wrong, report DONE_WITH_CONCERNS with CONFLICT_REASON."
  exit 1
fi

exit 0
