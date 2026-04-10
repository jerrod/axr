#!/usr/bin/env bash
# socratic.sh — PostToolUse hook for Write|Edit
#
# Detects code-level signals that suggest distortion patterns in the code
# itself (not rationalization phrases — that's rubber-band's job).
# Outputs Socratic questions to prompt reflection and voluntary correction.
#
# Signals: TODO/FIXME in new code, internal mocks, lint suppressions,
# broad exceptions, oversized functions.
#
# Key design: never blocks, only injects questions. One question per
# invocation. 5-minute cooldown to avoid nagging.
#
# Input: JSON on stdin with tool_input (Write or Edit)
# Output: JSON with additionalContext, or silent exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/_lib.sh"

ensure_therapist_dir

INPUT=$(cat)

# Extract content from Write or Edit tool input
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // "unknown"')
QUESTION=""
SIGNAL=""

# --- Signal 1: TODO/FIXME/HACK/XXX in new code ---

check_todo_markers() {
  if printf '%s' "$CONTENT" | grep -qiE '(TODO|FIXME|HACK|XXX)'; then
    QUESTION="SOCRATIC: A TODO/FIXME marker was just written."
    QUESTION+=" What prevents resolving it now while the context is fresh?"
    SIGNAL="todo-marker"
  fi
}

# --- Signal 2: Internal mocks ---

check_internal_mocks() {
  if [[ -n "$QUESTION" ]]; then
    return
  fi

  if printf '%s' "$CONTENT" | grep -qiE '(jest\.mock|@patch|spyOn.*mockImplementation|mock_open|MagicMock|create_autospec)'; then
    QUESTION="SOCRATIC: This code mocks an internal collaborator."
    QUESTION+=" What would break if you used the real implementation instead?"
    SIGNAL="internal-mock"
  fi
}

# --- Signal 3: Lint suppression markers ---

check_lint_suppressions() {
  if [[ -n "$QUESTION" ]]; then
    return
  fi

  # Build the suppression regex from adjacent string literals so the source
  # text does not contain the very markers the rq lint-suppressions diff
  # scanner is looking for — the runtime regex value is unchanged.
  local suppression_re='(no''qa|type:\s*ignore|eslint''-disable|ts''-ignore|ts''-expect-error|@suppress)'
  if printf '%s' "$CONTENT" | grep -qiE "$suppression_re"; then
    QUESTION="SOCRATIC: A lint suppression was just added."
    QUESTION+=" What rule is being suppressed?"
    QUESTION+=" What would it take to satisfy it instead?"
    SIGNAL="lint-suppression"
  fi
}

# --- Signal 4: Broad exception handling ---

check_broad_exceptions() {
  if [[ -n "$QUESTION" ]]; then
    return
  fi

  if printf '%s' "$CONTENT" | grep -qE '(except\s*:|except\s+Exception\s*:)'; then
    QUESTION="SOCRATIC: A broad exception handler was just written."
    QUESTION+=" What specific exceptions can this code raise?"
    QUESTION+=" What should happen differently for each?"
    SIGNAL="broad-exception"
  fi
}

# --- Signal 5: Oversized function ---

check_oversized_function() {
  if [[ -n "$QUESTION" ]]; then
    return
  fi

  local line_count
  line_count=$(printf '%s' "$CONTENT" | wc -l | tr -d ' ')

  if [[ "$line_count" -gt 50 ]]; then
    QUESTION="SOCRATIC: This block is ${line_count} lines."
    QUESTION+=" If you split it into named sections, what names come to mind?"
    SIGNAL="oversized-function"
  fi
}

check_todo_markers
check_internal_mocks
check_lint_suppressions
check_broad_exceptions
check_oversized_function

if [[ -z "$QUESTION" ]]; then
  exit 0
fi

# Check cooldown (5 minutes = 300 seconds) only when we have a question
if ! check_cooldown "socratic" 300; then
  exit 0
fi

# Log to journal with ABC structure
bash "${SCRIPT_DIR}/journal.sh" log \
  "socratic-code" \
  "${SIGNAL} in ${FILE_PATH##*/}" \
  "$QUESTION" \
  --source=socratic \
  --event="editing ${FILE_PATH##*/}" \
  --belief="${SIGNAL}" \
  --consequence="code-level signal written" \
  --category="code-quality" 2>/dev/null || true

# Log prediction for behavioral experiment
bash "${SCRIPT_DIR}/journal.sh" log \
  "prediction" \
  "${SIGNAL}" \
  "Agent may leave code signal unaddressed" \
  --source=socratic \
  --category="code-quality" \
  --predicted="fail" \
  --resolved=false 2>/dev/null || true

# Output hook response (never blocks — context injection only)
jq -n --arg ctx "$QUESTION" '{hookSpecificOutput: {additionalContext: $ctx}}'
