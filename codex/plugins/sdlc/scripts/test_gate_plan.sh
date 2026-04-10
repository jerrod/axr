#!/usr/bin/env bash
# Tests for gate-plan.sh — all five code paths
# Uses a fresh git repo per test with an isolated HOME to avoid touching real plans.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate-plan.sh"

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

# ─── Helpers ─────────────────────────────────────────────────────────────────

# make_repo BRANCH_NAME COMMIT_MSG
# Creates a fresh git repo with origin set to a synthetic URL so get_repo_name
# returns "gateplanfixture". Leaves cwd inside the repo on BRANCH_NAME.
make_repo() {
  local branch_name="${1:-feature}"
  local commit_msg="${2:-add feature}"
  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")

  cd "$tmpdir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git remote add origin "https://github.com/test-org/gateplanfixture.git"

  # Initial commit on main
  git checkout -q -b main
  echo "# init" >README.md
  git add README.md
  git commit -q -m "init"

  # Feature branch
  git checkout -q -b "$branch_name"
  echo "change" >change.txt
  git add change.txt
  git commit -q -m "$commit_msg"

  echo "$tmpdir"
}

# make_plan_home — returns a fresh tmpdir to use as HOME for plan isolation
make_plan_home() {
  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")
  echo "$tmpdir"
}

# write_config REPO_DIR PLAN_REQUIRED [ALLOW_BRANCH]
# Writes sdlc.config.json into REPO_DIR.
write_config() {
  local repo_dir="$1"
  local plan_required="$2"
  local allow_branch="${3:-}"

  python3 -c "
import json, sys
plan_required_val = sys.argv[1] == 'true'
allow_branch = sys.argv[2]
repo_dir = sys.argv[3]

config = {'plan_required': plan_required_val, 'allow': {}}
if allow_branch:
    config['allow']['plan'] = [{'branch': allow_branch, 'reason': 'tracked separately in jira ABC-123'}]

with open(repo_dir + '/sdlc.config.json', 'w') as f:
    json.dump(config, f, indent=2)
" "$plan_required" "$allow_branch" "$repo_dir"
}

# run_gate REPO_DIR FAKE_HOME
# Runs gate-plan.sh with isolated env. Returns the proof JSON status field.
run_gate() {
  local repo_dir="$1"
  local fake_home="$2"
  local proof_dir="$repo_dir/.quality/proof"
  mkdir -p "$proof_dir"

  cd "$repo_dir"
  # Unset CI/GITHUB_ACTIONS so existing tests exercise their intended code path
  # even when the suite runs under a CI environment (where the gate would
  # otherwise always skip via the ci_environment bypass).
  env -u CI -u GITHUB_ACTIONS \
    SDLC_DEFAULT_BRANCH=main \
    PROOF_DIR="$proof_dir" \
    HOME="$fake_home" \
    SDLC_CONFIG_FILE="$repo_dir/sdlc.config.json" \
    bash "$GATE" >/dev/null 2>&1 || true

  python3 -c "
import json, sys
try:
    d = json.load(open('$proof_dir/plan.json'))
    status = d.get('status', 'MISSING')
    bypassed = d.get('bypassed_via')
    bypassed_str = str(bypassed) if bypassed is not None else 'null'
    print(status, bypassed_str)
except Exception as e:
    print('ERROR', str(e))
"
  cd - >/dev/null
}

assert_eq() {
  local label="$1"
  local expected_status="$2"
  local expected_bypassed="$3"
  local output="$4"
  local got_status got_bypassed
  got_status=$(echo "$output" | awk '{print $1}')
  got_bypassed=$(echo "$output" | awk '{print $2}')

  if [ "$got_status" = "$expected_status" ] && [ "$got_bypassed" = "$expected_bypassed" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected status=$expected_status bypassed_via=$expected_bypassed"
    echo "  got     status=$got_status bypassed_via=$got_bypassed"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test 1: plan_required=false → skip ──────────────────────────────────────
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "false"
OUTPUT=$(run_gate "$REPO" "$HOME_DIR")
assert_eq "plan_required=false → status=skip, no bypass" "skip" "null" "$OUTPUT"

# ─── Test 2: plan_required=true, no plan file → fail with escape hints ───────
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true"
OUTPUT=$(run_gate "$REPO" "$HOME_DIR")
assert_eq "no plan file → status=fail" "fail" "null" "$OUTPUT"
# Spec test #5: verify error text includes path and escape option names
STDERR_OUT=$( (cd "$REPO" && SDLC_DEFAULT_BRANCH=main PROOF_DIR="$REPO/.quality/proof" HOME="$HOME_DIR" SDLC_CONFIG_FILE="$REPO/sdlc.config.json" bash "$GATE" 2>&1 >/dev/null) || true)
for needle in ".claude/plans/" "/sdlc:plan" "hotfix:" "plan_required=false"; do
  if echo "$STDERR_OUT" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: fail stderr mentions '$needle'"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: fail stderr missing '$needle'"
  fi
done

# ─── Test 3: HEAD commit is hotfix: → skip with hotfix_prefix ────────────────
REPO=$(make_repo "feature" "hotfix: urgent thing")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true"
OUTPUT=$(run_gate "$REPO" "$HOME_DIR")
assert_eq "hotfix commit → status=skip, bypassed_via=hotfix_prefix" "skip" "hotfix_prefix" "$OUTPUT"

# ─── Test 4: plan file exists → pass ─────────────────────────────────────────
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true"
# Plan file at expected path: $HOME/.claude/plans/gateplanfixture/feature.md
mkdir -p "$HOME_DIR/.claude/plans/gateplanfixture"
echo "# Feature plan" >"$HOME_DIR/.claude/plans/gateplanfixture/feature.md"
OUTPUT=$(run_gate "$REPO" "$HOME_DIR")
assert_eq "plan file exists → status=pass" "pass" "null" "$OUTPUT"

# ─── Test 5: allow-list match → skip with allow_list ─────────────────────────
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true" "feature"
OUTPUT=$(run_gate "$REPO" "$HOME_DIR")
assert_eq "allow-list match → status=skip, bypassed_via=allow_list" "skip" "allow_list" "$OUTPUT"

# ─── Test 6: CI environment → skip with ci_environment ──────────────────────
# Plan files live outside the repo so CI cannot enforce this gate. Both
# CI=true and GITHUB_ACTIONS (non-empty) should trigger the skip.
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true"
proof_dir="$REPO/.quality/proof"
mkdir -p "$proof_dir"
(cd "$REPO" && CI=true SDLC_DEFAULT_BRANCH=main PROOF_DIR="$proof_dir" HOME="$HOME_DIR" SDLC_CONFIG_FILE="$REPO/sdlc.config.json" bash "$GATE" >/dev/null 2>&1) || true
OUTPUT=$(python3 -c "
import json
d = json.load(open('$proof_dir/plan.json'))
print(d.get('status','MISSING'), d.get('bypassed_via','null') or 'null')
")
assert_eq "CI=true → status=skip, bypassed_via=ci_environment" "skip" "ci_environment" "$OUTPUT"

# Also verify GITHUB_ACTIONS triggers the same path
REPO=$(make_repo "feature" "add feature")
HOME_DIR=$(make_plan_home)
write_config "$REPO" "true"
proof_dir="$REPO/.quality/proof"
mkdir -p "$proof_dir"
(cd "$REPO" && GITHUB_ACTIONS=true SDLC_DEFAULT_BRANCH=main PROOF_DIR="$proof_dir" HOME="$HOME_DIR" SDLC_CONFIG_FILE="$REPO/sdlc.config.json" bash "$GATE" >/dev/null 2>&1) || true
OUTPUT=$(python3 -c "
import json
d = json.load(open('$proof_dir/plan.json'))
print(d.get('status','MISSING'), d.get('bypassed_via','null') or 'null')
")
assert_eq "GITHUB_ACTIONS=true → status=skip, bypassed_via=ci_environment" "skip" "ci_environment" "$OUTPUT"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
