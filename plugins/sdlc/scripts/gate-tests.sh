#!/usr/bin/env bash
# Gate: Tests — every source file must have a test file, all tests must pass
# Produces: .quality/proof/tests.json
# Output format: always uses "test_failures" as structured JSON array
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"
# shellcheck source=plugins/sdlc/scripts/detect-test-runner.sh
source "$SCRIPT_DIR/detect-test-runner.sh"
# shellcheck source=plugins/sdlc/scripts/select-affected-tests.sh
source "$SCRIPT_DIR/select-affected-tests.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-tests.jsonl"

# ─── Fingerprint: skip tests if nothing changed ──────────────────
FINGERPRINT=$(compute_fingerprint)

if check_fingerprint_cache "$FINGERPRINT"; then
  echo "✓ Fingerprint match — skipping tests (cached)"
  cat "$PROOF_DIR/tests.json"
  exit 0
fi

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/tests.json" <<CRASHJSON
{
  "gate": "tests",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "fingerprint": "",
  "test_runner": "unknown",
  "tests_ran": false,
  "vacuous_reason": "",
  "test_failures": [],
  "missing_tests": [],
  "failed_subprojects": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/tests.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

CHANGED_SRC=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' 2>/dev/null || git diff --name-only --cached -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' 2>/dev/null || true)

# Filter out test files and config files from source list
SRC_FILES=""
if [ -n "$CHANGED_SRC" ]; then
  SRC_FILES=$(echo "$CHANGED_SRC" | grep -vE '(\.test\.|\.spec\.|_test\.|test_|\.config\.|\.d\.ts$|__tests__|__mocks__|/tests/|/test/)' || true)
fi

MISSING_TESTS=()
PAIRED=()

# Build test file search patterns for a given source file
build_test_patterns() {
  local dir="$1" name="$2" ext="$3"
  echo "$dir/${name}.test.${ext}"
  echo "$dir/${name}.spec.${ext}"
  echo "$dir/${name}_test.${ext}"
  echo "$dir/__tests__/${name}.test.${ext}"
  echo "$dir/__tests__/${name}.spec.${ext}"
  echo "${dir/src/test}/${name}.test.${ext}"
  echo "${dir/src/tests}/${name}.test.${ext}"
  echo "${dir/lib/test}/${name}_test.${ext}"
  case "$ext" in
    py)
      echo "$dir/test_${name}.py"
      echo "tests/test_${name}.py"
      echo "tests/${dir}/test_${name}.py"
      ;;
    go) echo "$dir/${name}_test.go" ;;
    rb)
      echo "spec/${dir}/${name}_spec.rb"
      echo "spec/${name}_spec.rb"
      echo "$dir/${name}_spec.rb"
      echo "test/${dir}/${name}_test.rb"
      echo "test/${name}_test.rb"
      echo "test/test_${name}.rb"
      ;;
    java)
      echo "${dir/main/test}/${name}Test.java"
      echo "${dir/main/test}/${name}Tests.java"
      echo "$dir/${name}Test.java"
      ;;
    kt)
      echo "${dir/main/test}/${name}Test.kt"
      echo "${dir/main/test}/${name}Tests.kt"
      echo "$dir/${name}Test.kt"
      ;;
  esac
}

find_test_file() {
  local src="$1"
  local dir name ext
  dir=$(dirname "$src")
  name="${src##*/}"
  name="${name%.*}"
  ext="${src##*.}"
  local pattern
  while IFS= read -r pattern; do
    [ -f "$pattern" ] && {
      echo "$pattern"
      return 0
    }
  done < <(build_test_patterns "$dir" "$name" "$ext")
  local found
  found=$(find . -path "./.git" -prune -o -name "*${name}*test*" -print -o -name "*test*${name}*" -print 2>/dev/null | head -1)
  [ -n "$found" ] && {
    echo "$found"
    return 0
  }
  return 1
}

if [ -n "$SRC_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    if find_test_file "$file" >/dev/null; then
      PAIRED+=("$file")
    elif is_allowed "tests" "file=$file"; then
      true
    else
      MISSING_TESTS+=("$file")
    fi
  done <<<"$SRC_FILES"
fi

# ─── Select and run affected tests ───────────────────────────────
detect_test_runner "."
TEST_RUNNER="$DETECTED_RUNNER"
TEST_CMD="$DETECTED_CMD"

# Detect testmon — if available, it handles test selection internally
detect_testmon

SELECTED_TESTS=""
if [ "$TESTMON_AVAILABLE" != "true" ] && [ -n "$SRC_FILES" ]; then
  SELECTED_TESTS=$(select_affected_tests "$SRC_FILES" "$CHANGED_SRC" "$TEST_RUNNER")
fi

run_selected_tests "$TEST_RUNNER" "$SELECTED_TESTS"

# Vacuous-pass detection: catches the fall-through path in run_selected_tests
TESTS_VACUOUS_REASON=""
if [ -n "$SRC_FILES" ] && [ "$TESTS_RAN" = "false" ]; then
  if [ "$TEST_RUNNER" = "none" ] || [ -z "$TEST_RUNNER" ]; then
    TESTS_VACUOUS_REASON="no test runner detected — set up bin/test or install pytest/vitest/jest/rspec for your stack"
  else
    TESTS_VACUOUS_REASON="test runner '$TEST_RUNNER' detected but no tests executed — check test file selection"
  fi
fi

# Prune stale coverage entries after test execution
prune_coverage_data

# ─── Monorepo: run tests in subdirectories ────────────────────────
FAILED_SUBS=()
SUBPROJECTS_RAN=false
if [ "$TEST_RUNNER" != "bin-test" ]; then
  # shellcheck source=plugins/sdlc/scripts/find-project-roots.sh
  source "$SCRIPT_DIR/find-project-roots.sh"
  discover_subproject_roots "$SDLC_DEFAULT_BRANCH"

  # Guard empty-array expansion under set -u
  for local_root in "${DISCOVERED_ROOTS[@]:-}"; do
    [ -n "$local_root" ] || continue
    # Per-subproject fingerprint — cache independently
    local_rel=$(GT_ROOT="$local_root" python3 -c "import os; print(os.path.relpath(os.environ['GT_ROOT']))" 2>/dev/null || basename "$local_root")
    sub_fp=$(compute_subproject_fingerprint "$local_rel")
    sub_proof="$PROOF_DIR/tests-${local_rel//\//-}.json"
    if check_fingerprint_cache "$sub_fp" "$sub_proof"; then
      echo "✓ $local_rel: tests cached (fingerprint match)"
      SUBPROJECTS_RAN=true
      continue
    fi

    detect_test_runner "$local_root"
    [ -z "$DETECTED_CMD" ] && continue
    sub_exit=0
    # Safety invariant: DETECTED_CMD is `cd $(printf %q "$dir") && <cmd>`.
    # `printf %q` quotes all shell metacharacters including newlines, so the
    # eval is safe against path injection. Converting to an array would
    # require splitting the `cd && cmd` compound, which is a larger refactor.
    sub_output=$(eval "$DETECTED_CMD") || sub_exit=$?
    SUBPROJECTS_RAN=true
    if [ $sub_exit -ne 0 ]; then
      sub_name=$(basename "$local_root")
      junit_path=""
      [ "$DETECTED_RUNNER" = "pytest" ] && junit_path="$local_root/.quality/proof/junit.xml"
      sub_failures=$(parse_failures "$DETECTED_RUNNER" "$sub_output" "$SCRIPT_DIR" "$junit_path")
      FAILED_SUBS+=("{\"subproject\":\"$sub_name\",\"runner\":\"$DETECTED_RUNNER\",\"failures\":$sub_failures}")
      TEST_EXIT=$sub_exit
    fi
  done
fi

# If monorepo subproject tests actually ran, the top-level "no tests executed"
# vacuous reason is a false positive — tests DID run, just not at the root.
# Clear regardless of pass/fail: TEST_EXIT below already reports subproject
# failures, so keeping the vacuous reason would produce dual misleading errors.
if [ "$SUBPROJECTS_RAN" = "true" ]; then
  TESTS_VACUOUS_REASON=""
fi

# Clear crash trap — we made it past analysis, write proof normally
trap - ERR

# ─── Build proof ──────────────────────────────────────────────────
GATE_STATUS="pass"
[ ${#MISSING_TESTS[@]} -gt 0 ] && GATE_STATUS="fail"
[ $TEST_EXIT -ne 0 ] && GATE_STATUS="fail"
[ -n "$TESTS_VACUOUS_REASON" ] && GATE_STATUS="fail"

MISSING_JSON=""
[ ${#MISSING_TESTS[@]} -gt 0 ] && MISSING_JSON=$(printf '"%s",' "${MISSING_TESTS[@]}" | sed 's/,$//')

# Always output test_failures as structured array
FAILURES_JSON="[]"
if [ $TEST_EXIT -ne 0 ] && [ -n "$TEST_OUTPUT" ]; then
  junit_path=""
  [ "$TEST_RUNNER" = "pytest" ] && junit_path=".quality/proof/junit.xml"
  FAILURES_JSON=$(parse_failures "$TEST_RUNNER" "$TEST_OUTPUT" "$SCRIPT_DIR" "$junit_path")
fi

FAILED_SUBS_JSON=""
[ ${#FAILED_SUBS[@]} -gt 0 ] && FAILED_SUBS_JSON=$(printf '%s,' "${FAILED_SUBS[@]}" | sed 's/,$//')

# TESTS_RAN is always literal "true" or "false" (set in select-affected-tests.sh
# and reset in run_selected_tests). Normalize once and inline directly into JSON.
[ "$TESTS_RAN" = "true" ] || TESTS_RAN="false"
VACUOUS_REASON_JSON=$(printf '%s' "$TESTS_VACUOUS_REASON" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().rstrip('\n')))")

cat >"$PROOF_DIR/tests.json" <<ENDJSON
{
  "gate": "tests",
  "sha": "$(git rev-parse HEAD)",
  "fingerprint": "$FINGERPRINT",
  "status": "$GATE_STATUS",
  "error": null,
  "test_runner": "$TEST_RUNNER",
  "tests_ran": $TESTS_RAN,
  "vacuous_reason": $VACUOUS_REASON_JSON,
  "test_failures": $FAILURES_JSON,
  "missing_tests": [${MISSING_JSON}],
  "failed_subprojects": [${FAILED_SUBS_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/tests.json"

report_unused_allow_entries tests

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint tests
  [ ${#MISSING_TESTS[@]} -gt 0 ] && echo "GATE FAILED: ${#MISSING_TESTS[@]} source file(s) have no test file" >&2
  [ $TEST_EXIT -ne 0 ] && echo "GATE FAILED: Tests exited with code $TEST_EXIT" >&2
  [ -n "$TESTS_VACUOUS_REASON" ] && echo "GATE FAILED: $TESTS_VACUOUS_REASON" >&2
  exit 1
fi
