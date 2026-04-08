#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# reframe.sh — PostToolUse hook for Bash
#
# Detects frustration patterns: repeated commands, impossibility language,
# overwhelming output. Injects cognitive reframes.
# Enhanced with decatastrophizing: appends resolution evidence from journal
# history, or generic Socratic questions on cold start.
#
# Input: JSON on stdin with tool_input.command and tool_output
# Output: JSON with additionalContext when patterns detected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"

ensure_therapist_dir

INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
OUTPUT=$(printf '%s' "$INPUT" | jq -r '.tool_output // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Skip innocuous commands that shouldn't trigger frustration detection
if printf '%s' "$COMMAND" | grep -qE '^(ls|cat|head|tail|echo|cd|pwd|wc|which|env|whoami|date|uname|id|true|false)( |$)'; then
  exit 0
fi

HISTORY_FILE="${THERAPIST_DIR}/cmd-history"
REFRAME=""
PATTERN_TYPE=""

# --- Pattern 1: Command repetition ---

check_repetition() {
  touch "$HISTORY_FILE"
  printf '%s\n' "$COMMAND" >>"$HISTORY_FILE"

  # Keep only last 20 commands
  tail -20 "$HISTORY_FILE" >"${HISTORY_FILE}.tmp"
  mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"

  local count
  count=$(grep -cxF "$COMMAND" "$HISTORY_FILE" || true)

  if [[ "$count" -ge 3 ]]; then
    REFRAME="REFRAME: This is attempt #${count}."
    REFRAME+=" Each error teaches something different."
    REFRAME+=" What changed between attempts?"
    PATTERN_TYPE="repetition"
  fi
}

# --- Pattern 2: Impossibility language ---

check_impossibility() {
  if [[ -n "$REFRAME" ]]; then
    return
  fi

  if printf '%s' "$OUTPUT" | grep -qiE '(not fixable|impossible to|cannot be (resolved|fixed|done)|no such (file|module|command)|command not found)'; then
    REFRAME="REFRAME: This constraint is information"
    REFRAME+=" about what approach to try next,"
    REFRAME+=" not a dead end."
    PATTERN_TYPE="impossibility"
  fi
}

# --- Pattern 3: Overwhelming output ---

check_overwhelm() {
  if [[ -n "$REFRAME" ]]; then
    return
  fi

  local line_count
  line_count=$(printf '%s' "$OUTPUT" | wc -l | tr -d ' ')

  if [[ "$line_count" -gt 100 ]]; then
    REFRAME="REFRAME: ${line_count} lines of output."
    REFRAME+=" Pause. Read the FIRST error, not all of them."
    REFRAME+=" Fix one thing at a time."
    PATTERN_TYPE="overwhelm"
  fi
}

check_repetition
check_impossibility
check_overwhelm

if [[ -z "$REFRAME" ]]; then
  exit 0
fi

# --- Decatastrophizing: add evidence layer ---

add_decatastrophize() {
  local resolution_data
  resolution_data=$(journal_resolution_rate "frustration-pattern" 2>/dev/null || echo "no_data")

  if [[ "$resolution_data" != "no_data" ]]; then
    IFS='|' read -r pct ratio <<<"$resolution_data"
    REFRAME+=" EVIDENCE: You've encountered this pattern before."
    REFRAME+=" Resolution rate: ${pct} (${ratio})."
    REFRAME+=" The pattern says this is solvable."
  else
    # Cold start: generic decatastrophize questions per pattern type
    case "$PATTERN_TYPE" in
      impossibility)
        REFRAME+=" What specifically makes this impossible?"
        REFRAME+=" Name the constraint. Constraints have workarounds."
        ;;
      repetition)
        REFRAME+=" What's different about the error this time vs. last time?"
        ;;
      overwhelm)
        REFRAME+=" How many *unique* errors are in this output?"
        REFRAME+=" Usually it's 1-3 root causes."
        ;;
    esac
  fi
}

add_decatastrophize

# Log to journal with ABC structure
bash "${SCRIPT_DIR}/journal.sh" log \
  "frustration-pattern" \
  "$(printf '%s' "$COMMAND" | cut -c1-80)" \
  "$REFRAME" \
  --source=reframe \
  --event="command execution" \
  --belief="${PATTERN_TYPE} detected" \
  --consequence="frustration pattern active" \
  --category="frustration-${PATTERN_TYPE}" 2>/dev/null || true

# Log prediction for behavioral experiment
bash "${SCRIPT_DIR}/journal.sh" log \
  "prediction" \
  "${PATTERN_TYPE}" \
  "Agent may give up or repeat without change" \
  --source=reframe \
  --category="frustration-${PATTERN_TYPE}" \
  --predicted="fail" \
  --resolved=false 2>/dev/null || true

# Output hook response
jq -n --arg ctx "$REFRAME" '{hookSpecificOutput: {additionalContext: $ctx}}'
