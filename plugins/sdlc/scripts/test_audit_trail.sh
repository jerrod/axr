#!/usr/bin/env bash
# Tests for audit-trail.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-trail.sh"
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

assert_file_exists() {
  local test_name="$1" filepath="$2"
  if [ -f "$filepath" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (file not found: $filepath)"
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

# Safe JSON field reader — avoids shell injection in python -c
json_field() {
  local file="$1" expr="$2"
  JF_FILE="$file" JF_EXPR="$expr" python3 -c "
import json, os
d = json.load(open(os.environ['JF_FILE']))
print(eval(os.environ['JF_EXPR'], {'d': d, 'len': len}))
" 2>/dev/null
}

setup() {
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  git init -q
  git config commit.gpgsign false
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -q -m "init"
  export AUDIT_DIR="$TMPDIR/.quality/audit"
}

teardown() {
  cd "$SCRIPT_DIR"
  rm -rf "$TMPDIR"
}

# ─── Tests ──────────────────────────────────────────────────────

echo "=== audit-trail.sh tests ==="
echo ""

# --- init ---
echo "Init command:"

setup
bash "$AUDIT_SCRIPT" init "test task" >/dev/null 2>&1
assert_file_exists "init creates trail.json" "$AUDIT_DIR/trail.json"
teardown

setup
bash "$AUDIT_SCRIPT" init "test task" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" init "test task 2" >/dev/null 2>&1
local_version=$(json_field "$AUDIT_DIR/trail.json" "d['version']")
assert_eq "init is idempotent (trail not overwritten)" "1" "$local_version"
local_entries=$(json_field "$AUDIT_DIR/trail.json" "len(d['entries'])")
assert_eq "init idempotent (entries still empty)" "0" "$local_entries"
teardown

setup
bash "$AUDIT_SCRIPT" init "my cool task" >/dev/null 2>&1
task_content=$(cat "$AUDIT_DIR/task.txt")
assert_eq "init records task" "my cool task" "$task_content"
teardown

echo ""

# --- plan ---
echo "Plan command:"

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
cat >"$TMPDIR/plan.json" <<'PLAN'
{
  "task": "test",
  "planned_phases": [
    {"order": 1, "phase": "build", "agent": "sdlc:builder", "skills": ["sdlc:build"], "reason": "code needed"}
  ]
}
PLAN
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan.json" >/dev/null 2>&1
assert_file_exists "plan registers execution-plan.json" "$AUDIT_DIR/execution-plan.json"
plan_phase=$(json_field "$AUDIT_DIR/execution-plan.json" "d['planned_phases'][0]['phase']")
assert_eq "plan has correct content" "build" "$plan_phase"
teardown

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
echo "not json" >"$TMPDIR/bad.json"
output=$(bash "$AUDIT_SCRIPT" plan "$TMPDIR/bad.json" 2>&1)
assert_contains "plan rejects invalid JSON" "$output" "Invalid plan JSON"
teardown

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
cat >"$TMPDIR/plan1.json" <<'PLAN'
{"task": "first", "planned_phases": [{"order": 1, "phase": "build", "agent": "a"}]}
PLAN
cat >"$TMPDIR/plan2.json" <<'PLAN'
{"task": "second", "planned_phases": [{"order": 1, "phase": "review", "agent": "b"}]}
PLAN
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan1.json" >/dev/null 2>&1
output=$(bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan2.json" 2>&1)
assert_contains "plan noop when exists" "$output" "already registered"
plan_task=$(json_field "$AUDIT_DIR/execution-plan.json" "d['task']")
assert_eq "plan keeps first registration" "first" "$plan_task"
teardown

echo ""

# --- log ---
echo "Log command:"

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started >/dev/null 2>&1
entry_action=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['action']")
assert_eq "log started" "started" "$entry_action"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --duration=120 --tools=30 --context="built feature" >/dev/null 2>&1
dur=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['duration_seconds']")
tools=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['tool_calls']")
ctx=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")
assert_eq "log completed with duration" "120" "$dur"
assert_eq "log completed with tools" "30" "$tools"
assert_eq "log completed with context" "built feature" "$ctx"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder failed --context="stuck on gate" >/dev/null 2>&1
entry_action=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['action']")
assert_eq "log failed" "failed" "$entry_action"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed >/dev/null 2>&1
id1=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['id']")
id2=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][1]['id']")
if [ "$id1" != "$id2" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: log generates unique IDs"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: log generates unique IDs (both '$id1')"
fi
teardown

echo ""

# --- special characters in context ---
echo "Special characters:"

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context="it's a 'quoted' value" >/dev/null 2>&1
ctx=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")
assert_eq "context with single quotes" "it's a 'quoted' value" "$ctx"
teardown

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context='has "double quotes" inside' >/dev/null 2>&1
ctx=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")
assert_eq "context with double quotes" 'has "double quotes" inside' "$ctx"
teardown

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context='has $dollar and `backtick`' >/dev/null 2>&1
ctx=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")
expected="has \$dollar and \`backtick\`"
assert_eq "context with dollar and backtick" "$expected" "$ctx"
teardown

setup
bash "$AUDIT_SCRIPT" init "task with 'quotes' and \$vars" >/dev/null 2>&1
output=$(bash "$AUDIT_SCRIPT" show 2>&1)
assert_contains "show handles special chars in task" "$output" "quotes"
teardown

echo ""

# --- report ---
echo "Report command:"

setup
bash "$AUDIT_SCRIPT" init "report test" >/dev/null 2>&1
cat >"$TMPDIR/plan.json" <<'PLAN'
{
  "task": "build feature",
  "planned_phases": [
    {"order": 1, "phase": "build", "agent": "sdlc:builder", "skills": ["sdlc:build"], "reason": "code needed"},
    {"order": 2, "phase": "review", "agent": "sdlc:reviewer", "skills": ["sdlc:review"], "reason": "needs review"}
  ]
}
PLAN
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan.json" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started --context="starting build" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --duration=60 --tools=20 --context="build done" >/dev/null 2>&1
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report has execution summary" "$report" "Execution Summary"
assert_contains "report has execution plan table" "$report" "Execution Plan"
assert_contains "report has audit trail" "$report" "Audit Trail"
assert_contains "report shows completed" "$report" "completed"
assert_contains "report shows skipped" "$report" "skipped"
teardown

setup
bash "$AUDIT_SCRIPT" init "orphan test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started --context="starting" >/dev/null 2>&1
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report detects orphaned started" "$report" "status unknown"
teardown

setup
bash "$AUDIT_SCRIPT" init "no plan test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context="done" >/dev/null 2>&1
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report works without plan" "$report" "Execution Summary"
teardown

setup
bash "$AUDIT_SCRIPT" init "failed phase test" >/dev/null 2>&1
cat >"$TMPDIR/plan.json" <<'PLAN'
{
  "task": "test failed",
  "planned_phases": [
    {"order": 1, "phase": "build", "agent": "sdlc:builder", "skills": ["sdlc:build"], "reason": "code needed"}
  ]
}
PLAN
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan.json" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started --context="starting" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder failed --context="gate failure" >/dev/null 2>&1
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report shows failed status in plan table" "$report" "| failed |"
teardown

echo ""

# --- show ---
echo "Show command:"

setup
bash "$AUDIT_SCRIPT" init "show test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context="done" >/dev/null 2>&1
output=$(bash "$AUDIT_SCRIPT" show 2>&1)
assert_contains "show outputs summary" "$output" "Audit Trail"
assert_contains "show includes task" "$output" "show test"
teardown

echo ""

# --- per-entry fallback (no flock) ---
echo "Per-entry fallback (no flock):"

setup
bash "$AUDIT_SCRIPT" init "flock fallback test" >/dev/null 2>&1
# Simulate no-flock by writing entry files directly
mkdir -p "$AUDIT_DIR/entries"
echo '{"id":"test-entry-1","timestamp":"2026-01-01T00:00:00Z","phase":"build","name":"sdlc:builder","action":"completed","sha":"abc123"}' >"$AUDIT_DIR/entries/test-entry-1.json"
echo '{"id":"test-entry-2","timestamp":"2026-01-01T00:01:00Z","phase":"review","name":"sdlc:reviewer","action":"started","sha":"abc123"}' >"$AUDIT_DIR/entries/test-entry-2.json"
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report merges per-entry files" "$report" "sdlc:builder"
assert_contains "report merges both entries" "$report" "sdlc:reviewer"
# Entry files should be cleaned up after merge
count=$(find "$AUDIT_DIR/entries" -name '*.json' 2>/dev/null | wc -l)
assert_eq "entry files removed after merge" "0" "$count"
teardown

setup
bash "$AUDIT_SCRIPT" init "show merge test" >/dev/null 2>&1
mkdir -p "$AUDIT_DIR/entries"
echo '{"id":"show-entry-1","timestamp":"2026-01-01T00:00:00Z","phase":"build","name":"sdlc:builder","action":"completed","sha":"def456"}' >"$AUDIT_DIR/entries/show-entry-1.json"
output=$(bash "$AUDIT_SCRIPT" show 2>&1)
assert_contains "show merges per-entry files" "$output" "sdlc:builder"
teardown

echo ""

# --- always exits 0 ---
echo "Error handling:"

setup
bash "$AUDIT_SCRIPT" init "error test" >/dev/null 2>&1
echo "broken json{{{" >"$AUDIT_DIR/trail.json"
assert_exit_zero "exits 0 on broken trail JSON" bash "$AUDIT_SCRIPT" log build sdlc:builder started
teardown

setup
assert_exit_zero "exits 0 on report with no data" bash "$AUDIT_SCRIPT" report
teardown

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Passed: $PASS  Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -gt 0 ]; then
  exit 1
fi
