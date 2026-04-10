#!/usr/bin/env bash
# Tests for block-merge-without-ci hook
# Uses function sourcing + mocked gh commands to test without hitting GitHub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

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

# Source just the helper functions (not the main logic at the bottom)
# Extract everything between set -euo and PR_NUMBER= (the function definitions)
eval "$(sed -n '/^extract_pr_number/,/^PR_NUMBER/{/^PR_NUMBER/d;p;}' "$SCRIPT_DIR/block-merge-without-ci")"

# ─── extract_pr_number tests ────────────────────────────────────

echo "=== extract_pr_number ==="

assert_eq "extracts number from 'gh pr merge 123'" \
  "123" "$(extract_pr_number "gh pr merge 123")"

assert_eq "extracts number from 'gh pr merge 456 --squash'" \
  "456" "$(extract_pr_number "gh pr merge 456 --squash")"

assert_eq "extracts number from 'gh pr merge --squash 789'" \
  "789" "$(extract_pr_number "gh pr merge --squash 789")"

assert_eq "extracts number from 'gh pr merge --squash --delete-branch 101'" \
  "101" "$(extract_pr_number "gh pr merge --squash --delete-branch 101")"

assert_eq "returns empty for 'gh pr merge' with no number" \
  "" "$(extract_pr_number "gh pr merge")"

assert_eq "returns empty for 'gh pr merge --squash'" \
  "" "$(extract_pr_number "gh pr merge --squash")"

# ─── count_matching tests ───────────────────────────────────────

echo "=== count_matching ==="

SAMPLE_CHECKS=$(printf "quality-gates\tpass\t49s\thttps://example.com\nlint\tfail\t12s\thttps://example.com\ntypecheck\tpending\t0\thttps://example.com")

TAB="$(printf '\t')"

assert_eq "counts 1 failing check" \
  "1" "$(count_matching "${TAB}fail" "$SAMPLE_CHECKS")"

assert_eq "counts 1 pending check" \
  "1" "$(count_matching "${TAB}pending" "$SAMPLE_CHECKS")"

assert_eq "counts 0 for no matches" \
  "0" "$(count_matching "nonexistent" "$SAMPLE_CHECKS")"

ALL_PASS=$(printf "gate-a\tpass\t10s\thttps://example.com\ngate-b\tpass\t5s\thttps://example.com")

assert_eq "counts 0 failing in all-pass" \
  "0" "$(count_matching "${TAB}fail" "$ALL_PASS")"

# ─── End-to-end via stdin (requires mocked gh) ─────────────────

echo "=== end-to-end (mocked gh) ==="

# Create a temp dir with a mock gh
TMPDIR_E2E=$(mktemp -d)
trap 'rm -rf "$TMPDIR_E2E"' EXIT

# Mock gh that returns all-pass checks and approved review
cat >"$TMPDIR_E2E/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then
  printf "quality-gates\tpass\t49s\thttps://example.com\n"
elif [[ "$*" == *"pr view"* ]]; then
  echo '{"reviewDecision":"APPROVED","reviews":[{"state":"APPROVED"}]}'
fi
MOCKGH
chmod +x "$TMPDIR_E2E/gh"

# Test: all pass + approved = allow
INPUT='{"tool_input":{"command":"gh pr merge 42"}}'
RESULT=$(echo "$INPUT" | PATH="$TMPDIR_E2E:$PATH" bash "$SCRIPT_DIR/block-merge-without-ci")
assert_contains "allows merge when checks pass and approved" "$RESULT" '"allow"'

# Mock gh with failing checks (gh exits non-zero when checks fail)
cat >"$TMPDIR_E2E/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then
  printf "quality-gates\tfail\t49s\thttps://example.com\n"
  exit 1
elif [[ "$*" == *"pr view"* ]]; then
  echo '{"reviewDecision":"APPROVED","reviews":[{"state":"APPROVED"}]}'
fi
MOCKGH
chmod +x "$TMPDIR_E2E/gh"

RESULT=$(echo "$INPUT" | PATH="$TMPDIR_E2E:$PATH" bash "$SCRIPT_DIR/block-merge-without-ci")
assert_contains "blocks merge on failing checks" "$RESULT" '"block"'
assert_contains "mentions failing in reason (not auth error)" "$RESULT" "failing"

# Mock gh with pending checks
cat >"$TMPDIR_E2E/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then
  printf "quality-gates\tpending\t0\thttps://example.com\n"
elif [[ "$*" == *"pr view"* ]]; then
  echo '{"reviewDecision":"APPROVED","reviews":[{"state":"APPROVED"}]}'
fi
MOCKGH
chmod +x "$TMPDIR_E2E/gh"

RESULT=$(echo "$INPUT" | PATH="$TMPDIR_E2E:$PATH" bash "$SCRIPT_DIR/block-merge-without-ci")
assert_contains "blocks merge on pending checks" "$RESULT" '"block"'
assert_contains "mentions pending in reason" "$RESULT" "pending"

# Mock gh with changes requested
cat >"$TMPDIR_E2E/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then
  printf "quality-gates\tpass\t49s\thttps://example.com\n"
elif [[ "$*" == *"pr view"* ]]; then
  echo '{"reviewDecision":"CHANGES_REQUESTED","reviews":[{"state":"CHANGES_REQUESTED"}]}'
fi
MOCKGH
chmod +x "$TMPDIR_E2E/gh"

RESULT=$(echo "$INPUT" | PATH="$TMPDIR_E2E:$PATH" bash "$SCRIPT_DIR/block-merge-without-ci")
assert_contains "blocks merge on changes requested" "$RESULT" '"block"'
assert_contains "mentions requested changes" "$RESULT" "requested changes"

# Mock gh with zero reviews (unapproved PR)
cat >"$TMPDIR_E2E/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then
  printf "quality-gates\tpass\t49s\thttps://example.com\n"
elif [[ "$*" == *"pr view"* ]]; then
  echo '{"reviewDecision":"","reviews":[]}'
fi
MOCKGH
chmod +x "$TMPDIR_E2E/gh"

RESULT=$(echo "$INPUT" | PATH="$TMPDIR_E2E:$PATH" bash "$SCRIPT_DIR/block-merge-without-ci")
assert_contains "blocks merge when PR has zero reviews" "$RESULT" '"block"'
assert_contains "mentions not approved" "$RESULT" "not approved"

# ─── Summary ────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
