#!/usr/bin/env bash
# pause.sh — PreToolUse hook for Bash(git commit*)|Bash(git push*)
#
# Checks evidence that verification was done before allowing commit/push.
# Looks for: recent gate proofs, rubber-band snaps today, test file coverage.
#
# Input: JSON on stdin with tool_input.command
# Output: block JSON if evidence gaps found, silent exit if all clear

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/_lib.sh"

ensure_therapist_dir

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only act on commit and push commands
if ! printf '%s' "$COMMAND" | grep -qE '^git (commit|push)'; then
  exit 0
fi

GAPS=()

# --- Check 1: Recent gate proofs ---

check_gate_proofs() {
  local proof_dir="${THERAPIST_PROOF_DIR:-${REPO_ROOT}/.quality/proof}"
  if [[ ! -d "$proof_dir" ]]; then
    # Skip this check if no proof directory exists (rq plugin may not be installed)
    return
  fi

  local recent_files
  recent_files=$(find "$proof_dir" -type f -mmin -30 2>/dev/null | head -1)
  if [[ -z "$recent_files" ]]; then
    GAPS+=("No gate proofs from the last 30 minutes — re-run gates")
  fi
}

# --- Check 2: Rubber-band snaps today ---

check_snaps_today() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "$journal_file" ]]; then
    return
  fi

  local today
  today=$(date -u +%Y-%m-%d)
  local today_snaps
  today_snaps=$(grep "$today" "$journal_file" 2>/dev/null |
    grep -c "\"source\":\"rubber-band\"" 2>/dev/null || true)

  if [[ "$today_snaps" -gt 0 ]]; then
    GAPS+=("${today_snaps} rubber-band snap(s) today — review corrections before committing")
  fi
}

# --- Check 3: Test files in staged changes ---

check_test_coverage() {
  if ! printf '%s' "$COMMAND" | grep -q 'git commit'; then
    return
  fi

  local staged_sources
  staged_sources=$(git diff --cached --name-only 2>/dev/null |
    grep -E '\.(ts|tsx|py|js|jsx|sh)$' |
    grep -vE '\.(test|spec)\.' |
    grep -vE '(test_|_test\.)' |
    grep -vE '__tests__' || true)

  if [[ -z "$staged_sources" ]]; then
    return
  fi

  local missing_tests=()
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    local base="${src%.*}"
    local ext="${src##*.}"
    local has_test=false

    local dir base_name
    dir="$(dirname "$src")"
    base_name="$(basename "${base}")"

    for test_pat in "${base}.test.${ext}" "${base}.spec.${ext}" "${dir}/test_${base_name}.${ext}" "${dir}/${base_name}_test.${ext}"; do
      if git diff --cached --name-only 2>/dev/null | grep -qF "$test_pat"; then
        has_test=true
        break
      fi
    done

    if [[ "$has_test" = false ]]; then
      missing_tests+=("$src")
    fi
  done <<<"$staged_sources"

  if [[ ${#missing_tests[@]} -gt 0 ]]; then
    local count="${#missing_tests[@]}"
    GAPS+=("${count} source file(s) staged without corresponding test files")
  fi
}

# --- Check 4: Metric regressions ---

check_regressions() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "$journal_file" ]]; then
    return
  fi

  local regression_count
  regression_count=$(JF="${journal_file}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
one_hour_ago = now - timedelta(hours=1)
count = 0

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') != 'regression':
                continue
            ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
            if ts >= one_hour_ago:
                count += 1
        except (json.JSONDecodeError, ValueError, KeyError):
            continue

print(count)
" 2>/dev/null || echo "0")

  if [[ "$regression_count" -gt 0 ]]; then
    GAPS+=("${regression_count} metric regression(s) detected — fix before committing")
  fi
}

check_gate_proofs
check_snaps_today
check_test_coverage
check_regressions

if [[ ${#GAPS[@]} -eq 0 ]]; then
  exit 0
fi

# Build checklist
CHECKLIST="PAUSE: Before committing, address these gaps:"
for gap in "${GAPS[@]}"; do
  CHECKLIST+=$'\n'"- ${gap}"
done

jq -n --arg reason "$CHECKLIST" '{"decision":"block","reason":$reason}'
