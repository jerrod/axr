#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# test_journal.sh — Tests for journal.sh subcommands
# Sourced by test_therapist.sh — requires harness functions

echo "--- journal.sh ---"
echo ""

echo "log subcommand:"

setup
output=$(bash "${SCRIPT_DIR}/journal.sh" log rationalization "test trigger" "test correction" --phrase="should be fine" --source=test --event="editing foo" --category="premature-closure")
assert_contains "log prints confirmation" "$output" "Logged: rationalization"
line=$(cat "${TEST_DIR}/.therapist/journal.jsonl")
assert_contains "log creates entry with phrase" "$line" '"phrase":"should be fine"'
assert_contains "log creates entry with category" "$line" '"category":"premature-closure"'
teardown

echo ""
echo "recent subcommand:"

setup
bash "${SCRIPT_DIR}/journal.sh" log rationalization "trigger1" "correction1" >/dev/null 2>&1
bash "${SCRIPT_DIR}/journal.sh" log quality-failure "trigger2" "correction2" >/dev/null 2>&1
output=$(bash "${SCRIPT_DIR}/journal.sh" recent 5)
assert_contains "recent shows entries" "$output" "trigger1"
assert_contains "recent shows both entries" "$output" "trigger2"
teardown

echo ""
echo "stats subcommand:"

setup
bash "${SCRIPT_DIR}/journal.sh" log rationalization "t1" "c1" >/dev/null 2>&1
bash "${SCRIPT_DIR}/journal.sh" log rationalization "t2" "c2" >/dev/null 2>&1
output=$(bash "${SCRIPT_DIR}/journal.sh" stats)
assert_contains "stats shows counts" "$output" "rationalization: 2"
teardown

echo ""
echo "streak subcommand:"

setup
bash "${SCRIPT_DIR}/journal.sh" log rationalization "t1" "c1" >/dev/null 2>&1
output=$(bash "${SCRIPT_DIR}/journal.sh" streak)
assert_contains "streak shows days since" "$output" "rationalization"
assert_contains "streak shows day count" "$output" "day(s)"
teardown

echo ""
echo "chain subcommand:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"editing foo","belief":"should be fine","consequence":"skipped test","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"editing bar","belief":"close enough","consequence":"skipped lint","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(bash "${SCRIPT_DIR}/journal.sh" chain "premature-closure")
assert_contains "chain shows downward arrow header" "$output" "DOWNWARD ARROW"
assert_contains "chain shows category" "$output" "premature-closure"
assert_contains "chain shows session" "$output" "Session"
teardown

echo ""
echo "abc subcommand:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"debugging CSS","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"debugging CSS","category":"ownership-avoidance"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(bash "${SCRIPT_DIR}/journal.sh" abc --group-by=event)
assert_contains "abc groups by event" "$output" "debugging CSS"
assert_contains "abc shows analysis header" "$output" "ABC Analysis"
teardown

echo ""
echo "exemplar subcommand:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Tier 1: journal activation entry
printf '{"ts":"%s","type":"activation","trigger":"ran bin/test proactively","correction":"good","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(bash "${SCRIPT_DIR}/journal.sh" exemplar "premature-closure")
assert_contains "exemplar finds journal tier" "$output" "From your history"
teardown

setup
# Tier fallback: no data at all
output=$(bash "${SCRIPT_DIR}/journal.sh" exemplar "nonexistent-category" 2>/dev/null || true)
# Should return empty or fall through
assert_eq "exemplar returns empty for unknown category" "" "$output"
teardown

echo ""
echo "risk-profile subcommand:"

setup
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for _ in 1 2 3 4; do
  printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"CSS work","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
done
output=$(bash "${SCRIPT_DIR}/journal.sh" risk-profile)
assert_contains "risk-profile outputs risk data" "$output" "RISK"
teardown

echo ""
