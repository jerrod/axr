#!/usr/bin/env bash
# Tests for audit-trail.sh
set -euo pipefail

# AUDIT_SYNC_WRITES=1 forces the no-flock fallback to merge per-entry files
# into trail.json on every log call so macOS tests can read trail.json
# directly. Production MUST NOT set it — it reintroduces a write race.
export AUDIT_SYNC_WRITES=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-trail.sh"
PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (expected '$2', got '$3')"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then _pass "$1"; else _fail "$1 (both '$2')"; fi
}
assert_contains() {
  if echo "$2" | grep -q "$3"; then _pass "$1"; else _fail "$1 (expected to contain '$3')"; fi
}
assert_file_exists() {
  if [ -f "$2" ]; then _pass "$1"; else _fail "$1 (file not found: $2)"; fi
}
assert_exit_zero() {
  local name="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then _pass "$name"; else _fail "$name (exit code $rc, expected 0)"; fi
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
  TMPDIR=$(mktemp -d); cd "$TMPDIR"
  git init -q
  git config commit.gpgsign false
  git config user.email "test@test.com"; git config user.name "Test"
  git commit --allow-empty -q -m "init"
  export AUDIT_DIR="$TMPDIR/.quality/audit"
}

teardown() { cd "$SCRIPT_DIR"; rm -rf "$TMPDIR"; }

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
assert_eq "init is idempotent (trail not overwritten)" "1" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['version']")"
assert_eq "init idempotent (entries still empty)" "0" \
  "$(json_field "$AUDIT_DIR/trail.json" "len(d['entries'])")"
teardown

setup
bash "$AUDIT_SCRIPT" init "my cool task" >/dev/null 2>&1
assert_eq "init records task" "my cool task" "$(cat "$AUDIT_DIR/task.txt")"
teardown

echo ""

# --- plan ---
echo "Plan command:"

PLAN_BUILD='{"task":"test","planned_phases":[{"order":1,"phase":"build","agent":"sdlc:builder","skills":["sdlc:build"],"reason":"code needed"}]}'
PLAN_FIRST='{"task":"first","planned_phases":[{"order":1,"phase":"build","agent":"a"}]}'
PLAN_SECOND='{"task":"second","planned_phases":[{"order":1,"phase":"review","agent":"b"}]}'

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
printf '%s' "$PLAN_BUILD" >"$TMPDIR/plan.json"
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan.json" >/dev/null 2>&1
assert_file_exists "plan registers execution-plan.json" "$AUDIT_DIR/execution-plan.json"
assert_eq "plan has correct content" "build" \
  "$(json_field "$AUDIT_DIR/execution-plan.json" "d['planned_phases'][0]['phase']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
echo "not json" >"$TMPDIR/bad.json"
output=$(bash "$AUDIT_SCRIPT" plan "$TMPDIR/bad.json" 2>&1)
assert_contains "plan rejects invalid JSON" "$output" "Invalid plan JSON"
teardown

setup
bash "$AUDIT_SCRIPT" init "plan test" >/dev/null 2>&1
printf '%s' "$PLAN_FIRST" >"$TMPDIR/plan1.json"
printf '%s' "$PLAN_SECOND" >"$TMPDIR/plan2.json"
bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan1.json" >/dev/null 2>&1
output=$(bash "$AUDIT_SCRIPT" plan "$TMPDIR/plan2.json" 2>&1)
assert_contains "plan noop when exists" "$output" "already registered"
assert_eq "plan keeps first registration" "first" \
  "$(json_field "$AUDIT_DIR/execution-plan.json" "d['task']")"
teardown

echo ""

# --- log ---
echo "Log command:"

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started >/dev/null 2>&1
assert_eq "log started" "started" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['action']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --duration=120 --tools=30 --context="built feature" >/dev/null 2>&1
assert_eq "log completed with duration" "120" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['duration_seconds']")"
assert_eq "log completed with tools" "30" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['tool_calls']")"
assert_eq "log completed with context" "built feature" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder failed --context="stuck on gate" >/dev/null 2>&1
assert_eq "log failed" "failed" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['action']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "log test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder started >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed >/dev/null 2>&1
id1=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['id']")
id2=$(json_field "$AUDIT_DIR/trail.json" "d['entries'][1]['id']")
assert_ne "log generates unique IDs" "$id1" "$id2"
teardown

echo ""

# --- special characters in context ---
echo "Special characters:"

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context="it's a 'quoted' value" >/dev/null 2>&1
assert_eq "context with single quotes" "it's a 'quoted' value" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context='has "double quotes" inside' >/dev/null 2>&1
assert_eq "context with double quotes" 'has "double quotes" inside' \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "special chars test" >/dev/null 2>&1
bash "$AUDIT_SCRIPT" log build sdlc:builder completed --context='has $dollar and `backtick`' >/dev/null 2>&1
assert_eq "context with dollar and backtick" "has \$dollar and \`backtick\`" \
  "$(json_field "$AUDIT_DIR/trail.json" "d['entries'][0]['context']")"
teardown

setup
bash "$AUDIT_SCRIPT" init "task with 'quotes' and \$vars" >/dev/null 2>&1
output=$(bash "$AUDIT_SCRIPT" show 2>&1)
assert_contains "show handles special chars in task" "$output" "quotes"
teardown

echo ""

# --- report ---
echo "Report command:"

PLAN_REPORT='{"task":"build feature","planned_phases":[{"order":1,"phase":"build","agent":"sdlc:builder","skills":["sdlc:build"],"reason":"code needed"},{"order":2,"phase":"review","agent":"sdlc:reviewer","skills":["sdlc:review"],"reason":"needs review"}]}'
PLAN_FAILED='{"task":"test failed","planned_phases":[{"order":1,"phase":"build","agent":"sdlc:builder","skills":["sdlc:build"],"reason":"code needed"}]}'

setup
bash "$AUDIT_SCRIPT" init "report test" >/dev/null 2>&1
printf '%s' "$PLAN_REPORT" >"$TMPDIR/plan.json"
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
printf '%s' "$PLAN_FAILED" >"$TMPDIR/plan.json"
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
mkdir -p "$AUDIT_DIR/entries"
echo '{"id":"test-entry-1","timestamp":"2026-01-01T00:00:00Z","phase":"build","name":"sdlc:builder","action":"completed","sha":"abc123"}' >"$AUDIT_DIR/entries/test-entry-1.json"
echo '{"id":"test-entry-2","timestamp":"2026-01-01T00:01:00Z","phase":"review","name":"sdlc:reviewer","action":"started","sha":"abc123"}' >"$AUDIT_DIR/entries/test-entry-2.json"
report=$(bash "$AUDIT_SCRIPT" report 2>&1)
assert_contains "report merges per-entry files" "$report" "sdlc:builder"
assert_contains "report merges both entries" "$report" "sdlc:reviewer"
# BSD wc -l pads with leading spaces — strip with tr before compare.
count=$(find "$AUDIT_DIR/entries" -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]')
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
