#!/usr/bin/env bash
# Tests for enforce-review-before-pr hook
# Covers each exit path: non-matching command (allow), no .quality dir (allow),
# missing review-coverage.json (block), incomplete status (block), stale SHA (block),
# missing PROOF.md (block), all conditions met (allow)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/enforce-review-before-pr"
PASS=0
FAIL=0

assert_contains() {
  local test_name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected to contain '$needle', got: $haystack)"
  fi
}

run_hook() {
  local workdir="$1" input="$2"
  echo "$input" | (cd "$workdir" && bash "$HOOK")
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── Test 1: Non-matching command → allow ──────────────────────

echo "=== Non-matching command ==="

WORKDIR="$TMPDIR_BASE/nonmatch"
mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q
INPUT='{"tool_input":{"command":"git push origin main"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows non-PR command" "$RESULT" '"allow"'

# ─── Test 2: No .quality directory → allow ──────────────────────

echo "=== No .quality directory ==="

WORKDIR="$TMPDIR_BASE/no-quality"
mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows when no .quality dir" "$RESULT" '"allow"'

# ─── Test 3: Missing review-coverage.json → block ───────────────

echo "=== Missing review-coverage.json ==="

WORKDIR="$TMPDIR_BASE/no-review"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when no review-coverage.json" "$RESULT" '"block"'
assert_contains "mentions review" "$RESULT" 'review'

# ─── Test 4: Incomplete review status → block ───────────────────

echo "=== Incomplete review status ==="

WORKDIR="$TMPDIR_BASE/incomplete"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
echo '{"status": "incomplete", "sha": "abc123"}' >"$WORKDIR/.quality/proof/review-coverage.json"
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when status incomplete" "$RESULT" '"block"'

# ─── Test 5: Stale SHA → block ──────────────────────────────────

echo "=== Stale review SHA ==="

WORKDIR="$TMPDIR_BASE/stale"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
# Create a commit so HEAD exists
touch "$WORKDIR/dummy"
git -C "$WORKDIR" add dummy
git -C "$WORKDIR" commit -q -m "init"
# CURRENT_SHA intentionally not used — we pass a mismatched SHA to test staleness detection
echo "{\"status\": \"complete\", \"sha\": \"stale_sha_not_matching\"}" >"$WORKDIR/.quality/proof/review-coverage.json"
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when SHA is stale" "$RESULT" '"block"'
assert_contains "mentions stale" "$RESULT" 'stale'

# ─── Test 6: Missing PROOF.md → block ───────────────────────────

echo "=== Missing PROOF.md ==="

WORKDIR="$TMPDIR_BASE/no-proof"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
touch "$WORKDIR/dummy"
git -C "$WORKDIR" add dummy
git -C "$WORKDIR" commit -q -m "init"
SHA=$(git -C "$WORKDIR" rev-parse HEAD)
echo "{\"status\": \"complete\", \"sha\": \"$SHA\"}" >"$WORKDIR/.quality/proof/review-coverage.json"
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when no PROOF.md" "$RESULT" '"block"'
assert_contains "mentions PROOF" "$RESULT" 'PROOF'

# ─── Test 7: All conditions met → allow ─────────────────────────

echo "=== All conditions met ==="

WORKDIR="$TMPDIR_BASE/all-good"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
touch "$WORKDIR/dummy"
git -C "$WORKDIR" add dummy
git -C "$WORKDIR" commit -q -m "init"
SHA=$(git -C "$WORKDIR" rev-parse HEAD)
echo "{\"status\": \"complete\", \"sha\": \"$SHA\"}" >"$WORKDIR/.quality/proof/review-coverage.json"
echo "# Proof" >"$WORKDIR/.quality/proof/PROOF.md"
INPUT='{"tool_input":{"command":"gh pr create --title test"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows when all conditions met" "$RESULT" '"allow"'

# ─── Test 8: gh pr edit also matched → block when no proof ──────

echo "=== gh pr edit matched ==="

WORKDIR="$TMPDIR_BASE/edit"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
INPUT='{"tool_input":{"command":"gh pr edit 42 --body updated"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks gh pr edit without proof" "$RESULT" '"block"'

# ─── Test 9: gh pr edit with all conditions met → allow ─────────

echo "=== gh pr edit happy path ==="

WORKDIR="$TMPDIR_BASE/edit-allow"
mkdir -p "$WORKDIR/.quality/proof"
git -C "$WORKDIR" init -q
touch "$WORKDIR/dummy"
git -C "$WORKDIR" add dummy
git -C "$WORKDIR" commit -q -m "init"
SHA=$(git -C "$WORKDIR" rev-parse HEAD)
echo "{\"status\": \"complete\", \"sha\": \"$SHA\"}" >"$WORKDIR/.quality/proof/review-coverage.json"
echo "# Proof" >"$WORKDIR/.quality/proof/PROOF.md"
INPUT='{"tool_input":{"command":"gh pr edit 42 --body updated"}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows gh pr edit when all conditions met" "$RESULT" '"allow"'

# ─── Summary ────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
