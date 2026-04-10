#!/usr/bin/env bash
# Tests for _gate_patterns / _files_changed_for_gate in run-gates.sh
# Verifies that shell scripts invalidate lint/dead-code/tests caches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_GATES="$SCRIPT_DIR/run-gates.sh"
PASS=0
FAIL=0
TEST_REPO_DIR=""

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local test_name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected to contain '$needle')"
  fi
}

# Source just the helper functions from run-gates.sh without running main.
# We extract lines from the "Cache helpers" section up to the cache-check loop.
source_cache_helpers() {
  # Extract only the pattern functions (_gate_patterns, _files_changed_for_gate)
  # from run-gates.sh via process substitution — avoids shared /tmp state and
  # parallel-run races. Anchored to the exact `_gate_patterns()` function
  # declaration and stops just before `_gate_cached()` to avoid capturing a
  # half-function.
  # shellcheck source=/dev/null
  source <(awk '
    /^_gate_patterns\(\) \{/ { in_block=1 }
    /^_gate_cached\(\) \{/   { in_block=0 }
    in_block { print }
  ' "$RUN_GATES")
}

setup_repo() {
  TEST_REPO_DIR=$(mktemp -d)
  cd "$TEST_REPO_DIR" || exit 1
  git init -q
  git config commit.gpgsign false
  git config user.email "test@test.com"
  git config user.name "Test"
  # Seed a file and commit
  echo "initial" >seed.txt
  git add seed.txt
  git commit -q -m "init"
  export CURRENT_SHA
  CURRENT_SHA=$(git rev-parse HEAD)
}

teardown_repo() {
  cd / || exit 1
  rm -rf "$TEST_REPO_DIR"
  TEST_REPO_DIR=""
}

# ─── Tests for _gate_patterns ──────────────────────────────────

test_gate_patterns_includes_sh_for_lint() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns lint)"
  assert_contains "lint patterns include *.sh" "$patterns" '*.sh'
}

test_gate_patterns_includes_sh_for_dead_code() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns dead-code)"
  assert_contains "dead-code patterns include *.sh" "$patterns" '*.sh'
}

test_gate_patterns_includes_sh_for_tests() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns tests)"
  assert_contains "tests patterns include *.sh" "$patterns" '*.sh'
}

test_gate_patterns_includes_test_sh_for_test_quality() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns test-quality)"
  assert_contains "test-quality patterns include test_*.sh" "$patterns" 'test_*.sh'
}

test_gate_patterns_filesize_is_wildcard() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns filesize)"
  assert_eq "filesize patterns are '*'" "*" "$patterns"
}

test_gate_patterns_unknown_gate_is_wildcard() {
  source_cache_helpers
  local patterns
  patterns="$(_gate_patterns some-unknown-gate)"
  assert_eq "unknown gate falls back to '*'" "*" "$patterns"
}

# ─── Tests for _files_changed_for_gate ─────────────────────────

test_sh_change_invalidates_lint_cache() {
  setup_repo
  source_cache_helpers
  local old_sha="$CURRENT_SHA"
  echo '#!/bin/bash' >script.sh
  git add script.sh
  git commit -q -m "add sh"
  CURRENT_SHA=$(git rev-parse HEAD)
  if _files_changed_for_gate lint "$old_sha"; then
    PASS=$((PASS + 1))
    echo "  PASS: *.sh change invalidates lint cache"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: *.sh change should invalidate lint cache but didn't"
  fi
  teardown_repo
}

test_sh_change_invalidates_dead_code_cache() {
  setup_repo
  source_cache_helpers
  local old_sha="$CURRENT_SHA"
  echo '#!/bin/bash' >script.sh
  git add script.sh
  git commit -q -m "add sh"
  CURRENT_SHA=$(git rev-parse HEAD)
  if _files_changed_for_gate dead-code "$old_sha"; then
    PASS=$((PASS + 1))
    echo "  PASS: *.sh change invalidates dead-code cache"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: *.sh change should invalidate dead-code cache but didn't"
  fi
  teardown_repo
}

test_md_change_does_not_invalidate_lint_cache() {
  setup_repo
  source_cache_helpers
  local old_sha="$CURRENT_SHA"
  echo '# Doc' >doc.md
  git add doc.md
  git commit -q -m "add md"
  CURRENT_SHA=$(git rev-parse HEAD)
  if _files_changed_for_gate lint "$old_sha"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: *.md change should NOT invalidate lint cache"
  else
    PASS=$((PASS + 1))
    echo "  PASS: *.md change does not invalidate lint cache"
  fi
  teardown_repo
}

test_py_change_invalidates_lint_cache() {
  setup_repo
  source_cache_helpers
  local old_sha="$CURRENT_SHA"
  echo 'x = 1' >script.py
  git add script.py
  git commit -q -m "add py"
  CURRENT_SHA=$(git rev-parse HEAD)
  if _files_changed_for_gate lint "$old_sha"; then
    PASS=$((PASS + 1))
    echo "  PASS: *.py change invalidates lint cache"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: *.py change should invalidate lint cache"
  fi
  teardown_repo
}

test_same_sha_means_cache_valid() {
  setup_repo
  source_cache_helpers
  # No changes since seed commit — CURRENT_SHA equals old_sha
  if _files_changed_for_gate lint "$CURRENT_SHA"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: same SHA should mean cache is still valid"
  else
    PASS=$((PASS + 1))
    echo "  PASS: same SHA keeps cache valid"
  fi
  teardown_repo
}

# ─── Run ────────────────────────────────────────────────────────

echo "Running gate cache pattern tests..."
echo ""
echo "Pattern tests:"
test_gate_patterns_includes_sh_for_lint
test_gate_patterns_includes_sh_for_dead_code
test_gate_patterns_includes_sh_for_tests
test_gate_patterns_includes_test_sh_for_test_quality
test_gate_patterns_filesize_is_wildcard
test_gate_patterns_unknown_gate_is_wildcard
echo ""
echo "Cache-invalidation tests:"
test_sh_change_invalidates_lint_cache
test_sh_change_invalidates_dead_code_cache
test_md_change_does_not_invalidate_lint_cache
test_py_change_invalidates_lint_cache
test_same_sha_means_cache_valid

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
