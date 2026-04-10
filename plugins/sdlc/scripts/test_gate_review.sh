#!/usr/bin/env bash
# Tests for gate-review.sh — all six code paths
# Uses a fresh git repo per test with isolated .quality/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate-review.sh"

PASS=0
FAIL=0

# Cleanup any temp dirs created during the run
TMPDIRS=()
cleanup() {
  # Guard empty-array expansion under set -u
  for d in "${TMPDIRS[@]:-}"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# ─── Helpers ──────────────────────────────────────────────────────────────────

# make_repo [BRANCH_NAME]
# Creates a fresh git repo with a remote, main and feature branches.
# Writes a minimal sdlc.config.json so SDLC_MANAGED=true and pre-creates
# .quality/proof/ as the working directory for the gate.
# Returns the tmpdir path.
make_repo() {
  local branch_name="${1:-feature}"
  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")

  cd "$tmpdir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git remote add origin "https://github.com/test-org/gatereviewfixture.git"

  git checkout -q -b main
  echo "# init" >README.md
  git add README.md
  git commit -q -m "init"

  git checkout -q -b "$branch_name"
  echo "change" >change.txt
  git add change.txt
  git commit -q -m "add feature"

  # sdlc.config.json is the authoritative "sdlc-managed" marker for gate-review
  echo '{"thresholds": {}}' >"$tmpdir/sdlc.config.json"
  mkdir -p "$tmpdir/.quality/proof"

  echo "$tmpdir"
}

# write_coverage REPO_DIR SHA STATUS [ARCHITECT_REMAINING_COUNT]
# Writes review-coverage.json into .quality/proof/
# ARCHITECT_REMAINING_COUNT=0 means empty remaining (complete).
write_coverage() {
  local repo_dir="$1"
  local sha="$2"
  local status="$3"
  local arch_remaining="${4:-0}"
  local omit_sha="${5:-false}"

  python3 -c "
import json, sys

repo_dir = sys.argv[1]
sha = sys.argv[2]
status = sys.argv[3]
arch_remaining = int(sys.argv[4])
omit_sha = sys.argv[5] == 'true'

remaining = ['src/foo.py'] * arch_remaining

agent_stub = {'dispatched': [], 'reviewed': [], 'remaining': [], 'shards': 1, 'passes': 1}
data = {
    'status': status,
    'agents': {
        'architect': {**agent_stub, 'remaining': remaining},
        'security': {**agent_stub},
        'correctness': {**agent_stub},
        'style': {**agent_stub}
    }
}
if not omit_sha:
    data['sha'] = sha

with open(repo_dir + '/.quality/proof/review-coverage.json', 'w') as f:
    json.dump(data, f, indent=2)
" "$repo_dir" "$sha" "$status" "$arch_remaining" "$omit_sha"
}

# run_gate REPO_DIR
# Runs gate-review.sh with isolated env. Reads proof JSON and prints:
#   status coverage_status incomplete_agents_json coverage_sha_prefix
run_gate() {
  local repo_dir="$1"
  local proof_dir="$repo_dir/.quality/proof"

  cd "$repo_dir"
  # Unset CI/GITHUB_ACTIONS so existing tests exercise their intended code
  # path even when the suite runs under a CI environment.
  env -u CI -u GITHUB_ACTIONS \
    PROOF_DIR="$proof_dir" \
    SDLC_CONFIG_FILE="$repo_dir/sdlc.config.json" \
    bash "$GATE" >/dev/null 2>&1 || true

  # Use a non-whitespace sentinel ('-') for empty fields so assertions can
  # compare fields positionally without relying on load-bearing whitespace.
  PROOF_JSON="$proof_dir/review.json" python3 -c "
import json, os, sys
try:
    d = json.load(open(os.environ['PROOF_JSON']))
    status = d.get('status', 'MISSING')
    coverage_status = d.get('coverage_status', '-') or '-'
    incomplete = d.get('incomplete_agents', [])
    coverage_sha = d.get('coverage_sha', '') or ''
    bypassed = d.get('bypassed_via') or 'null'
    sha_prefix = coverage_sha[:7] if coverage_sha else '-'
    incomplete_str = ','.join(incomplete) if incomplete else 'none'
    print(status, coverage_status, incomplete_str, sha_prefix, bypassed)
except Exception as e:
    print('ERROR', '-', '-', '-', str(e))
"
  cd - >/dev/null
}

# run_gate_with_config REPO_DIR CONFIG_JSON
# Writes sdlc.config.json then runs the gate.
run_gate_with_config() {
  local repo_dir="$1"
  local config_json="$2"

  echo "$config_json" >"$repo_dir/sdlc.config.json"
  run_gate "$repo_dir"
}

assert_eq() {
  local label="$1"
  local expected="$2"
  local got="$3"

  if [ "$got" = "$expected" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  got:      $got"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test 1: Missing review-coverage.json → status=fail, coverage_status=missing
REPO=$(make_repo "feature")
OUTPUT=$(run_gate "$REPO")
WANT="fail missing none - null"
assert_eq "missing review-coverage.json → fail/missing" "$WANT" "$OUTPUT"

# ─── Test 2: status=incomplete, architect.remaining=["src/foo.py"] → fail/incomplete ─
REPO=$(make_repo "feature")
HEAD_SHA=$(cd "$REPO" && git rev-parse HEAD)
write_coverage "$REPO" "$HEAD_SHA" "incomplete" 1
OUTPUT=$(run_gate "$REPO")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
COV_STATUS=$(echo "$OUTPUT" | awk '{print $2}')
INCOMPLETE_AGENTS=$(echo "$OUTPUT" | awk '{print $3}')
if [ "$STATUS" = "fail" ] && [ "$COV_STATUS" = "incomplete" ] && [ "$INCOMPLETE_AGENTS" = "architect" ]; then
  echo "PASS: incomplete coverage, architect has remaining → fail/incomplete"
  PASS=$((PASS + 1))
else
  echo "FAIL: incomplete coverage, architect has remaining"
  echo "  expected status=fail coverage_status=incomplete incomplete_agents=architect"
  echo "  got: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# ─── Test 3: SHA mismatch (deadbeef vs HEAD) → status=fail, coverage_sha prefix=deadbee ─
REPO=$(make_repo "feature")
write_coverage "$REPO" "deadbeef1234567890" "complete" 0
OUTPUT=$(run_gate "$REPO")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
COV_STATUS=$(echo "$OUTPUT" | awk '{print $2}')
SHA_PREFIX=$(echo "$OUTPUT" | awk '{print $4}')
if [ "$STATUS" = "fail" ] && [ "$COV_STATUS" = "complete" ] && [ "$SHA_PREFIX" = "deadbee" ]; then
  echo "PASS: SHA mismatch → fail, coverage_sha prefix=deadbee"
  PASS=$((PASS + 1))
else
  echo "FAIL: SHA mismatch check"
  echo "  expected status=fail coverage_status=complete sha_prefix=deadbee"
  echo "  got status=$STATUS coverage_status=$COV_STATUS sha_prefix=$SHA_PREFIX"
  FAIL=$((FAIL + 1))
fi

# ─── Test 4: Complete + matching SHA → status=pass ────────────────────────────
REPO=$(make_repo "feature")
HEAD_SHA=$(cd "$REPO" && git rev-parse HEAD)
write_coverage "$REPO" "$HEAD_SHA" "complete" 0
OUTPUT=$(run_gate "$REPO")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
COV_STATUS=$(echo "$OUTPUT" | awk '{print $2}')
if [ "$STATUS" = "pass" ] && [ "$COV_STATUS" = "complete" ]; then
  echo "PASS: complete + matching SHA → pass"
  PASS=$((PASS + 1))
else
  echo "FAIL: complete + matching SHA"
  echo "  expected status=pass coverage_status=complete"
  echo "  got: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# ─── Test 5: No sdlc.config.json → status=skip (not sdlc-managed) ────────────────
REPO=$(make_repo "feature")
# Remove sdlc.config.json to simulate a non-sdlc-managed project
rm -f "$REPO/sdlc.config.json"
OUTPUT=$(run_gate "$REPO")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
if [ "$STATUS" = "skip" ]; then
  echo "PASS: no sdlc.config.json → skip (not sdlc-managed)"
  PASS=$((PASS + 1))
else
  echo "FAIL: no sdlc.config.json should → skip"
  echo "  got: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# ─── Test 6: allow.review branch entry → status=skip, bypassed_via=allow_list ─
REPO=$(make_repo "feature")
CONFIG_JSON=$(python3 -c "
import json
config = {
    'allow': {
        'review': [
            {'branch': 'feature', 'reason': 'reviewed separately in sprint-42'}
        ]
    }
}
print(json.dumps(config, indent=2))
")
OUTPUT=$(run_gate_with_config "$REPO" "$CONFIG_JSON")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
BYPASSED=$(echo "$OUTPUT" | awk '{print $NF}')
if [ "$STATUS" = "skip" ] && [ "$BYPASSED" = "allow_list" ]; then
  echo "PASS: allow.review branch entry → skip, bypassed_via=allow_list"
  PASS=$((PASS + 1))
else
  echo "FAIL: allow.review branch entry"
  echo "  expected status=skip bypassed_via=allow_list"
  echo "  got: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# ─── Test 7: review-coverage.json omits sha field → fail (missing sha) ───────
REPO=$(make_repo "feature")
write_coverage "$REPO" "unused" "complete" 0 "true"
OUTPUT=$(run_gate "$REPO")
STATUS=$(echo "$OUTPUT" | awk '{print $1}')
# The parser sees a "complete" status file → coverage_status is "complete"
# → the gate hits the stale-SHA branch (not the parse-error branch). Assert
# both fields to pin the specific code path.
COV_STATUS=$(echo "$OUTPUT" | awk '{print $2}')
if [ "$STATUS" = "fail" ] && [ "$COV_STATUS" = "complete" ]; then
  echo "PASS: missing sha field → fail via stale-SHA branch"
  PASS=$((PASS + 1))
else
  echo "FAIL: missing sha field should → fail via stale-SHA branch"
  echo "  got: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# ─── Test 8: CI environment → skip with bypassed_via=ci_environment ─────────
# review-coverage.json is local-only (gitignored), so CI must skip this gate.
# Both CI=true and GITHUB_ACTIONS should trigger the same skip path.
assert_ci_skip() {
  local var="$1"
  local REPO proof_dir status bypassed
  REPO=$(make_repo "feature")
  proof_dir="$REPO/.quality/proof"
  (cd "$REPO" && env "$var=true" PROOF_DIR="$proof_dir" SDLC_CONFIG_FILE="$REPO/sdlc.config.json" bash "$GATE" >/dev/null 2>&1) || true
  # Each field asserted independently so a swap between status and
  # bypassed_via still fails. Path via env var (matching run_gate) so
  # exotic tmpdir characters cannot break the python3 -c string.
  local parsed
  parsed=$(PROOF_JSON="$proof_dir/review.json" python3 -c "import json, os; d=json.load(open(os.environ['PROOF_JSON'])); print(d.get('status')); print(d.get('bypassed_via'))")
  status=$(echo "$parsed" | sed -n 1p)
  bypassed=$(echo "$parsed" | sed -n 2p)
  assert_eq "$var=true → status=skip" "skip" "$status"
  assert_eq "$var=true → bypassed_via=ci_environment" "ci_environment" "$bypassed"
}
assert_ci_skip CI
assert_ci_skip GITHUB_ACTIONS

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
