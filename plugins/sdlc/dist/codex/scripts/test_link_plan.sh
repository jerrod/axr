#!/usr/bin/env bash
# Tests for link-plan.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_PLAN="$SCRIPT_DIR/link-plan.sh"
PASS=0
FAIL=0
TEST_REPO_DIR=""
TEST_HOME=""

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

assert_true() {
  local test_name="$1"
  shift
  if bash -c "$*"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name"
  fi
}

setup_repo() {
  TEST_REPO_DIR=$(mktemp -d)
  TEST_HOME=$(mktemp -d)
  cd "$TEST_REPO_DIR" || exit 1
  git init -q
  git config commit.gpgsign false
  git config user.email "test@test.com"
  git config user.name "Test"
  git remote add origin "https://github.com/test-owner/test-repo.git"
  git commit --allow-empty -q -m "init"
  git checkout -q -b feat/my-feature
  export HOME="$TEST_HOME"
}

teardown_repo() {
  cd / || exit 1
  rm -rf "$TEST_REPO_DIR" "$TEST_HOME"
  TEST_REPO_DIR=""
  TEST_HOME=""
}

# ─── Tests ──────────────────────────────────────────────────────

test_no_plan_is_silent_success() {
  setup_repo
  local exit_code=0
  bash "$LINK_PLAN" >/dev/null 2>&1 || exit_code=$?
  assert_eq "exits 0 when no canonical plan exists" "0" "$exit_code"
  assert_true "no symlink created" "[ ! -e .quality/plans/feat-my-feature.md ]"
  teardown_repo
}

test_creates_symlink_from_branch() {
  setup_repo
  mkdir -p "$TEST_HOME/.claude/plans/test-repo"
  echo "# Plan" >"$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  bash "$LINK_PLAN" >/dev/null 2>&1
  assert_true "symlink created" "[ -L .quality/plans/feat-my-feature.md ]"
  assert_eq "symlink target" \
    "$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md" \
    "$(readlink .quality/plans/feat-my-feature.md)"
  teardown_repo
}

test_uses_explicit_slug_arg() {
  setup_repo
  mkdir -p "$TEST_HOME/.claude/plans/test-repo"
  echo "# Plan" >"$TEST_HOME/.claude/plans/test-repo/other-slug.md"
  bash "$LINK_PLAN" "other-slug" >/dev/null 2>&1
  assert_true "symlink created from arg" "[ -L .quality/plans/other-slug.md ]"
  teardown_repo
}

test_idempotent_when_link_correct() {
  setup_repo
  mkdir -p "$TEST_HOME/.claude/plans/test-repo"
  echo "# Plan" >"$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  bash "$LINK_PLAN" >/dev/null 2>&1
  local first_target
  first_target=$(readlink .quality/plans/feat-my-feature.md)
  bash "$LINK_PLAN" >/dev/null 2>&1
  local second_target
  second_target=$(readlink .quality/plans/feat-my-feature.md)
  assert_eq "symlink unchanged on re-run" "$first_target" "$second_target"
  teardown_repo
}

test_replaces_stale_symlink() {
  setup_repo
  mkdir -p "$TEST_HOME/.claude/plans/test-repo" .quality/plans
  echo "# Plan" >"$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  # Create a stale symlink pointing somewhere else
  ln -s /tmp/wrong-path .quality/plans/feat-my-feature.md
  bash "$LINK_PLAN" >/dev/null 2>&1
  assert_eq "symlink now points to canonical" \
    "$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md" \
    "$(readlink .quality/plans/feat-my-feature.md)"
  teardown_repo
}

test_backs_up_regular_file() {
  setup_repo
  mkdir -p "$TEST_HOME/.claude/plans/test-repo" .quality/plans
  echo "# Plan" >"$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  # Create a regular file at the symlink path
  echo "existing content" >.quality/plans/feat-my-feature.md
  bash "$LINK_PLAN" >/dev/null 2>&1
  assert_true "symlink created over file" "[ -L .quality/plans/feat-my-feature.md ]"
  assert_true "backup exists" "ls .quality/plans/feat-my-feature.md.bak.* >/dev/null 2>&1"
  teardown_repo
}

test_not_in_git_repo_fails() {
  local tmp
  tmp=$(mktemp -d)
  cd "$tmp" || exit 1
  local exit_code=0
  bash "$LINK_PLAN" >/dev/null 2>&1 || exit_code=$?
  assert_eq "exits 1 outside git repo" "1" "$exit_code"
  cd / || exit 1
  rm -rf "$tmp"
}

# ─── Run ────────────────────────────────────────────────────────

echo "Running link-plan tests..."
test_no_plan_is_silent_success
test_creates_symlink_from_branch
test_uses_explicit_slug_arg
test_idempotent_when_link_correct
test_replaces_stale_symlink
test_backs_up_regular_file
test_not_in_git_repo_fails

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
