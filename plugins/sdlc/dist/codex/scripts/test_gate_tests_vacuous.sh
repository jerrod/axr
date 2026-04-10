#!/usr/bin/env bash
# Tests for gate-tests.sh vacuous-pass detection
# Verifies that gate-tests fails when src files exist but no tests are executed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate-tests.sh"

PASS=0
FAIL=0

TMPDIRS=()
TMP_REPO=""
cleanup() {
  # Guard empty-array expansion under set -u
  for d in "${TMPDIRS[@]:-}"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# Create a minimal git repo with one source file on a feature branch
make_repo_with_src() {
  local src_file="$1"
  TMP_REPO=$(mktemp -d)
  TMPDIRS+=("$TMP_REPO")
  cd "$TMP_REPO"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"

  # Initial commit on main
  git checkout -q -b main
  echo "# init" >README.md
  git add README.md
  git commit -q -m "init"

  # Feature branch with source file
  git checkout -q -b feature
  mkdir -p "$(dirname "$src_file")"
  echo "export const foo = () => 42;" >"$src_file"
  git add "$src_file"
  git commit -q -m "add src"

  cd - >/dev/null
}

# Run gate-tests.sh in the repo, capture proof JSON fields
# Prints: "status tests_ran vacuous_reason"
run_gate() {
  local repo="$1"
  local proof_dir="$repo/.quality/proof"
  mkdir -p "$proof_dir"

  cd "$repo"
  SDLC_DEFAULT_BRANCH=main PROOF_DIR="$proof_dir" bash "$GATE" >/dev/null 2>&1 || true

  python3 -c "
import json, sys
try:
    d = json.load(open('$proof_dir/tests.json'))
    status = d.get('status', 'MISSING')
    tests_ran = d.get('tests_ran', 'MISSING')
    vacuous = d.get('vacuous_reason', '')
    print(status, str(tests_ran).lower(), vacuous)
except Exception as e:
    print('ERROR', 'error', str(e))
"
  cd - >/dev/null
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test 1: TypeScript source, no package.json, no test runner ──────────────
# Expected: status=fail, tests_ran=false (no test runner detected)
make_repo_with_src "src/utils.ts"
output=$(run_gate "$TMP_REPO")
status=$(echo "$output" | awk '{print $1}')
tests_ran=$(echo "$output" | awk '{print $2}')
assert_eq "TS source, no test runner => status=fail" "fail" "$status"
assert_eq "TS source, no test runner => tests_ran=false" "false" "$tests_ran"

# TODO: add integration test for the runner-detected-but-no-tests-executed path.
# That path requires mocking the test runner detection in ways that conflict
# with real filesystem state, so the TS/no-runner case above is the only
# shell-level fixture; the other path is exercised by gate-tests.sh itself.

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
