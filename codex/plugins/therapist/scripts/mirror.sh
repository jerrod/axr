#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# mirror.sh — PostToolUse hook for Bash
#
# Reflects quality command failures back with specific numbers.
# Enhanced with:
#   - Successive approximation: tracks progress toward targets
#   - Behavioral experiments: resolves predictions and reports accuracy
#   - Regression detection: flags metrics that got worse
#
# Input: JSON on stdin with tool_input.command and tool_output
# Output: JSON with additionalContext on failure, silent exit otherwise

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"

ensure_therapist_dir

INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
OUTPUT=$(printf '%s' "$INPUT" | jq -r '.tool_output // ""')

if ! is_quality_command "$COMMAND"; then
  exit 0
fi

# --- Extract metrics from output ---

extract_coverage() {
  local line="" pct=""
  line=$(printf '%s' "$OUTPUT" | grep -iE '(coverage|cov)' | tail -1 || true)
  if [[ -n "$line" ]]; then
    pct=$(printf '%s' "$line" | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 || true)
  fi
  if [[ -z "$pct" ]]; then
    pct=$(printf '%s' "$OUTPUT" | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 || true)
  fi
  if [[ -n "$pct" ]]; then
    printf '%s' "${pct%\%}"
  fi
}

extract_test_failures() {
  local count=""
  # Match "3 failed" or "FAILED 3 tests" patterns
  count=$(printf '%s' "$OUTPUT" | grep -oiE '[0-9]+ (failed|failure)' | head -1 | grep -oE '[0-9]+' || true)
  if [[ -z "$count" ]]; then
    count=$(printf '%s' "$OUTPUT" | grep -oiE 'FAILED [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi
  printf '%s' "$count"
}

extract_lint_errors() {
  printf '%s' "$OUTPUT" | grep -oiE '[0-9]+ (error|warning|violation)' | head -1 | grep -oE '[0-9]+' || true
}

# --- Record measurements and check progress ---

record_and_check_progress() {
  local metric="$1" value="$2" target="$3"
  local progress_msg=""

  # Get previous measurement
  local prev_data
  prev_data=$(journal_last_measurement "$metric" 2>/dev/null || true)

  # Record current measurement
  bash "${SCRIPT_DIR}/journal.sh" log \
    "measurement" \
    "${COMMAND}" \
    "Measured ${metric}: ${value}" \
    --source=mirror \
    --metric="${metric}" \
    --value="${value}" \
    --target="${target}" >/dev/null 2>&1 || true

  if [[ -n "$prev_data" ]]; then
    local prev_value
    prev_value="${prev_data%%|*}"
    if [[ -n "$prev_value" ]]; then
      if [[ "$metric" == "coverage" ]]; then
        # Higher is better for coverage
        if V="$value" PV="$prev_value" python3 -c "import os; exit(0 if float(os.environ['V']) > float(os.environ['PV']) else 1)" 2>/dev/null; then
          local delta gap
          delta=$(V="$value" PV="$prev_value" python3 -c "import os; print(f'{float(os.environ[\"V\"]) - float(os.environ[\"PV\"]):.1f}')" 2>/dev/null || echo "?")
          gap=$(T="$target" V="$value" python3 -c "import os; print(f'{float(os.environ[\"T\"]) - float(os.environ[\"V\"]):.1f}')" 2>/dev/null || echo "?")
          progress_msg="Progress: +${delta} points from ${prev_value}%. Gap: ${gap} points remaining."
        elif V="$value" PV="$prev_value" python3 -c "import os; exit(0 if float(os.environ['V']) < float(os.environ['PV']) else 1)" 2>/dev/null; then
          # REGRESSION
          progress_msg="REGRESSION: Coverage dropped from ${prev_value}% to ${value}%."
          bash "${SCRIPT_DIR}/journal.sh" log \
            "regression" \
            "${COMMAND}" \
            "Coverage regressed from ${prev_value} to ${value}" \
            --source=mirror \
            --metric="${metric}" \
            --value="${value}" \
            --category="premature-closure" >/dev/null 2>&1 || true
        fi
      else
        # Lower is better for errors/failures
        if V="$value" PV="$prev_value" python3 -c "import os; exit(0 if float(os.environ['V']) < float(os.environ['PV']) else 1)" 2>/dev/null; then
          local delta
          delta=$(PV="$prev_value" V="$value" python3 -c "import os; print(f'{float(os.environ[\"PV\"]) - float(os.environ[\"V\"]):.0f}')" 2>/dev/null || echo "?")
          progress_msg="Progress: -${delta} from ${prev_value}. Target: ${target}."
        elif V="$value" PV="$prev_value" python3 -c "import os; exit(0 if float(os.environ['V']) > float(os.environ['PV']) else 1)" 2>/dev/null; then
          # REGRESSION
          progress_msg="REGRESSION: ${metric} increased from ${prev_value} to ${value}."
          bash "${SCRIPT_DIR}/journal.sh" log \
            "regression" \
            "${COMMAND}" \
            "${metric} regressed from ${prev_value} to ${value}" \
            --source=mirror \
            --metric="${metric}" \
            --value="${value}" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi

  printf '%s' "$progress_msg"
}

# --- Resolve open predictions (behavioral experiments) ---

resolve_predictions() {
  local gate_passed="$1"
  local experiment_msg=""

  local predictions
  predictions=$(journal_open_predictions 2>/dev/null || true)

  if [[ -z "$predictions" ]]; then
    printf '%s' "$experiment_msg"
    return
  fi

  local actual="fail"
  if [[ "$gate_passed" == "true" ]]; then
    actual="pass"
  fi

  while IFS= read -r pred_line; do
    [[ -z "$pred_line" ]] && continue
    local pred_ts pred_predicted pred_category
    pred_ts=$(printf '%s' "$pred_line" | jq -r '.ts // ""')
    pred_predicted=$(printf '%s' "$pred_line" | jq -r '.predicted // ""')
    pred_category=$(printf '%s' "$pred_line" | jq -r '.category // ""')

    bash "${SCRIPT_DIR}/journal.sh" log \
      "outcome" \
      "${COMMAND}" \
      "Prediction resolved: predicted=${pred_predicted}, actual=${actual}" \
      --source=mirror \
      --category="${pred_category}" \
      --predicted="${pred_predicted}" \
      --prediction-ts="${pred_ts}" >/dev/null 2>&1 || true
  done <<<"$predictions"

  # Get accuracy stats
  local accuracy_data
  accuracy_data=$(journal_prediction_accuracy "" "7d" 2>/dev/null || true)

  if [[ -n "$accuracy_data" ]] && [[ "$accuracy_data" != "no_data" ]]; then
    IFS='|' read -r pct ratio rest <<<"$accuracy_data"
    experiment_msg="EXPERIMENT: Prediction accuracy ${pct} (${ratio})."
    if [[ -n "$rest" ]]; then
      experiment_msg+=" Recent: ${rest}"
    fi
  fi

  printf '%s' "$experiment_msg"
}

GATE_PASSED="true"
if has_failure "$OUTPUT"; then
  GATE_PASSED="false"
fi

# --- Build reflection ---

REFLECTION=""
PROGRESS=""

# Coverage check
COVERAGE_PCT=$(extract_coverage)
if [[ -n "$COVERAGE_PCT" ]]; then
  if V="$COVERAGE_PCT" python3 -c "import os; exit(0 if float(os.environ['V']) < 95 else 1)" 2>/dev/null; then
    REFLECTION="THE MIRROR: Coverage is ${COVERAGE_PCT}%. Your standard is 95%. The gap is real."
    PROGRESS=$(record_and_check_progress "coverage" "$COVERAGE_PCT" "95")
    GATE_PASSED="false"
  else
    record_and_check_progress "coverage" "$COVERAGE_PCT" "95" >/dev/null 2>&1 || true
  fi
fi

# Test failure count
FAIL_COUNT=$(extract_test_failures)
if [[ -n "$FAIL_COUNT" ]] && [[ "$FAIL_COUNT" -gt 0 ]]; then
  REFLECTION="${REFLECTION:+${REFLECTION} }THE MIRROR: ${FAIL_COUNT} test failure(s). Each failure is information, not an obstacle."
  FAIL_PROGRESS=$(record_and_check_progress "test-failures" "$FAIL_COUNT" "0")
  PROGRESS="${PROGRESS:+${PROGRESS} }${FAIL_PROGRESS}"
  GATE_PASSED="false"
fi

# Lint error count
LINT_COUNT=$(extract_lint_errors)
if [[ -n "$LINT_COUNT" ]] && [[ "$LINT_COUNT" -gt 0 ]]; then
  REFLECTION="${REFLECTION:+${REFLECTION} }THE MIRROR: ${LINT_COUNT} lint issue(s). Zero is the target."
  LINT_PROGRESS=$(record_and_check_progress "lint-errors" "$LINT_COUNT" "0")
  PROGRESS="${PROGRESS:+${PROGRESS} }${LINT_PROGRESS}"
  GATE_PASSED="false"
fi

# Resolve predictions regardless of pass/fail
EXPERIMENT=$(resolve_predictions "$GATE_PASSED")

# If no specific failures detected but command failed
if [[ -z "$REFLECTION" ]] && [[ "$GATE_PASSED" == "false" ]]; then
  REFLECTION="THE MIRROR: The command failed. Read the output. Understand the cause. Fix it."
fi

# If nothing to report (gate passed, no experiment data)
if [[ -z "$REFLECTION" ]] && [[ -z "$PROGRESS" ]] && [[ -z "$EXPERIMENT" ]]; then
  exit 0
fi

# Combine all outputs
FULL_OUTPUT=""
if [[ -n "$REFLECTION" ]]; then
  FULL_OUTPUT="$REFLECTION"
fi
if [[ -n "$PROGRESS" ]]; then
  FULL_OUTPUT="${FULL_OUTPUT:+${FULL_OUTPUT} }${PROGRESS}"
fi
if [[ -n "$EXPERIMENT" ]]; then
  FULL_OUTPUT="${FULL_OUTPUT:+${FULL_OUTPUT} }${EXPERIMENT}"
fi

# Log to journal with ABC structure
if [[ "$GATE_PASSED" == "false" ]]; then
  bash "${SCRIPT_DIR}/journal.sh" log \
    "quality-failure" \
    "$(printf '%s' "$COMMAND" | cut -c1-80)" \
    "Reflected failure back to agent" \
    --source=mirror \
    --event="quality gate run" \
    --belief="quality check" \
    --consequence="failure reflected" >/dev/null 2>&1 || true
fi

# Output hook response
jq -n --arg ctx "$FULL_OUTPUT" '{hookSpecificOutput: {additionalContext: $ctx}}'
