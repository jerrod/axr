#!/usr/bin/env bash
# Tests for gate-coverage.sh vacuous-pass and skip detection
# Verifies skip on doc-only changes and fail when coverage paths don't match
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate-coverage.sh"

PASS=0
FAIL=0

TMPDIRS=()
TMP_REPO=""
cleanup() {
  # Guard empty-array expansion under set -u
  for d in "${TMPDIRS[@]:-}"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# Create a minimal git repo with configurable changed files on a feature branch
make_repo_with_src() {
  local src_file="$1"
  TMP_REPO=$(mktemp -d)
  TMPDIRS+=("$TMP_REPO")
  cd "$TMP_REPO"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"

  # Initial commit on main
  git checkout -q -b main
  echo "# init" >README.md
  git add README.md
  git commit -q -m "init"

  # Feature branch
  git checkout -q -b feature
  mkdir -p "$(dirname "$src_file")"
  echo "placeholder content" >"$src_file"
  git add "$src_file"
  git commit -q -m "add file"

  cd - >/dev/null
}

# Run gate-coverage.sh in the repo, capture proof JSON fields
# Prints: "status files_checked files_matched reason"
run_gate() {
  local repo="$1"
  local proof_dir="$repo/.quality/proof"
  mkdir -p "$proof_dir"

  cd "$repo"
  SDLC_DEFAULT_BRANCH=main PROOF_DIR="$proof_dir" bash "$GATE" >/dev/null 2>&1 || true

  python3 -c "
import json, sys
try:
    d = json.load(open('$proof_dir/coverage.json'))
    status = d.get('status', 'MISSING')
    checked = d.get('files_checked', -1)
    matched = d.get('files_matched', -1)
    reason = d.get('reason', '')
    print(status, checked, matched, reason)
except Exception as e:
    print('ERROR', -1, -1, str(e))
"
  cd - >/dev/null
}

# ─── Test 1: Doc-only change (README) → status=skip ─────────────────────────
make_repo_with_src "README.md"
output=$(run_gate "$TMP_REPO")
status=$(echo "$output" | awk '{print $1}')
if [ "$status" = "skip" ]; then
  echo "PASS: doc-only change => skip"
  PASS=$((PASS + 1))
else
  echo "FAIL: doc-only change => expected skip, got status=$status"
  FAIL=$((FAIL + 1))
fi

# ─── Test 2: Java source + JaCoCo XML with mismatched paths ─────────────────
# Expected: status=fail, files_checked>0, files_matched==0
# The Java source is in the JaCoCo extension set but its class path does
# not match anything the coverage report knows about → vacuous fail.
make_repo_with_src "src/main/java/com/example/Foo.java"

# Write a JaCoCo XML that references a completely different Java file
mkdir -p "$TMP_REPO/build/reports/jacoco/test"
cat >"$TMP_REPO/build/reports/jacoco/test/jacocoTestReport.xml" <<'COVEOF'
<?xml version="1.0" encoding="UTF-8"?>
<report name="test">
  <package name="com/other">
    <class name="com/other/Bar" sourcefilename="Bar.java">
      <counter type="LINE" missed="0" covered="10"/>
    </class>
    <sourcefile name="Bar.java">
      <counter type="LINE" missed="0" covered="10"/>
    </sourcefile>
  </package>
</report>
COVEOF
cd "$TMP_REPO"
git add build/reports/jacoco/test/jacocoTestReport.xml
git commit -q -m "add jacoco coverage with mismatched paths"
cd - >/dev/null

output=$(run_gate "$TMP_REPO")
status=$(echo "$output" | awk '{print $1}')
checked=$(echo "$output" | awk '{print $2}')
matched=$(echo "$output" | awk '{print $3}')

if [ "$status" = "fail" ] && [ "$checked" -gt 0 ] && [ "$matched" -eq 0 ]; then
  echo "PASS: Java src + mismatched coverage => fail (checked=$checked, matched=$matched)"
  PASS=$((PASS + 1))
else
  echo "FAIL: Java src + mismatched coverage => expected fail/checked>0/matched=0, got status=$status checked=$checked matched=$matched"
  FAIL=$((FAIL + 1))
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
