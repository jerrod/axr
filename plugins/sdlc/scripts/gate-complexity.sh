#!/usr/bin/env bash
# Gate: Complexity — AST-based analysis with tool fallback
# Uses analyze_complexity.py (radon, oxlint, gocyclo) with regex heuristic fallback.
# Produces: .quality/proof/complexity.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"
# shellcheck source=plugins/sdlc/scripts/commands-config.sh
source "$SCRIPT_DIR/commands-config.sh"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/complexity.json" <<CRASHJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "files_checked": 0,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/complexity.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

CHANGED_FILES=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' 2>/dev/null || git diff --name-only --cached -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' 2>/dev/null || true)

# No test file exclusion — real AST tools handle test files correctly.

if [ -z "$CHANGED_FILES" ]; then
  trap - ERR
  cat >"$PROOF_DIR/complexity.json" <<ENDJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "pass",
  "error": null,
  "files_checked": 0,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
  cat "$PROOF_DIR/complexity.json"
  exit 0
fi

# Convert newline-separated file list to space-separated args
FILE_ARGS=()
CHECKED=0
while IFS= read -r file; do
  [ -f "$file" ] || continue
  FILE_ARGS+=("$file")
  CHECKED=$((CHECKED + 1))
done <<<"$CHANGED_FILES"

if [ ${#FILE_ARGS[@]} -eq 0 ]; then
  trap - ERR
  cat >"$PROOF_DIR/complexity.json" <<ENDJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "pass",
  "error": null,
  "files_checked": 0,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
  cat "$PROOF_DIR/complexity.json"
  exit 0
fi

# Check for explicit SARIF config
CMD_CONFIG=$(get_command "complexity")
if [ -n "$CMD_CONFIG" ]; then
  parse_command_config "$CMD_CONFIG"

  if [ "$_CMD_FORMAT" = "sarif" ] && [ -n "$_CMD_REPORT" ]; then
    # Run command if specified (array-split, no eval)
    if [ -n "$_CMD_RUN" ]; then
      read -ra _cmd_array <<<"$_CMD_RUN"
      "${_cmd_array[@]}" >/dev/null 2>&1 || true
    fi

    SARIF_FINDINGS=$(python3 "$SCRIPT_DIR/parse_sarif.py" "$_CMD_REPORT" "complexity/" 2>/dev/null || echo "[]")
    VIOLATION_COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$SARIF_FINDINGS" 2>/dev/null || echo 0)

    # Convert SARIF findings to sdlc violation format
    VIO_FORMATTED=$(python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
violations = []
for f in findings:
    violations.append({
        'file': f['file'],
        'function': f['message'],
        'complexity': 0,
        'lines': 0,
        'issue': f['rule_id'] + ': ' + f['message'],
    })
print(json.dumps(violations, indent=2))
" "$SARIF_FINDINGS" 2>/dev/null || echo "[]")

    GATE_STATUS="pass"
    if [ "$VIOLATION_COUNT" -gt 0 ] 2>/dev/null; then
      GATE_STATUS="fail"
    fi

    trap - ERR
    cat >"$PROOF_DIR/complexity.json" <<ENDJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "files_checked": $CHECKED,
  "violations": $VIO_FORMATTED,
  "source": "sarif",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
    cat "$PROOF_DIR/complexity.json"
    [ "$GATE_STATUS" = "fail" ] && echo "GATE FAILED: $VIOLATION_COUNT complexity violation(s) from SARIF" >&2 && exit 1
    exit 0
  fi
fi

# Kotlin skip guard: skip with informational message if no SARIF/detekt
HAS_KOTLIN_ONLY=true
for f in "${FILE_ARGS[@]}"; do
  case "$f" in
    *.kt) ;; # Kotlin file — check continues
    *)
      HAS_KOTLIN_ONLY=false
      break
      ;;
  esac
done

if [ "$HAS_KOTLIN_ONLY" = true ]; then
  # All changed files are Kotlin with no SARIF config — skip
  trap - ERR
  echo "Complexity analysis skipped for Kotlin (no detekt/SARIF configured)." >&2
  echo "Add detekt for complexity enforcement." >&2
  cat >"$PROOF_DIR/complexity.json" <<ENDJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "skip",
  "reason": "Kotlin files without detekt/SARIF — no reliable complexity analysis available",
  "error": null,
  "files_checked": $CHECKED,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
  cat "$PROOF_DIR/complexity.json"
  exit 0
fi

# Run the Python analysis engine
# Capture stderr separately — show on failure, suppress on success.
# Without this, a crashed script silently returns "[]" and the gate passes.
ANALYSIS_STDERR=$(mktemp)
ANALYSIS_EXIT=0
VIOLATIONS_JSON=$(python3 "$SCRIPT_DIR/analyze_complexity.py" \
  --files "${FILE_ARGS[@]}" \
  --max-function-lines "$SDLC_MAX_FUNCTION_LINES" \
  --max-complexity "$SDLC_MAX_COMPLEXITY" \
  --allow-json "$_RQ_ALLOW_CONFIG" 2>"$ANALYSIS_STDERR") || ANALYSIS_EXIT=$?

if [ $ANALYSIS_EXIT -ne 0 ] || [ -z "$VIOLATIONS_JSON" ]; then
  echo "analyze_complexity.py failed (exit $ANALYSIS_EXIT):" >&2
  cat "$ANALYSIS_STDERR" >&2
  rm -f "$ANALYSIS_STDERR"
  VIOLATIONS_JSON="[]"
  # Let the gate fail — a crashed analyzer is not a clean pass
  if [ $ANALYSIS_EXIT -ne 0 ]; then
    trap - ERR
    cat >"$PROOF_DIR/complexity.json" <<FAILJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "fail",
  "error": "analyze_complexity.py crashed with exit code $ANALYSIS_EXIT",
  "files_checked": $CHECKED,
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
FAILJSON
    cat "$PROOF_DIR/complexity.json"
    echo "GATE FAILED: analysis script crashed" >&2
    exit 1
  fi
fi
rm -f "$ANALYSIS_STDERR"

# Clear ERR trap — analysis complete, write proof normally
trap - ERR

# Count violations from JSON array
VIOLATION_COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$VIOLATIONS_JSON" 2>/dev/null || echo 0)

GATE_STATUS="pass"
if [ "$VIOLATION_COUNT" -gt 0 ] 2>/dev/null; then
  GATE_STATUS="fail"
fi

# Format the violations array for proof JSON
VIO_FORMATTED=$(python3 -c "
import json, sys
violations = json.loads(sys.argv[1])
print(json.dumps(violations, indent=2))
" "$VIOLATIONS_JSON" 2>/dev/null || echo "[]")

cat >"$PROOF_DIR/complexity.json" <<ENDJSON
{
  "gate": "complexity",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "files_checked": $CHECKED,
  "violations": $VIO_FORMATTED,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/complexity.json"

if [ "$GATE_STATUS" = "fail" ]; then
  echo "GATE FAILED: $VIOLATION_COUNT complexity violation(s)" >&2
  exit 1
fi
