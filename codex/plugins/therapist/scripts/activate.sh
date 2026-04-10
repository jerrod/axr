#!/usr/bin/env bash
# activate.sh — PostToolUse hook for Bash (async)
#
# Behavioral activation: detects positive signals and provides
# reinforcement. Celebrates proactive quality checks and recovery
# from failures.
#
# Proactive = quality command run without a preceding commit attempt
# in recent command history.
#
# 10-minute cooldown, escalating brevity after 5+ activations per session.
#
# Input: JSON on stdin with tool_input.command and tool_output
# Output: JSON with additionalContext on positive signal, silent exit otherwise

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/_lib.sh"

ensure_therapist_dir

INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
OUTPUT=$(printf '%s' "$INPUT" | jq -r '.tool_output // ""')

if ! is_quality_command "$COMMAND"; then
  exit 0
fi

if has_failure "$OUTPUT"; then
  exit 0
fi

# Determine activation type
ACTIVATION_TYPE=""
ACTIVATION_MSG=""

# Check if this is recovery (previous mirror failure exists in journal)
check_recovery() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "$journal_file" ]]; then
    return 1
  fi

  JF="${journal_file}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
one_hour_ago = now - timedelta(hours=1)

has_recent_failure = False
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') == 'quality-failure':
                ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
                if ts >= one_hour_ago:
                    has_recent_failure = True
        except (json.JSONDecodeError, ValueError, KeyError):
            continue

exit(0 if has_recent_failure else 1)
" 2>/dev/null
}

# Check if this is proactive (no recent commit attempt in cmd-history)
check_proactive() {
  local history_file="${THERAPIST_DIR}/cmd-history"
  if [[ ! -f "$history_file" ]]; then
    return 0
  fi

  # Check last 5 commands for commit/push attempts
  if tail -5 "$history_file" | grep -qE '^git (commit|push)'; then
    return 1
  fi
  return 0
}

if check_recovery 2>/dev/null; then
  ACTIVATION_TYPE="recovery"
  ACTIVATION_MSG="ACTIVATION: Fixed and verified. Recovery from failure is the skill that matters most."
elif check_proactive; then
  ACTIVATION_TYPE="proactive-gate"
  ACTIVATION_MSG="ACTIVATION: Proactive quality check — passing."
else
  exit 0
fi

# Check cooldown (10 minutes = 600 seconds) only after confirming activation
if ! check_cooldown "activate" 600; then
  exit 0
fi

# Count session activations for escalating brevity
SESSION_COUNT=0
JOURNAL_FILE="${THERAPIST_DIR}/journal.jsonl"
if [[ -f "$JOURNAL_FILE" ]]; then
  SESSION_COUNT=$(JF="${JOURNAL_FILE}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
session_start = now - timedelta(hours=4)
count = 0

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') == 'activation':
                ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
                if ts >= session_start:
                    count += 1
        except (json.JSONDecodeError, ValueError, KeyError):
            continue

print(count)
" 2>/dev/null || echo "0")
fi

TOTAL=$((SESSION_COUNT + 1))

# Escalating brevity
if [[ "$TOTAL" -gt 5 ]]; then
  ACTIVATION_MSG="ACTIVATION: +1 (${TOTAL} this session)."
elif [[ "$TOTAL" -gt 1 ]]; then
  ACTIVATION_MSG="${ACTIVATION_MSG} That's ${TOTAL} positive actions this session."
fi

# Read streak data
STREAK_FILE="${THERAPIST_DIR}/streak.json"
if [[ -f "$STREAK_FILE" ]]; then
  STREAK=$(jq -r '.consecutive_clean_sessions // 0' "$STREAK_FILE" 2>/dev/null || echo "0")
  if [[ "$STREAK" -gt 1 ]]; then
    ACTIVATION_MSG+=" ${STREAK} consecutive clean sessions."
  fi
fi

# Log to journal
bash "${SCRIPT_DIR}/journal.sh" log \
  "activation" \
  "${ACTIVATION_TYPE}" \
  "${ACTIVATION_MSG}" \
  --source=activate \
  --event="quality gate run" \
  --category="positive-behavior" 2>/dev/null || true

# Output hook response
jq -n --arg ctx "$ACTIVATION_MSG" '{hookSpecificOutput: {additionalContext: $ctx}}'
