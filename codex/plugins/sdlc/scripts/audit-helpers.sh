#!/usr/bin/env bash
# Helpers for audit-trail.sh — init, plan registration, report/show
# rendering, and per-entry merge. Sourced, not executed directly.
#
# These live in their own file so audit-trail.sh stays under the 300-line
# per-file gate. All functions here rely on variables exported by the
# parent script: AUDIT_DIR, TRAIL_FILE, PLAN_FILE. cmd_init lives here so
# the library is fully self-contained — sourcing it pulls in everything
# cmd_log and merge_pending_entries need without an inverted dependency
# back into audit-trail.sh.

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

cmd_plan() {
  local plan_source="${1:-}"
  if [ -z "$plan_source" ]; then
    echo "Usage: audit-trail.sh plan <json-file>"
    return
  fi

  if [ -f "$PLAN_FILE" ]; then
    echo "Plan already registered at $PLAN_FILE"
    return
  fi

  if [ ! -f "$plan_source" ]; then
    echo "Plan file not found: $plan_source"
    return
  fi

  # Containment check: refuse plan files outside the repo. cmd_plan copies
  # the source verbatim into PLAN_FILE, so an arbitrary path would let a
  # caller seed the audit trail from anywhere on disk.
  local repo_root real_src
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  real_src=$(realpath "$plan_source" 2>/dev/null) || {
    echo "Cannot resolve path: $plan_source"
    return
  }
  case "$real_src" in
    "$repo_root"/*) ;;
    *)
      echo "Plan file must be inside the repo: $plan_source"
      return
      ;;
  esac

  # Validate JSON structure. Capture python output without overwriting it
  # with a generic 'invalid' string so the user sees the actual error.
  local valid
  valid=$(AT_SRC="$plan_source" python3 -c "
import json, sys, os
try:
    data = json.load(open(os.environ['AT_SRC']))
    if 'planned_phases' not in data:
        print('missing planned_phases')
        sys.exit(1)
    if not isinstance(data.get('planned_phases'), list):
        print('planned_phases must be a list')
        sys.exit(1)
    print('valid')
except Exception as e:
    print(f'invalid: {e}')
    sys.exit(1)
" 2>/dev/null) || true

  if [ "$valid" != "valid" ]; then
    echo "Invalid plan JSON: ${valid:-unknown error}"
    return
  fi

  mkdir -p "$AUDIT_DIR"
  cp "$plan_source" "$PLAN_FILE"
  echo "Execution plan registered"
}

# merge_pending_entries — coalesce per-entry JSON files into trail.json.
# Per-entry files are written by cmd_log on systems without flock (macOS) to
# avoid concurrent-write corruption. report/show call this so the trail is
# complete before display, even if no flock-serialized merge ran.
merge_pending_entries() {
  local entries_dir="$AUDIT_DIR/entries"
  [ -d "$entries_dir" ] || return 0
  local entry_files
  entry_files=$(find "$entries_dir" -name '*.json' 2>/dev/null | sort)
  [ -z "$entry_files" ] && return 0

  if [ ! -f "$TRAIL_FILE" ]; then
    cmd_init ""
  fi

  AT_TRAIL_FILE="$TRAIL_FILE" AT_ENTRIES_DIR="$entries_dir" python3 -c "
import json, os, glob
trail = json.load(open(os.environ['AT_TRAIL_FILE']))
entries_dir = os.environ['AT_ENTRIES_DIR']
for path in sorted(glob.glob(os.path.join(entries_dir, '*.json'))):
    try:
        entry = json.load(open(path))
        trail['entries'].append(entry)
        os.remove(path)
    except Exception:
        pass
json.dump(trail, open(os.environ['AT_TRAIL_FILE'], 'w'), indent=2)
" || true
}

cmd_report() {
  # Merge any per-entry files written without flock
  merge_pending_entries

  local has_plan="no"
  local has_trail="no"
  [ -f "$PLAN_FILE" ] && has_plan="yes"
  [ -f "$TRAIL_FILE" ] && has_trail="yes"

  if [ "$has_plan" = "no" ] && [ "$has_trail" = "no" ]; then
    echo "No audit data found in $AUDIT_DIR"
    return
  fi

  AT_MODE=report \
    AT_HAS_PLAN="$has_plan" \
    AT_HAS_TRAIL="$has_trail" \
    AT_AUDIT_DIR="$AUDIT_DIR" \
    AT_PLAN_FILE="$PLAN_FILE" \
    AT_TRAIL_FILE="$TRAIL_FILE" \
    python3 "$SCRIPT_DIR/audit_render.py" || true
}

cmd_show() {
  # Merge any per-entry files written without flock
  merge_pending_entries

  if [ ! -f "$TRAIL_FILE" ]; then
    echo "No audit trail found. Run: audit-trail.sh init <task>"
    return
  fi

  local task=""
  [ -f "$AUDIT_DIR/task.txt" ] && task=$(cat "$AUDIT_DIR/task.txt")

  AT_MODE=show \
    AT_TRAIL_FILE="$TRAIL_FILE" \
    AT_TASK="$task" \
    python3 "$SCRIPT_DIR/audit_render.py" || true
}
