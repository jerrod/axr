#!/usr/bin/env bash
# Audit trail: execution plan + runtime agent/skill logging
# Always exits 0 — logging failures must never block workflows
#
# Usage:
#   audit-trail.sh init <task>                          — Initialize .quality/audit/
#   audit-trail.sh plan <json-file>                     — Register execution plan
#   audit-trail.sh log <phase> <name> <action> [flags]  — Log agent/skill entry
#   audit-trail.sh report                               — Generate markdown for PR
#   audit-trail.sh show                                 — Display summary to terminal
set -euo pipefail
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUDIT_DIR="${AUDIT_DIR:-.quality/audit}"
TRAIL_FILE="$AUDIT_DIR/trail.json"
LOCK_FILE="$AUDIT_DIR/.trail.lock"
PLAN_FILE="$AUDIT_DIR/execution-plan.json"

# shellcheck source=plugins/sdlc/scripts/_audit_lib.sh
source "$SCRIPT_DIR/_audit_lib.sh"

# ─── Helpers ────────────────────────────────────────────────────

find_plugin_json() {
  local pj
  pj=$(find . -name "plugin.json" -path "*/sdlc/.claude-plugin/*" 2>/dev/null | head -1)
  if [ -z "$pj" ]; then
    pj=$(find "$HOME/.claude" -name "plugin.json" -path "*/sdlc/.claude-plugin/*" 2>/dev/null | sort -V | tail -1)
  fi
  echo "$pj"
}

get_plugin_version() {
  local pj
  pj=$(find_plugin_json)
  if [ -n "$pj" ]; then
    AT_PJ="$pj" python3 -c "
import json, os
print(json.load(open(os.environ['AT_PJ']))['version'])
" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

timestamp_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

timestamp_id() {
  local nano
  nano=$(date -u +"%N" 2>/dev/null || echo "000000000")
  echo "$(date -u +"%Y%m%d-%H%M%S")-${nano:0:6}-$$"
}

sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g'
}

current_sha() {
  git rev-parse HEAD 2>/dev/null || echo "unknown"
}

# ─── Commands ───────────────────────────────────────────────────

cmd_init() {
  local task="${1:-}"
  mkdir -p "$AUDIT_DIR"

  if [ ! -f "$TRAIL_FILE" ]; then
    local version
    version=$(get_plugin_version)
    AT_VERSION="$version" \
      AT_TS="$(timestamp_iso)" \
      AT_TRAIL_FILE="$TRAIL_FILE" \
      python3 -c "
import json, os
trail = {
    'version': 1,
    'plugin_version': os.environ['AT_VERSION'],
    'initialized_at': os.environ['AT_TS'],
    'entries': []
}
json.dump(trail, open(os.environ['AT_TRAIL_FILE'], 'w'), indent=2)
"
  fi

  if [ -n "$task" ]; then
    echo "$task" >"$AUDIT_DIR/task.txt"
  fi

  echo "Audit trail initialized in $AUDIT_DIR"
}

cmd_log() {
  local phase="${1:-}"
  local name="${2:-}"
  local action="${3:-}"
  shift 3 2>/dev/null || true

  if [ -z "$phase" ] || [ -z "$name" ] || [ -z "$action" ]; then
    echo "Usage: audit-trail.sh log <phase> <name> <action> [--context=...] [--duration=...] [--tools=...] [--files=...] [--gates=...]"
    return
  fi

  # Validate action
  case "$action" in
    started | completed | failed) ;;
    *)
      echo "Invalid action: $action (must be started|completed|failed)"
      return
      ;;
  esac

  # Parse flags
  local context="" duration="" tools="" files="" gates=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context=*) context="${1#--context=}" ;;
      --duration=*) duration="${1#--duration=}" ;;
      --tools=*) tools="${1#--tools=}" ;;
      --files=*) files="${1#--files=}" ;;
      --gates=*) gates="${1#--gates=}" ;;
    esac
    shift
  done

  local entry_id
  entry_id="$(timestamp_id)-$(sanitize_name "$name")-$action"
  local sha
  sha=$(current_sha)
  local ts
  ts=$(timestamp_iso)

  # Initialize trail if it doesn't exist
  if [ ! -f "$TRAIL_FILE" ]; then
    cmd_init ""
  fi

  local entry_json
  entry_json=$(AT_ID="$entry_id" \
    AT_TS="$ts" \
    AT_PHASE="$phase" \
    AT_NAME="$name" \
    AT_ACTION="$action" \
    AT_SHA="$sha" \
    AT_CONTEXT="$context" \
    AT_DURATION="$duration" \
    AT_TOOLS="$tools" \
    AT_FILES="$files" \
    AT_GATES="$gates" \
    python3 -c "
import json, os
entry = {
    'id': os.environ['AT_ID'],
    'timestamp': os.environ['AT_TS'],
    'phase': os.environ['AT_PHASE'],
    'name': os.environ['AT_NAME'],
    'action': os.environ['AT_ACTION'],
    'sha': os.environ['AT_SHA']
}
ctx = os.environ.get('AT_CONTEXT', '')
if ctx: entry['context'] = ctx
dur = os.environ.get('AT_DURATION', '')
if dur: entry['duration_seconds'] = int(dur)
tools = os.environ.get('AT_TOOLS', '')
if tools: entry['tool_calls'] = int(tools)
files = os.environ.get('AT_FILES', '')
if files: entry['files_changed'] = files
gates = os.environ.get('AT_GATES', '')
if gates: entry['gates'] = gates
print(json.dumps(entry))
")

  # Append with lock if flock is available; otherwise write per-entry files
  if command -v flock >/dev/null 2>&1; then
    AT_TRAIL_FILE="$TRAIL_FILE" flock "$LOCK_FILE" python3 -c "
import json, sys, os
trail = json.load(open(os.environ['AT_TRAIL_FILE']))
trail['entries'].append(json.loads(sys.stdin.read()))
json.dump(trail, open(os.environ['AT_TRAIL_FILE'], 'w'), indent=2)
" <<<"$entry_json" || true
  else
    # No flock — write per-entry file to avoid concurrent write corruption
    local entries_dir="$AUDIT_DIR/entries"
    mkdir -p "$entries_dir"
    echo "$entry_json" >"$entries_dir/${entry_id}.json"
    # AUDIT_SYNC_WRITES=1 forces an immediate merge into trail.json. Used by
    # tests that want deterministic post-log reads on macOS (no flock). Do
    # NOT set this in production — it re-introduces the concurrent-write
    # race that the per-entry fallback is designed to prevent.
    if [ -n "${AUDIT_SYNC_WRITES:-}" ]; then
      merge_pending_entries
    fi
  fi

  echo "Logged: $phase/$name/$action"
}


# ─── Dispatch ───────────────────────────────────────────────────

CMD="${1:-}"
if [ -n "$CMD" ]; then
  shift
fi

case "$CMD" in
  init) cmd_init "$@" ;;
  plan) cmd_plan "$@" ;;
  log) cmd_log "$@" ;;
  report) cmd_report ;;
  show) cmd_show ;;
  *)
    echo "Usage: audit-trail.sh {init|plan|log|report|show}"
    echo ""
    echo "Commands:"
    echo "  init <task>                           Initialize audit trail"
    echo "  plan <json-file>                      Register execution plan"
    echo "  log <phase> <name> <action> [flags]   Log agent/skill entry"
    echo "  report                                Generate markdown report"
    echo "  show                                  Display terminal summary"
    ;;
esac
