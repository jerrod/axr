#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# test_hooks.sh — Tests for hook scripts
# Sourced by test_therapist.sh — requires harness functions

# ─── rubber-band.sh tests ───────────────────────────────────

echo "--- rubber-band.sh ---"
echo ""

echo "Confront tier (0-4 incidents):"

setup
output=$(hook_write_json "This is pre-existing and already broken" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" 2>/dev/null)
assert_contains "catches rationalization phrase" "$output" "decision"
assert_contains "blocks with SNAP" "$output" "SNAP"
assert_contains "includes correction" "$output" "I own every file I touch"
teardown

setup
output=$(hook_edit_json "should be fine without tests" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" 2>/dev/null)
assert_contains "catches edit content too" "$output" "SNAP"
assert_contains "includes correction for should be fine" "$output" "Run verification"
teardown

echo ""
echo "Graduation: question tier (5+ incidents):"

setup
populate_journal 6 "ownership-avoidance"
output=$(hook_write_json "This is pre-existing code" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" 2>/dev/null)
assert_contains "question tier outputs COST-BENEFIT" "$output" "COST-BENEFIT"
assert_contains "question tier blocks" "$output" "decision"
teardown

echo ""
echo "Graduation: remind tier (10+ incidents):"

setup
populate_journal 12 "ownership-avoidance"
output=$(hook_write_json "This is pre-existing code" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" 2>/dev/null)
assert_contains "remind tier allows with context" "$output" "additionalContext"
assert_not_contains "remind tier does not block" "$output" '"decision":"block"'
teardown

echo ""
echo "Prediction logging:"

setup
hook_write_json "This is pre-existing code" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" >/dev/null 2>&1
journal_file="${TEST_DIR}/.therapist/journal.jsonl"
pred_count=$(grep -c '"type":"prediction"' "$journal_file" 2>/dev/null || echo "0")
assert_eq "logs prediction entry" "1" "$pred_count"
teardown

echo ""
echo "ABC-structured logging:"

setup
hook_write_json "This is pre-existing code" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" >/dev/null 2>&1
journal_file="${TEST_DIR}/.therapist/journal.jsonl"
abc_entry=$(grep '"type":"rationalization"' "$journal_file" | head -1)
assert_contains "logs activating_event" "$abc_entry" '"activating_event"'
assert_contains "logs belief" "$abc_entry" '"belief"'
assert_contains "logs consequence" "$abc_entry" '"consequence"'
teardown

echo ""
echo "Clean content:"

setup
exit_code=0
output=$(hook_write_json "This is perfectly clean code with no issues" "/tmp/test.py" | bash "${SCRIPT_DIR}/rubber-band.sh" 2>/dev/null) || exit_code=$?
assert_eq "clean content exits zero" "0" "$exit_code"
assert_eq "clean content produces no output" "" "$output"
teardown

echo ""

# ─── mirror.sh tests ────────────────────────────────────────

echo "--- mirror.sh ---"
echo ""

echo "Quality command failures:"

setup
output=$(hook_bash_json "bin/test" "FAILED 3 tests\n85%" | bash "${SCRIPT_DIR}/mirror.sh" 2>/dev/null)
assert_contains "detects test failures" "$output" "THE MIRROR"
assert_contains "reflects failure count" "$output" "failure"
teardown

echo ""
echo "Non-quality commands ignored:"

setup
exit_code=0
output=$(hook_bash_json "ls -la" "total 0" | bash "${SCRIPT_DIR}/mirror.sh" 2>/dev/null) || exit_code=$?
assert_eq "ignores non-quality command" "0" "$exit_code"
assert_eq "no output for non-quality" "" "$output"
teardown

echo ""
echo "Records measurements:"

setup
hook_bash_json "bin/test" "FAILED 2 tests\n85%" | bash "${SCRIPT_DIR}/mirror.sh" >/dev/null 2>&1
journal_file="${TEST_DIR}/.therapist/journal.jsonl"
meas_count=$(grep -c '"type":"measurement"' "$journal_file" 2>/dev/null || echo "0")
assert_eq "records measurement entries" "true" "$([ "$meas_count" -gt 0 ] && echo true || echo false)"
teardown

echo ""
echo "Successive approximation (progress tracking):"

setup
# First run: baseline
hook_bash_json "bin/test" "Coverage: 80%" | bash "${SCRIPT_DIR}/mirror.sh" >/dev/null 2>&1
# Second run: improvement
output=$(hook_bash_json "bin/test" "Coverage: 88%" | bash "${SCRIPT_DIR}/mirror.sh" 2>/dev/null)
assert_contains "tracks coverage progress" "$output" "Progress"
teardown

echo ""
echo "Regression detection:"

setup
# First run: baseline
hook_bash_json "bin/test" "Coverage: 90%" | bash "${SCRIPT_DIR}/mirror.sh" >/dev/null 2>&1
# Second run: regression
output=$(hook_bash_json "bin/test" "Coverage: 82%" | bash "${SCRIPT_DIR}/mirror.sh" 2>/dev/null)
assert_contains "detects regression" "$output" "REGRESSION"
journal_file="${TEST_DIR}/.therapist/journal.jsonl"
reg_count=$(grep -c '"type":"regression"' "$journal_file" 2>/dev/null || echo "0")
assert_eq "logs regression entry" "true" "$([ "$reg_count" -gt 0 ] && echo true || echo false)"
teardown

echo ""
echo "Resolves open predictions:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"prediction","trigger":"test","correction":"c","predicted":"pass","resolved":false,"category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(hook_bash_json "bin/test" "FAILED 1 test" | bash "${SCRIPT_DIR}/mirror.sh" 2>/dev/null)
journal_file="${TEST_DIR}/.therapist/journal.jsonl"
outcome_count=$(grep -c '"type":"outcome"' "$journal_file" 2>/dev/null || echo "0")
assert_eq "resolves predictions to outcomes" "true" "$([ "$outcome_count" -gt 0 ] && echo true || echo false)"
teardown

echo ""

# ─── reframe.sh tests ───────────────────────────────────────

echo "--- reframe.sh ---"
echo ""

echo "Command repetition:"

setup
# Run same command 3 times
hook_bash_json "bin/test" "ok" | bash "${SCRIPT_DIR}/reframe.sh" >/dev/null 2>&1
hook_bash_json "bin/test" "ok" | bash "${SCRIPT_DIR}/reframe.sh" >/dev/null 2>&1
output=$(hook_bash_json "bin/test" "ok" | bash "${SCRIPT_DIR}/reframe.sh" 2>/dev/null)
assert_contains "detects repeated commands" "$output" "REFRAME"
assert_contains "mentions attempt number" "$output" "attempt"
teardown

echo ""
echo "Impossibility language:"

setup
output=$(hook_bash_json "pip install foo" "ERROR: No such module. not found." | bash "${SCRIPT_DIR}/reframe.sh" 2>/dev/null)
assert_contains "detects impossibility language" "$output" "REFRAME"
assert_contains "reframes constraint" "$output" "constraint"
teardown

echo ""
echo "Overwhelming output:"

setup
# Generate 120 lines of output
big_output=$(printf 'error line %s\n' $(seq 1 120))
output=$(hook_bash_json "bin/lint" "$big_output" | bash "${SCRIPT_DIR}/reframe.sh" 2>/dev/null)
assert_contains "detects overwhelming output" "$output" "REFRAME"
assert_contains "mentions line count" "$output" "lines"
teardown

echo ""
echo "Decatastrophizing with evidence:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Pre-populate with frustration pattern and resolution
printf '{"ts":"%s","type":"frustration-pattern","trigger":"bin/test","correction":"c"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"activation","trigger":"recovery","correction":"c"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
# Trigger repetition
echo "bin/test" >>"${TEST_DIR}/.therapist/cmd-history"
echo "bin/test" >>"${TEST_DIR}/.therapist/cmd-history"
output=$(hook_bash_json "bin/test" "ok" | bash "${SCRIPT_DIR}/reframe.sh" 2>/dev/null)
assert_contains "appends evidence from journal" "$output" "EVIDENCE"
teardown

echo ""
echo "Socratic questions on cold start:"

setup
output=$(hook_bash_json "pip install foo" "ERROR: not found. impossible to resolve." | bash "${SCRIPT_DIR}/reframe.sh" 2>/dev/null)
assert_contains "appends Socratic questions on cold start" "$output" "constraint"
teardown

echo ""

# ─── pause.sh tests ──────────────────────────────────────────

echo "--- pause.sh ---"
echo ""

echo "Blocks commit with regressions:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"regression","trigger":"bin/test","correction":"coverage dropped","source":"mirror","metric":"coverage","value":80}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(hook_commit_json "git commit -m test" | bash "${SCRIPT_DIR}/pause.sh" 2>/dev/null)
assert_contains "blocks commit with regression" "$output" "regression"
assert_contains "blocks with decision" "$output" "block"
teardown

echo ""
echo "Allows commit with no gaps:"

setup
# No journal entries, no proof dir issues
exit_code=0
output=$(hook_commit_json "git commit -m test" | bash "${SCRIPT_DIR}/pause.sh" 2>/dev/null) || exit_code=$?
assert_eq "allows commit with no gaps" "0" "$exit_code"
teardown

echo ""

# ─── socratic.sh tests ──────────────────────────────────────

echo "--- socratic.sh ---"
echo ""

echo "Detects TODO/FIXME:"

setup
# Clear cooldown
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "def foo():\n    # TODO: fix this later\n    pass" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "detects TODO marker" "$output" "SOCRATIC"
assert_contains "asks about TODO" "$output" "TODO/FIXME"
teardown

echo ""
echo "Detects lint suppressions:"

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "x = 1  # noqa: E501" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "detects noqa suppression" "$output" "SOCRATIC"
assert_contains "asks about lint suppression" "$output" "lint suppression"
teardown

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "// eslint-disable-next-line no-unused-vars" "/tmp/test.js" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "detects eslint-disable" "$output" "SOCRATIC"
teardown

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "// @ts-ignore\nconst x: any = 1;" "/tmp/test.ts" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "detects ts-ignore" "$output" "SOCRATIC"
teardown

echo ""
echo "Detects broad exceptions:"

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "try:\n    do_stuff()\nexcept:\n    pass" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "detects bare except" "$output" "SOCRATIC"
assert_contains "asks about exceptions" "$output" "exception"
teardown

echo ""
echo "Respects 5-minute cooldown:"

setup
# Write a recent cooldown timestamp
date +%s >"${TEST_DIR}/.therapist/socratic-last"
exit_code=0
output=$(hook_write_json "# TODO: fix later" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null) || exit_code=$?
assert_eq "cooldown silences socratic" "0" "$exit_code"
assert_eq "cooldown produces no output" "" "$output"
teardown

echo ""
echo "Outputs questions (not blocks):"

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
output=$(hook_write_json "# TODO: implement" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null)
assert_contains "outputs additionalContext not block" "$output" "additionalContext"
assert_not_contains "does not output decision:block" "$output" '"decision":"block"'
teardown

echo ""
echo "Clean content exits silently:"

setup
rm -f "${TEST_DIR}/.therapist/socratic-last"
exit_code=0
output=$(hook_write_json "def clean_function():\n    return 42" "/tmp/test.py" | bash "${SCRIPT_DIR}/socratic.sh" 2>/dev/null) || exit_code=$?
assert_eq "clean content exits zero" "0" "$exit_code"
assert_eq "clean content no output" "" "$output"
teardown

echo ""

# ─── activate.sh tests ──────────────────────────────────────

echo "--- activate.sh ---"
echo ""

echo "Detects passing quality commands:"

setup
rm -f "${TEST_DIR}/.therapist/activate-last"
output=$(hook_bash_json "bin/test" "All 42 tests passed" | bash "${SCRIPT_DIR}/activate.sh" 2>/dev/null)
assert_contains "detects passing quality command" "$output" "ACTIVATION"
teardown

echo ""
echo "Ignores failing commands:"

setup
rm -f "${TEST_DIR}/.therapist/activate-last"
exit_code=0
output=$(hook_bash_json "bin/test" "FAILED 3 tests" | bash "${SCRIPT_DIR}/activate.sh" 2>/dev/null) || exit_code=$?
assert_eq "ignores failing command" "0" "$exit_code"
assert_eq "no output for failing command" "" "$output"
teardown

echo ""
echo "Respects 10-minute cooldown:"

setup
# Set recent cooldown
date +%s >"${TEST_DIR}/.therapist/activate-last"
exit_code=0
output=$(hook_bash_json "bin/test" "All tests passed" | bash "${SCRIPT_DIR}/activate.sh" 2>/dev/null) || exit_code=$?
assert_eq "cooldown silences activate" "0" "$exit_code"
assert_eq "cooldown produces no output" "" "$output"
teardown

echo ""

# ─── affirmation.sh tests ────────────────────────────────────

echo "--- affirmation.sh ---"
echo ""

echo "Fresh session message:"

setup
output=$(bash "${SCRIPT_DIR}/affirmation.sh" 2>/dev/null)
assert_contains "fresh session affirmation" "$output" "Fresh session"
assert_contains "session note header" "$output" "THERAPIST SESSION NOTE"
teardown

echo ""
echo "Risk profile with populated journal:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for _ in 1 2 3 4; do
  printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"CSS debug","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
done
output=$(bash "${SCRIPT_DIR}/affirmation.sh" 2>/dev/null)
assert_contains "affirmation includes risk profile" "$output" "RISK"
teardown

echo ""
echo "Updates streak file:"

setup
bash "${SCRIPT_DIR}/affirmation.sh" >/dev/null 2>&1
assert_eq "streak file created" "true" "$([ -f "${TEST_DIR}/.therapist/streak.json" ] && echo true || echo false)"
streak_val=$(jq -r '.consecutive_clean_sessions' "${TEST_DIR}/.therapist/streak.json" 2>/dev/null || echo "missing")
assert_eq "streak starts at 1 for fresh session" "1" "$streak_val"
teardown

echo ""
