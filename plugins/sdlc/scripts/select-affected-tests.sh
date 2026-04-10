#!/usr/bin/env bash
# Shared: Select tests affected by branch changes
# Usage: source this file, then call select_and_run_tests
# Requires: SCRIPT_DIR, SRC_FILES, CHANGED_SRC, SDLC_DEFAULT_BRANCH, PROOF_DIR
# Sets: TEST_OUTPUT, TEST_EXIT, TESTMON_AVAILABLE
set -uo pipefail

# Module-level vars set by run_selected_tests(), consumed by caller (gate-tests.sh)
export TEST_OUTPUT=""
export TEST_EXIT=0
export TESTS_RAN=""
export TESTMON_AVAILABLE=""

# Detect if pytest-testmon is installed
detect_testmon() {
  if python3 -c "import testmon" 2>/dev/null; then
    TESTMON_AVAILABLE="true"
  else
    TESTMON_AVAILABLE=""
  fi
}

# Compute fingerprint from git index (source/test files only)
compute_fingerprint() {
  local fp
  fp=$(git ls-files -s -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.go' '*.rs' '*.rb' '*.java' '*.kt' 2>/dev/null |
    md5sum 2>/dev/null || git ls-files -s -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.go' '*.rs' '*.rb' '*.java' '*.kt' 2>/dev/null | md5)
  echo "${fp%% *}"
}

# Compute fingerprint scoped to a subdirectory
compute_subproject_fingerprint() {
  local dir="$1"
  local fp
  fp=$(git ls-files -s -- "$dir"/'*.py' "$dir"/'*.ts' "$dir"/'*.tsx' "$dir"/'*.js' "$dir"/'*.jsx' "$dir"/'*.go' "$dir"/'*.rs' "$dir"/'*.rb' "$dir"/'*.java' "$dir"/'*.kt' 2>/dev/null |
    md5sum 2>/dev/null || git ls-files -s -- "$dir"/'*.py' "$dir"/'*.ts' "$dir"/'*.tsx' "$dir"/'*.js' "$dir"/'*.jsx' "$dir"/'*.go' "$dir"/'*.rs' "$dir"/'*.rb' "$dir"/'*.java' "$dir"/'*.kt' 2>/dev/null | md5)
  echo "${fp%% *}"
}

# Check if cached proof is still valid
# Valid when: proof exists, status is pass, and no source/test files changed since proof SHA
check_fingerprint_cache() {
  local fingerprint="$1"
  local proof_file="${2:-$PROOF_DIR/tests.json}"
  [ -f "$proof_file" ] || return 1
  local cached_fp cached_status cached_sha
  read -r cached_fp cached_status cached_sha < <(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('fingerprint',''), d.get('status',''), d.get('sha',''))
except Exception:
    print('  ')
" "$proof_file" 2>/dev/null || echo "  ")
  [ "$cached_status" = "pass" ] || return 1

  # Fast path: fingerprint matches exactly (no files changed at all)
  [ "$fingerprint" = "$cached_fp" ] && return 0

  # Slow path: fingerprint differs, but maybe only non-source files changed
  # Check if any source/test files changed between proof SHA and HEAD
  [ -n "$cached_sha" ] || return 1
  git cat-file -t "$cached_sha" >/dev/null 2>&1 || return 1
  local changed_source
  changed_source=$(git diff --name-only "$cached_sha"..HEAD -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.go' '*.rs' '*.rb' '*.java' '*.kt' 2>/dev/null || true)
  [ -z "$changed_source" ]
}

# Select affected test files (Mode A: gate-driven)
select_affected_tests() {
  local src_files="$1"
  local changed_src="$2"
  local test_runner="$3"

  local paired_tests="" changed_tests="" affected_tests=""

  # Find paired test files for changed source files
  while IFS= read -r src_file; do
    [ -n "$src_file" ] || continue
    local local_test
    local_test=$(find_test_file "$src_file" 2>/dev/null || true)
    [ -n "$local_test" ] && paired_tests+="$local_test"$'\n'
  done <<<"$src_files"

  # Find directly changed test files
  if [ -n "$changed_src" ]; then
    changed_tests=$(echo "$changed_src" | grep -E '(\.test\.|\.spec\.|_test\.|test_)' || true)
  fi

  # Find affected tests via import graph (Python only). Read src files
  # into an array so paths with spaces/metacharacters are preserved
  # instead of word-split.
  if [ "$test_runner" = "pytest" ] || [ "$test_runner" = "bin-test" ]; then
    if [ -f "$SCRIPT_DIR/find_affected_tests.py" ]; then
      local _src_array=()
      if [ -n "$src_files" ]; then
        while IFS= read -r _f; do
          [ -n "$_f" ] && _src_array+=("$_f")
        done <<<"$src_files"
      fi
      if [ ${#_src_array[@]} -gt 0 ]; then
        affected_tests=$(python3 "$SCRIPT_DIR/find_affected_tests.py" "${_src_array[@]}" 2>/dev/null || true)
      fi
    fi
  fi

  # Deduplicate and output
  printf '%s\n' "$paired_tests" "$changed_tests" "$affected_tests" | sort -u | grep -v '^$' || true
}

# Run tests with appropriate mode
# Output is written to a temp file to avoid shell variable size limits
# (bin/test can produce hundreds of KB of output which exceeds ARG_MAX)
run_selected_tests() {
  local test_runner="$1"
  local selected_tests="$2"

  TEST_OUTPUT_FILE=$(mktemp)
  # Ensure the tempfile is removed even if a later command crashes mid-run
  # (ERR / SIGINT / SIGTERM). The inner functions also remove it on success;
  # this trap is the safety net for the abnormal-exit paths.
  trap '[ -n "${TEST_OUTPUT_FILE:-}" ] && rm -f "$TEST_OUTPUT_FILE"' EXIT INT TERM
  TEST_OUTPUT=""
  TEST_EXIT=0
  TESTS_RAN=false

  _run_test_cmd() {
    TESTS_RAN=true
    "$@" >"$TEST_OUTPUT_FILE" 2>&1 || TEST_EXIT=$?
    # Only keep last 200 lines to avoid shell ARG_MAX on large suites
    TEST_OUTPUT=$(tail -200 "$TEST_OUTPUT_FILE")
  }

  _run_test_cmd_eval() {
    TESTS_RAN=true
    eval "$1" >"$TEST_OUTPUT_FILE" 2>&1 || TEST_EXIT=$?
    TEST_OUTPUT=$(tail -200 "$TEST_OUTPUT_FILE")
  }

  if [ "$test_runner" = "vitest" ]; then
    if [ -x "bin/test" ]; then
      export SDLC_CHANGED_SINCE="$SDLC_DEFAULT_BRANCH"
      _run_test_cmd bin/test
    else
      _run_test_cmd npx vitest run --changedSince="$SDLC_DEFAULT_BRANCH" --coverage --reporter=json
    fi
  elif [ "$test_runner" = "jest" ]; then
    if [ -x "bin/test" ]; then
      export SDLC_CHANGED_SINCE="$SDLC_DEFAULT_BRANCH"
      _run_test_cmd bin/test
    else
      _run_test_cmd npx jest --changedSince="$SDLC_DEFAULT_BRANCH" --coverage --json --forceExit
    fi
  elif [ "$TESTMON_AVAILABLE" = "true" ] && { [ "$test_runner" = "pytest" ] || [ "$test_runner" = "bin-test" ]; }; then
    if [ -x "bin/test" ]; then
      export SDLC_TESTMON=1
      _run_test_cmd bin/test
    else
      _run_test_cmd python3 -m pytest --testmon --tb=short -q \
        --cov --cov-append --cov-report=json \
        --junitxml=.quality/proof/junit.xml
    fi
  elif [ -n "$selected_tests" ]; then
    # Read selected tests into an array so filenames with spaces or leading
    # dashes can't be re-parsed as options or split into separate arguments.
    # Prefix each path with `--` boundary to prevent any leading `-` in a
    # filename from being interpreted as a flag by pytest/bin/test.
    local _sel_array=()
    while IFS= read -r _t; do
      [ -n "$_t" ] && _sel_array+=("$_t")
    done <<<"$selected_tests"
    if [ -x "bin/test" ]; then
      _run_test_cmd bin/test -- "${_sel_array[@]}"
    elif [ "$test_runner" = "pytest" ]; then
      _run_test_cmd python3 -m pytest --tb=short -q \
        --cov --cov-append --cov-report=json \
        --junitxml=.quality/proof/junit.xml \
        -- "${_sel_array[@]}"
    fi
  elif [ -n "${TEST_CMD:-}" ]; then
    _run_test_cmd_eval "$TEST_CMD"
  fi

  rm -f "$TEST_OUTPUT_FILE"
  # Release the EXIT/INT/TERM trap so a caller setting its own EXIT handler
  # after us is not silently replaced by our tempfile cleanup.
  trap - EXIT INT TERM
}

# Prune stale entries from coverage data files
# Keys in coverage.json may be relative to the pytest cwd (e.g. scripts dir)
# rather than repo root, so also check a set of candidate prefixes before
# declaring a key stale.
prune_coverage_data() {
  for cov_file in coverage.json coverage/coverage-summary.json; do
    [ -f "$cov_file" ] || continue
    python3 -c "
import json, os, sys
cov_path = sys.argv[1]
# Candidate prefixes to try if a bare key doesn't resolve at cwd
prefixes = ['', 'plugins/sdlc/scripts/']
def resolves(key):
    return any(os.path.isfile(os.path.join(p, key)) for p in prefixes)
with open(cov_path) as f:
    data = json.load(f)
if 'files' in data:
    data['files'] = {k: v for k, v in data['files'].items() if resolves(k)}
    with open(cov_path, 'w') as f:
        json.dump(data, f, indent=2)
elif 'total' in data:
    pruned = {k: v for k, v in data.items() if k == 'total' or resolves(k)}
    with open(cov_path, 'w') as f:
        json.dump(pruned, f, indent=2)
" "$cov_file" 2>/dev/null || true
  done
}
