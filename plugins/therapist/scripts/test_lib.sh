#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# test_lib.sh — Tests for _lib.sh functions
# Sourced by test_therapist.sh — requires harness functions

echo "--- _lib.sh ---"
echo ""

echo "escape_for_json:"

setup
source "${SCRIPT_DIR}/_lib.sh"
result=$(escape_for_json 'hello "world"')
assert_eq "escapes double quotes" 'hello \"world\"' "$result"
teardown

setup
source "${SCRIPT_DIR}/_lib.sh"
result=$(escape_for_json $'line1\nline2')
assert_eq "escapes newlines" 'line1\nline2' "$result"
teardown

setup
source "${SCRIPT_DIR}/_lib.sh"
result=$(escape_for_json $'has\ttab')
assert_eq "escapes tabs" 'has\ttab' "$result"
teardown

echo ""
echo "journal_log (basic):"

setup
source "${SCRIPT_DIR}/_lib.sh"
journal_log "rationalization" "test trigger" "test correction"
assert_eq "journal file created" "1" "$(wc -l <"${TEST_DIR}/.therapist/journal.jsonl" | tr -d ' ')"
line=$(cat "${TEST_DIR}/.therapist/journal.jsonl")
assert_contains "entry has type" "$line" '"type":"rationalization"'
assert_contains "entry has trigger" "$line" '"trigger":"test trigger"'
assert_contains "entry has correction" "$line" '"correction":"test correction"'
teardown

echo ""
echo "journal_log (ABC fields):"

setup
source "${SCRIPT_DIR}/_lib.sh"
journal_log "rationalization" "trig" "corr" --phrase="phrase1" --source="src1" --event="event1" --belief="belief1" --consequence="consequence1" --category="cat1"
line=$(cat "${TEST_DIR}/.therapist/journal.jsonl")
assert_contains "entry has activating_event" "$line" '"activating_event":"event1"'
assert_contains "entry has belief" "$line" '"belief":"belief1"'
assert_contains "entry has consequence" "$line" '"consequence":"consequence1"'
assert_contains "entry has category" "$line" '"category":"cat1"'
teardown

echo ""
echo "journal_log (prediction fields):"

setup
source "${SCRIPT_DIR}/_lib.sh"
journal_log "prediction" "trig" "corr" --predicted="pass" --resolved="false"
line=$(cat "${TEST_DIR}/.therapist/journal.jsonl")
assert_contains "entry has predicted" "$line" '"predicted":"pass"'
assert_contains "entry has resolved false" "$line" '"resolved":false'
teardown

echo ""
echo "journal_stats:"

setup
source "${SCRIPT_DIR}/_lib.sh"
journal_log "rationalization" "t1" "c1"
journal_log "rationalization" "t2" "c2"
journal_log "quality-failure" "t3" "c3"
output=$(journal_stats)
assert_contains "stats counts rationalization" "$output" "rationalization: 2"
assert_contains "stats counts quality-failure" "$output" "quality-failure: 1"
assert_contains "stats shows total" "$output" "Total: 3"
teardown

echo ""
echo "check_cooldown:"

setup
source "${SCRIPT_DIR}/_lib.sh"
check_cooldown "test-tool" 300
exit_code=0
check_cooldown "test-tool" 300 || exit_code=$?
assert_eq "within cooldown returns 1" "1" "$exit_code"
teardown

setup
source "${SCRIPT_DIR}/_lib.sh"
# Write a timestamp 400 seconds in the past
echo $(($(date +%s) - 400)) >"${TEST_DIR}/.therapist/test-tool-last"
exit_code=0
check_cooldown "test-tool" 300 || exit_code=$?
assert_eq "after cooldown returns 0" "0" "$exit_code"
teardown

echo ""
echo "journal_category_counts:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
journal_log "rat" "t" "c" --category="ownership-avoidance"
journal_log "rat" "t" "c" --category="ownership-avoidance"
journal_log "rat" "t" "c" --category="premature-closure"
output=$(journal_category_counts)
assert_contains "category counts ownership" "$output" "ownership-avoidance:2"
assert_contains "category counts premature" "$output" "premature-closure:1"
teardown

echo ""
echo "journal_open_predictions:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
# Add an unresolved prediction with current timestamp
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"prediction","trigger":"test","correction":"c","predicted":"pass","resolved":false}\n' "$ts" \
  >>"${TEST_DIR}/.therapist/journal.jsonl"
# Add a resolved prediction (should be excluded)
printf '{"ts":"%s","type":"prediction","trigger":"done","correction":"c","predicted":"pass","resolved":true}\n' "$ts" \
  >>"${TEST_DIR}/.therapist/journal.jsonl"
# Add an expired prediction (2 hours ago, should be excluded)
old_ts=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
printf '{"ts":"%s","type":"prediction","trigger":"old","correction":"c","predicted":"pass","resolved":false}\n' "$old_ts" \
  >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(journal_open_predictions)
assert_contains "open predictions includes unresolved" "$output" '"trigger": "test"'
assert_not_contains "open predictions excludes resolved" "$output" '"trigger": "done"'
teardown

echo ""
echo "journal_prediction_accuracy:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 2 correct, 1 wrong = 66%
{
  printf '{"ts":"%s","type":"outcome","trigger":"t","correction":"c","predicted":"pass","actual":"pass","detail":"test1"}\n' "$ts"
  printf '{"ts":"%s","type":"outcome","trigger":"t","correction":"c","predicted":"pass","actual":"pass","detail":"test2"}\n' "$ts"
  printf '{"ts":"%s","type":"outcome","trigger":"t","correction":"c","predicted":"pass","actual":"fail","detail":"test3"}\n' "$ts"
} >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(journal_prediction_accuracy "" "7d")
assert_contains "prediction accuracy percentage" "$output" "66%"
assert_contains "prediction accuracy ratio" "$output" "2/3"
teardown

echo ""
echo "journal_last_measurement:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"measurement","trigger":"t","correction":"c","metric":"coverage","value":85,"target":95}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"measurement","trigger":"t","correction":"c","metric":"coverage","value":90,"target":95}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(journal_last_measurement "coverage")
assert_contains "last measurement returns most recent value" "$output" "90|95"
teardown

echo ""
echo "journal_resolution_rate:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"frustration-pattern","trigger":"t","correction":"c"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"activation","trigger":"t","correction":"c"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(journal_resolution_rate "frustration-pattern")
assert_contains "resolution rate has percentage" "$output" "%"
assert_contains "resolution rate has ratio" "$output" "/"
teardown

echo ""
echo "journal_cost_summary:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","type":"rationalization","trigger":"t","correction":"c","source":"pause","category":"ownership-avoidance"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
printf '{"ts":"%s","type":"quality-failure","trigger":"t","correction":"c","category":"ownership-avoidance"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
output=$(journal_cost_summary "ownership-avoidance")
assert_contains "cost summary has blocked commits" "$output" "1|"
teardown

echo ""
echo "journal_risk_profile:"

setup
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Need 3+ entries with same event-category correlation for risk detection
for _ in 1 2 3 4; do
  printf '{"ts":"%s","type":"rat","trigger":"t","correction":"c","activating_event":"debugging CSS","category":"premature-closure"}\n' "$ts" >>"${TEST_DIR}/.therapist/journal.jsonl"
done
output=$(journal_risk_profile)
assert_contains "risk profile detects event-category correlation" "$output" "RISK"
assert_contains "risk profile names category" "$output" "premature-closure"
assert_contains "risk profile names event" "$output" "debugging CSS"
teardown

echo ""
