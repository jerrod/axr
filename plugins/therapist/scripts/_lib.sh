#!/usr/bin/env bash
# _lib.sh — Shared utilities for therapist skill scripts
#
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/_lib.sh"

set -euo pipefail

# --- Directory Resolution ---

IN_GIT_REPO=false
if git rev-parse --show-toplevel &>/dev/null; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  IN_GIT_REPO=true
else
  REPO_ROOT="$(pwd)"
fi
THERAPIST_DIR="${REPO_ROOT}/.therapist"

# --- Setup ---

ensure_therapist_dir() {
  mkdir -p "${THERAPIST_DIR}"

  # Only mutate .gitignore once per directory creation, and only in a real git repo
  if [[ "$IN_GIT_REPO" = true ]]; then
    local gitignore="${REPO_ROOT}/.gitignore"
    local marker="${THERAPIST_DIR}/.gitignore-done"
    if [[ ! -f "$marker" ]]; then
      # Create .gitignore if it doesn't exist
      touch "${gitignore}"
      if ! grep -qxF '.therapist/' "${gitignore}" 2>/dev/null; then
        printf '\n.therapist/\n' >>"${gitignore}"
      fi
      touch "$marker"
    fi
  fi
}

# --- JSON Utilities ---

escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  # Strip remaining control chars (0x00-0x1F) that could break JSON
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '%s' "$s"
}

# --- Cooldown ---

check_cooldown() {
  local tool_name="${1:?Usage: check_cooldown <tool-name> <seconds>}"
  local seconds="${2:?Usage: check_cooldown <tool-name> <seconds>}"
  local cooldown_file="${THERAPIST_DIR}/${tool_name}-last"

  ensure_therapist_dir

  if [[ -f "$cooldown_file" ]]; then
    local last_ts now_ts
    last_ts=$(cat "$cooldown_file" 2>/dev/null || echo "0")
    # Validate numeric to avoid arithmetic errors on corrupted files
    if ! [[ "$last_ts" =~ ^[0-9]+$ ]]; then
      last_ts=0
    fi
    now_ts=$(date +%s)
    local diff=$((now_ts - last_ts))
    if [[ "$diff" -lt "$seconds" ]]; then
      return 1
    fi
  fi

  date +%s >"$cooldown_file"
  return 0
}

# --- Journal Rotation ---

MAX_JOURNAL_LINES=10000

rotate_journal_if_needed() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "$journal_file" ]]; then
    return 0
  fi
  local line_count
  line_count=$(wc -l <"$journal_file" 2>/dev/null | tr -d ' ' || echo "0")
  [[ -z "$line_count" ]] && line_count=0
  if [[ "$line_count" -gt "$MAX_JOURNAL_LINES" ]]; then
    local keep=$((MAX_JOURNAL_LINES / 2))
    local archive_lines=$((line_count - keep))
    local archive
    archive="${THERAPIST_DIR}/journal.$(date +%Y%m%d%H%M%S).jsonl"
    # Portable "all but the last N" — head -n -N is GNU-only and breaks on
    # BSD head (macOS). Compute the count and use a positive head value.
    head -n "$archive_lines" "$journal_file" >"$archive"
    tail -n "$keep" "$journal_file" >"${journal_file}.tmp"
    mv "${journal_file}.tmp" "$journal_file"
  fi
}

# --- Quality Command Detection ---

is_quality_command() {
  local cmd="$1"
  printf '%s' "$cmd" | grep -qiE \
    '(bin/test|bin/lint|bin/format|bin/typecheck|pytest|vitest|jest|eslint|ruff|mypy|tsc|run-gates|gate-|coverage|bin/check)'
}

has_failure() {
  local output="$1"
  printf '%s' "$output" | grep -qiE \
    '(FAIL|FAILED|ERROR|error:|failure|exit code [1-9]|GATE FAILED|ModuleNotFoundError|SyntaxError|TypeError|ImportError)'
}

# --- Journal ---

journal_log() {
  local type="${1:?Usage: journal_log <type> <trigger> <correction> [--key=value ...]}"
  local trigger="${2:?Usage: journal_log <type> <trigger> <correction> [--key=value ...]}"
  local correction="${3:?Usage: journal_log <type> <trigger> <correction> [--key=value ...]}"
  shift 3

  local phrase="" source="" event="" belief="" consequence=""
  local category="" predicted="" resolved="" metric="" value="" target=""
  local prediction_ts=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phrase=*) phrase="${1#--phrase=}" ;;
      --source=*) source="${1#--source=}" ;;
      --event=*) event="${1#--event=}" ;;
      --belief=*) belief="${1#--belief=}" ;;
      --consequence=*) consequence="${1#--consequence=}" ;;
      --category=*) category="${1#--category=}" ;;
      --predicted=*) predicted="${1#--predicted=}" ;;
      --resolved=*) resolved="${1#--resolved=}" ;;
      --metric=*) metric="${1#--metric=}" ;;
      --value=*) value="${1#--value=}" ;;
      --target=*) target="${1#--target=}" ;;
      --prediction-ts=*) prediction_ts="${1#--prediction-ts=}" ;;
      *) ;; # ignore unknown
    esac
    shift
  done

  ensure_therapist_dir

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local escaped_type escaped_trigger escaped_correction
  escaped_type="$(escape_for_json "$type")"
  escaped_trigger="$(escape_for_json "$trigger")"
  escaped_correction="$(escape_for_json "$correction")"

  local entry
  entry="{\"ts\":\"${ts}\",\"type\":\"${escaped_type}\""
  entry+=",\"trigger\":\"${escaped_trigger}\""

  if [[ -n "${phrase}" ]]; then
    entry+=",\"phrase\":\"$(escape_for_json "$phrase")\""
  fi

  entry+=",\"correction\":\"${escaped_correction}\""

  if [[ -n "${source}" ]]; then
    entry+=",\"source\":\"$(escape_for_json "$source")\""
  fi

  if [[ -n "${event}" ]]; then
    entry+=",\"activating_event\":\"$(escape_for_json "$event")\""
  fi

  if [[ -n "${belief}" ]]; then
    entry+=",\"belief\":\"$(escape_for_json "$belief")\""
  fi

  if [[ -n "${consequence}" ]]; then
    entry+=",\"consequence\":\"$(escape_for_json "$consequence")\""
  fi

  if [[ -n "${category}" ]]; then
    entry+=",\"category\":\"$(escape_for_json "$category")\""
  fi

  if [[ -n "${predicted}" ]]; then
    entry+=",\"predicted\":\"$(escape_for_json "$predicted")\""
  fi

  if [[ -n "${resolved}" ]]; then
    # Validate boolean: only allow true/false
    if [[ "${resolved}" == "true" || "${resolved}" == "false" ]]; then
      entry+=",\"resolved\":${resolved}"
    else
      entry+=",\"resolved\":false"
    fi
  fi

  if [[ -n "${metric}" ]]; then
    entry+=",\"metric\":\"$(escape_for_json "$metric")\""
  fi

  if [[ -n "${value}" ]]; then
    # Validate numeric: strip non-numeric chars for safety
    local safe_value
    safe_value=$(printf '%s' "$value" | grep -oE '^-?[0-9]+\.?[0-9]*$' || echo "0")
    entry+=",\"value\":${safe_value}"
  fi

  if [[ -n "${target}" ]]; then
    local safe_target
    safe_target=$(printf '%s' "$target" | grep -oE '^-?[0-9]+\.?[0-9]*$' || echo "0")
    entry+=",\"target\":${safe_target}"
  fi

  if [[ -n "${prediction_ts}" ]]; then
    entry+=",\"prediction_ts\":\"$(escape_for_json "$prediction_ts")\""
  fi

  entry+="}"
  _journal_with_lock _journal_append_and_rotate "$entry"
}

# _journal_append_and_rotate — callback executed while holding the journal
# lock. Takes the pre-built JSONL entry as arg 1 and performs the append
# and rotation atomically so concurrent hook executions cannot overlap
# with a rotate-in-progress and lose data.
_journal_append_and_rotate() {
  local entry="$1"
  printf '%s\n' "$entry" >>"${THERAPIST_DIR}/journal.jsonl"
  rotate_journal_if_needed
}

# _journal_with_lock — acquire an exclusive journal lock, run the given
# command with its arguments, and release the lock. Prefers flock(1) when
# present (Linux, Homebrew util-linux on macOS). Falls back to a portable
# mkdir-based advisory lock so the plugin works out of the box on macOS
# where flock is not installed by default.
_journal_with_lock() {
  local cb="$1"
  shift
  local lock_file="${THERAPIST_DIR}/journal.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 200
      "$cb" "$@"
    ) 200>"$lock_file"
    return
  fi
  # mkdir is atomic on local filesystems — use a lock directory.
  local lock_dir="${lock_file}.d"
  local waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    # After ~5s, assume the holder crashed and steal the lock.
    if [[ "$waited" -gt 100 ]]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || break
      break
    fi
  done
  # Ensure the lock is released even on callback failure.
  trap 'rm -rf "${lock_dir}" 2>/dev/null || true' RETURN
  "$cb" "$@"
  rm -rf "$lock_dir" 2>/dev/null || true
  trap - RETURN
}

journal_stats() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    echo "No journal entries found."
    return 0
  fi

  JF="${journal_file}" python3 -c "
import json, os
from collections import Counter

journal_file = os.environ['JF']
counts = Counter()
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            counts[entry.get('type', 'unknown')] += 1
        except json.JSONDecodeError:
            continue

if not counts:
    print('No distortions recorded.')
else:
    print('Distortion counts:')
    for dtype, count in counts.most_common():
        print(f'  {dtype}: {count}')
    print(f'  Total: {sum(counts.values())}')
"
}

# --- Query/Analytics Modules ---
# Source these for journal query functions:
#   source "${SCRIPT_DIR}/_lib_queries.sh"   # category_counts, open_predictions, etc.
#   source "${SCRIPT_DIR}/_lib_analytics.sh"  # resolution_rate, cost_summary, risk_profile
