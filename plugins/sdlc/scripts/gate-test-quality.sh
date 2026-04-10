#!/usr/bin/env bash
# Gate: Test Quality — detect disguised mocks in test files
# Catches: spyOn().mockImplementation(), spyOn().mockReturnValue(), etc.
# Only flags mocks on INTERNAL code, not external boundaries.
# Produces: .quality/proof/test-quality.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-test-quality.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/test-quality.json" <<CRASHJSON
{
  "gate": "test-quality",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "scanned_files": 0,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/test-quality.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

# Get changed test files
CHANGED_TESTS=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- \
  '*.test.ts' '*.test.tsx' '*.test.js' '*.test.jsx' \
  '*.spec.ts' '*.spec.tsx' '*.spec.js' '*.spec.jsx' \
  '*_test.py' '*test_*.py' \
  '*_test.go' \
  '*Test.java' '*Test.kt' \
  '*_spec.rb' '*_test.rb' \
  2>/dev/null || git diff --name-only --cached -- \
  '*.test.ts' '*.test.tsx' '*.test.js' '*.test.jsx' \
  '*.spec.ts' '*.spec.tsx' '*.spec.js' '*.spec.jsx' \
  '*_test.py' '*test_*.py' \
  '*_test.go' \
  '*Test.java' '*Test.kt' \
  '*_spec.rb' '*_test.rb' \
  2>/dev/null || true)

VIOLATIONS=()

if [ -n "$CHANGED_TESTS" ]; then
  while IFS= read -r test_file; do
    [ -f "$test_file" ] || continue

    # Scan for disguised mock patterns using external Python scanner
    FOUND=$(python3 "$SCRIPT_DIR/scan_disguised_mocks.py" "$test_file" 2>/dev/null || true)

    if [ -n "$FOUND" ] && [ "$FOUND" != "null" ]; then
      # Check allow list for each violation
      local_violations=$(python3 -c "
import json, sys
violations = json.loads(sys.argv[1])
file = sys.argv[2]
for v in violations:
    print(json.dumps({
        'file': file,
        'line': v['line'],
        'pattern': v['pattern'],
        'code': v['code']
    }))
" "$FOUND" "$test_file" 2>/dev/null || true)

      while IFS= read -r vio; do
        [ -z "$vio" ] && continue
        vio_pattern=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['pattern'])" "$vio" 2>/dev/null || true)
        is_allowed "test-quality" "file=$test_file" "pattern=$vio_pattern" && continue
        VIOLATIONS+=("$vio")
      done <<<"$local_violations"
    fi
  done <<<"$CHANGED_TESTS"
fi

# Clear crash trap
trap - ERR

GATE_STATUS="pass"
VIO_JSON=""
if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  GATE_STATUS="fail"
  VIO_JSON=$(printf '%s,' "${VIOLATIONS[@]}" | sed 's/,$//')
fi

cat >"$PROOF_DIR/test-quality.json" <<ENDJSON
{
  "gate": "test-quality",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "violations": [${VIO_JSON}],
  "scanned_files": $(if [ -n "$CHANGED_TESTS" ]; then echo "$CHANGED_TESTS" | grep -c '.' 2>/dev/null || echo 0; else echo 0; fi),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/test-quality.json"

report_unused_allow_entries test-quality

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint test-quality
  echo "GATE FAILED: ${#VIOLATIONS[@]} disguised mock(s) found in test files" >&2
  echo "A spyOn() with .mockImplementation/.mockReturnValue/.mockResolvedValue replaces real code — it's a mock, not a spy." >&2
  echo "Fix: remove the .mock*() chain to use a real spy, or mock at the external boundary instead." >&2
  exit 1
fi
