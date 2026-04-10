#!/usr/bin/env bash
# Tests for require-critic-approval hook
# Covers each exit path: no .quality dir (allow), maintenance prefix (allow),
# missing critic.json (block), approved verdict (allow), non-approved verdict (block)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/require-critic-approval"
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

# Create isolated working directory for each test
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── Test 1: No .quality directory → allow ──────────────────────

echo "=== No .quality directory ==="

WORKDIR="$TMPDIR_BASE/no-quality"
mkdir -p "$WORKDIR"
INPUT='{"tool_input":{"command":"git commit -m \"feat: add thing\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows commit when no .quality dir" "$RESULT" '"allow"'

# ─── Test 2: Maintenance prefix → allow ─────────────────────────

echo "=== Maintenance prefix ==="

WORKDIR="$TMPDIR_BASE/maintenance"
mkdir -p "$WORKDIR/.quality/proof"
# No critic.json, but maintenance prefix should short-circuit

# Prefixes that still bypass critic
for prefix in "chore:" "docs:" "style:" "test:"; do
  INPUT="{\"tool_input\":{\"command\":\"git commit -m \\\"${prefix} update something\\\"\"}}"
  RESULT=$(run_hook "$WORKDIR" "$INPUT")
  assert_contains "allows maintenance prefix '$prefix'" "$RESULT" '"allow"'
done

# Prefixes that NOW require critic approval — dedicated workdir so state from
# the allow-prefix loop above cannot leak into the blocking assertions.
WORKDIR_BLOCK="$TMPDIR_BASE/blocking-prefix"
mkdir -p "$WORKDIR_BLOCK/.quality/proof"
[ ! -f "$WORKDIR_BLOCK/.quality/proof/critic.json" ] || {
  echo "SETUP ERROR: critic.json must not exist in $WORKDIR_BLOCK"
  exit 1
}
for prefix in "fix:" "refactor:"; do
  INPUT="{\"tool_input\":{\"command\":\"git commit -m \\\"${prefix} update something\\\"\"}}"
  RESULT=$(run_hook "$WORKDIR_BLOCK" "$INPUT")
  assert_contains "blocks prefix '$prefix' (no longer maintenance)" "$RESULT" '"block"'
done

# ─── Test 3: Missing critic.json → block ────────────────────────

echo "=== Missing critic.json ==="

WORKDIR="$TMPDIR_BASE/no-critic"
mkdir -p "$WORKDIR/.quality/proof"
INPUT='{"tool_input":{"command":"git commit -m \"feat: new feature\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when critic.json missing" "$RESULT" '"block"'
assert_contains "mentions no critic review" "$RESULT" "No critic review"

# ─── Test 4: Approved verdict → allow ───────────────────────────

echo "=== Approved verdict ==="

WORKDIR="$TMPDIR_BASE/approved"
mkdir -p "$WORKDIR/.quality/proof"
cat >"$WORKDIR/.quality/proof/critic.json" <<'JSON'
{"verdict": "approved", "findings": []}
JSON
INPUT='{"tool_input":{"command":"git commit -m \"feat: approved feature\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "allows commit when critic approved" "$RESULT" '"allow"'

# ─── Test 5: Non-approved verdict → block ───────────────────────

echo "=== Non-approved verdict ==="

WORKDIR="$TMPDIR_BASE/findings"
mkdir -p "$WORKDIR/.quality/proof"
cat >"$WORKDIR/.quality/proof/critic.json" <<'JSON'
{"verdict": "findings", "findings": [{"file": "a.py", "issue": "dead code"}]}
JSON
INPUT='{"tool_input":{"command":"git commit -m \"feat: unreviewed feature\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when verdict is not approved" "$RESULT" '"block"'
assert_contains "mentions verdict in block reason" "$RESULT" "findings"
assert_contains "mentions finding count" "$RESULT" "1"

# ─── Test 6: Unknown/missing verdict field → block ──────────────

echo "=== Unknown verdict ==="

WORKDIR="$TMPDIR_BASE/unknown"
mkdir -p "$WORKDIR/.quality/proof"
cat >"$WORKDIR/.quality/proof/critic.json" <<'JSON'
{"findings": []}
JSON
INPUT='{"tool_input":{"command":"git commit -m \"feat: something\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "blocks when verdict field missing" "$RESULT" '"block"'
assert_contains "shows unknown verdict" "$RESULT" "unknown"

# ─── Test 7: Stale approval is consumed after first use ──────────

echo "=== Stale approval consumed ==="

WORKDIR="$TMPDIR_BASE/stale"
mkdir -p "$WORKDIR/.quality/proof"
cat >"$WORKDIR/.quality/proof/critic.json" <<'JSON'
{"verdict": "approved", "findings": []}
JSON
INPUT='{"tool_input":{"command":"git commit -m \"feat: first commit\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "first commit allowed with approval" "$RESULT" '"allow"'

# critic.json should be deleted after the allowed commit
if [ -f "$WORKDIR/.quality/proof/critic.json" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: critic.json should be deleted after allowed commit"
else
  PASS=$((PASS + 1))
  echo "  PASS: critic.json deleted after allowed commit"
fi

# Second commit without re-approval should be blocked
INPUT='{"tool_input":{"command":"git commit -m \"feat: second commit\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "second commit blocked without fresh approval" "$RESULT" '"block"'
assert_contains "mentions no critic review" "$RESULT" "No critic review"

# ─── Test 8: Heredoc-style commit message → safe behavior ───────

echo "=== Heredoc format ==="

WORKDIR="$TMPDIR_BASE/heredoc"
mkdir -p "$WORKDIR/.quality/proof"
# Heredoc-wrapped messages are complex; verify the hook does not crash
# and falls through to critic check (safe-side: block without critic)
INPUT="{\"tool_input\":{\"command\":\"git commit -m \\\"\$(cat <<EOF\\nfix: stuff\\nEOF\\n)\\\"\"}}"
RESULT=$(run_hook "$WORKDIR" "$INPUT")
# No critic.json in this workdir and fix: is no longer a bypass prefix,
# so the safe-side outcome must be block (not just "any decision").
assert_contains "heredoc format does not crash and blocks without critic" "$RESULT" '"block"'

# ─── Test 9: Multi-flag -m bypass attempt → block ───────────────
# `git commit -m "feat: real" -m "chore: bypass"` must NOT bypass critic just
# because the trailing message has a maintenance prefix. The first message is
# the real subject and is non-maintenance — bypass must only be granted when
# every -m message is maintenance-prefixed.

echo "=== Multi-flag -m bypass attempt ==="

WORKDIR="$TMPDIR_BASE/multi-m-bypass"
mkdir -p "$WORKDIR/.quality/proof"
INPUT='{"tool_input":{"command":"git commit -m \"feat: real change\" -m \"chore: cosmetic\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "feat: + chore: dual -m does not bypass critic" "$RESULT" '"block"'

# But all-maintenance dual -m IS still allowed
INPUT='{"tool_input":{"command":"git commit -m \"chore: A\" -m \"docs: B\""}}'
RESULT=$(run_hook "$WORKDIR" "$INPUT")
assert_contains "chore: + docs: dual -m allows bypass" "$RESULT" '"allow"'

# ─── Summary ────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
