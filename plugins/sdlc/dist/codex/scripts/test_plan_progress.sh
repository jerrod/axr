#!/usr/bin/env bash
# Tests for plan-progress.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_PROGRESS="$SCRIPT_DIR/plan-progress.sh"
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

# Write a minimal valid build-latest checkpoint that validate_checkpoint accepts:
# requires git_sha == HEAD and no failing entries in proof_snapshot.
write_passing_checkpoint() {
  mkdir -p .quality/checkpoints
  local sha branch
  sha=$(git rev-parse HEAD)
  branch=$(git branch --show-current)
  cat >.quality/checkpoints/build-latest.json <<EOF
{
  "phase": "build",
  "git_sha": "$sha",
  "git_branch": "$branch",
  "timestamp": "2026-04-09T00:00:00Z",
  "working_tree_hash": "test",
  "proof_snapshot": [],
  "description": "test"
}
EOF
}

# ─── Tests ──────────────────────────────────────────────────────

test_mark_preserves_symlink() {
  setup_repo
  # Trap ensures teardown runs even if an assertion or subprocess exits
  # non-zero under `set -euo pipefail` — prevents temp-dir leaks and
  # silent failures where the script exits before assertions can report.
  trap 'teardown_repo' RETURN
  mkdir -p "$TEST_HOME/.claude/plans/test-repo" .quality/plans
  local canonical="$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  printf '# Plan\n\n- [ ] **Step X: foo**\n' >"$canonical"
  ln -s "$canonical" .quality/plans/feat-my-feature.md
  write_passing_checkpoint

  bash "$PLAN_PROGRESS" mark .quality/plans/feat-my-feature.md "foo" >/dev/null

  assert_true "symlink is still a symlink after mark" \
    "[ -L .quality/plans/feat-my-feature.md ]"
  assert_eq "symlink still points to canonical" \
    "$canonical" \
    "$(readlink .quality/plans/feat-my-feature.md)"
  assert_true "canonical file has [x] mark" \
    "grep -qF -- '- [x] **Step X: foo**' '$canonical'"
  assert_true "canonical file no longer has [ ] for that item" \
    "! grep -qF -- '- [ ] **Step X: foo**' '$canonical'"
}

test_mark_rejects_symlink_outside_boundaries() {
  setup_repo
  trap 'teardown_repo; rm -rf "$outside_dir"' RETURN
  # Create an outside target in its OWN mktemp dir (not reachable via
  # `..` from the repo or plans root). This ensures the boundary check
  # is tested on a genuinely-outside path, not a `..`-traversal that
  # might bypass a naive case-glob comparison.
  local outside_dir outside_target
  outside_dir=$(mktemp -d)
  outside_target="$outside_dir/evil.md"
  printf '# Original\n\n- [ ] **Step X: foo**\n' >"$outside_target"
  mkdir -p .quality/plans
  ln -s "$outside_target" .quality/plans/feat-my-feature.md
  write_passing_checkpoint

  local exit_code=0
  bash "$PLAN_PROGRESS" mark .quality/plans/feat-my-feature.md "foo" \
    >/dev/null 2>&1 || exit_code=$?

  assert_eq "mark rejects symlink outside repo and plans dir" "1" "$exit_code"
  assert_true "target file content unchanged after rejection" \
    "grep -q '\- \[ \] \*\*Step X: foo\*\*' '$outside_target'"

  rm -rf "$outside_dir"
}

test_mark_rejects_chained_symlink() {
  setup_repo
  trap 'teardown_repo; rm -rf "$outside_dir"' RETURN
  # Two-hop chain: the first hop lands INSIDE the repo (passes any
  # single-hop boundary check), the second hop points OUTSIDE both roots.
  # A single-hop resolver would validate the first hop and miss the
  # out-of-bounds final target.
  local outside_dir outside_target
  outside_dir=$(mktemp -d)
  outside_target="$outside_dir/evil.md"
  printf '# Original\n\n- [ ] **Step X: foo**\n' >"$outside_target"
  mkdir -p .quality/plans
  # First hop: inside repo, points to the outside target.
  ln -s "$outside_target" "$TEST_REPO_DIR/chain-link"
  # Second hop: the plan path, points to the in-repo chain-link.
  ln -s "$TEST_REPO_DIR/chain-link" .quality/plans/feat-my-feature.md
  write_passing_checkpoint

  local exit_code=0
  bash "$PLAN_PROGRESS" mark .quality/plans/feat-my-feature.md "foo" \
    >/dev/null 2>&1 || exit_code=$?

  assert_eq "mark rejects chained symlink ending outside boundaries" "1" "$exit_code"
  assert_true "chained target file content unchanged after rejection" \
    "grep -q '\- \[ \] \*\*Step X: foo\*\*' '$outside_target'"
}

test_mark_cleans_tmpfile_on_no_match() {
  setup_repo
  trap 'teardown_repo' RETURN
  mkdir -p "$TEST_HOME/.claude/plans/test-repo" .quality/plans
  local canonical="$TEST_HOME/.claude/plans/test-repo/feat-my-feature.md"
  printf '# Plan\n\n- [ ] **Step X: foo**\n' >"$canonical"
  ln -s "$canonical" .quality/plans/feat-my-feature.md
  write_passing_checkpoint

  # Count tmpfiles matching the mktemp default prefix before and after
  # a mark call that will hit the no-match exit path.
  local tmp_dir="${TMPDIR:-/tmp}"
  local before_count
  before_count=$(find "$tmp_dir" -maxdepth 1 -name 'tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')

  bash "$PLAN_PROGRESS" mark .quality/plans/feat-my-feature.md "bar-does-not-exist" \
    >/dev/null 2>&1 || true

  local after_count
  after_count=$(find "$tmp_dir" -maxdepth 1 -name 'tmp.*' -type f 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "tmpfile count unchanged after no-match exit" "$before_count" "$after_count"
}

# ─── Run ────────────────────────────────────────────────────────

echo "Running plan-progress tests..."
test_mark_preserves_symlink
test_mark_rejects_symlink_outside_boundaries
test_mark_rejects_chained_symlink
test_mark_cleans_tmpfile_on_no_match

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
