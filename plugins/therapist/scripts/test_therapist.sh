#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Tests for therapist plugin CBT tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
PASS=0
FAIL=0

# ─── Helpers ────────────────────────────────────────────────────

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
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected to contain '$needle')"
  fi
}

assert_not_contains() {
  local test_name="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected NOT to contain '$needle')"
  fi
}

assert_exit_zero() {
  local test_name="$1"
  shift
  local exit_code=0
  "$@" >/dev/null 2>&1 || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (exit code $exit_code, expected 0)"
  fi
}

assert_exit_nonzero() {
  local test_name="$1"
  shift
  local exit_code=0
  "$@" >/dev/null 2>&1 || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (exit code 0, expected non-zero)"
  fi
}

# ─── Setup / Teardown ──────────────────────────────────────────

setup() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init -q
  git config commit.gpgsign false
  git config user.email "test@test.com"
  git config user.name "Test"
  touch .gitignore
  git add .gitignore
  git commit --allow-empty -q -m "init"
  mkdir -p .therapist
}

teardown() {
  cd "$SCRIPT_DIR"
  rm -rf "$TEST_DIR"
}

# Helper: build hook JSON for PreToolUse Write
hook_write_json() {
  local content="$1"
  local file_path="${2:-/tmp/test.py}"
  jq -n --arg c "$content" --arg fp "$file_path" \
    '{tool_input: {content: $c, file_path: $fp}}'
}

# Helper: build hook JSON for PreToolUse Edit
hook_edit_json() {
  local new_string="$1"
  local file_path="${2:-/tmp/test.py}"
  jq -n --arg ns "$new_string" --arg fp "$file_path" \
    '{tool_input: {new_string: $ns, file_path: $fp}}'
}

# Helper: build hook JSON for PostToolUse Bash
hook_bash_json() {
  local command="$1"
  local tool_output="$2"
  jq -n --arg cmd "$command" --arg out "$tool_output" \
    '{tool_input: {command: $cmd}, tool_output: $out}'
}

# Helper: build hook JSON for PreToolUse Bash (commit)
hook_commit_json() {
  local command="${1:-git commit -m test}"
  jq -n --arg cmd "$command" \
    '{tool_input: {command: $cmd}}'
}

# Helper: populate journal with N rationalization entries for a category
populate_journal() {
  local count="$1"
  local category="${2:-ownership-avoidance}"
  local journal_file="${TEST_DIR}/.therapist/journal.jsonl"
  local ts
  for _ in $(seq 1 "$count"); do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","type":"rationalization","trigger":"test","correction":"test","phrase":"pre-existing","source":"rubber-band","activating_event":"test","belief":"pre-existing","consequence":"skip fixing","category":"%s"}\n' \
      "$ts" "$category" >>"$journal_file"
  done
}

# ���══════════════════════════════════════════════════════════════
echo "=== therapist plugin CBT tools tests ==="
echo ""

# Source test modules
# shellcheck source=test_lib.sh
source "${SCRIPT_DIR}/test_lib.sh"
# shellcheck source=test_journal.sh
source "${SCRIPT_DIR}/test_journal.sh"
# shellcheck source=test_hooks.sh
source "${SCRIPT_DIR}/test_hooks.sh"

# ═══════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Passed: $PASS  Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -gt 0 ]; then
  exit 1
fi
