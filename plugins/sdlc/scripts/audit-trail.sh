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

AUDIT_DIR="${AUDIT_DIR:-.quality/audit}"
TRAIL_FILE="$AUDIT_DIR/trail.json"
LOCK_FILE="$AUDIT_DIR/.trail.lock"
PLAN_FILE="$AUDIT_DIR/execution-plan.json"

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

  # Validate JSON structure
  local valid
  valid=$(AT_SRC="$plan_source" python3 -c "
import json, sys, os
try:
    data = json.load(open(os.environ['AT_SRC']))
    if 'planned_phases' not in data:
        print('missing planned_phases')
        sys.exit(1)
    print('valid')
except Exception as e:
    print(f'invalid: {e}')
    sys.exit(1)
" 2>/dev/null) || valid="invalid"

  if [ "$valid" != "valid" ]; then
    echo "Invalid plan JSON: $valid"
    return
  fi

  mkdir -p "$AUDIT_DIR"
  cp "$plan_source" "$PLAN_FILE"
  echo "Execution plan registered"
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

  AT_HAS_PLAN="$has_plan" \
    AT_HAS_TRAIL="$has_trail" \
    AT_AUDIT_DIR="$AUDIT_DIR" \
    AT_PLAN_FILE="$PLAN_FILE" \
    AT_TRAIL_FILE="$TRAIL_FILE" \
    python3 -c "
import json, os

plan = None
trail = None
task = ''
has_plan = (os.environ['AT_HAS_PLAN'] == 'yes')
has_trail = (os.environ['AT_HAS_TRAIL'] == 'yes')
audit_dir = os.environ['AT_AUDIT_DIR']

try:
    with open(os.path.join(audit_dir, 'task.txt')) as f:
        task = f.read().strip()
except FileNotFoundError:
    pass

if has_plan:
    try:
        plan = json.load(open(os.environ['AT_PLAN_FILE']))
    except Exception:
        pass

if has_trail:
    try:
        trail = json.load(open(os.environ['AT_TRAIL_FILE']))
    except Exception:
        pass

entries = trail.get('entries', []) if trail else []
plugin_version = trail.get('plugin_version', 'unknown') if trail else 'unknown'

# Build sets for plan vs actual comparison
planned_set = set()
if plan:
    for p in plan.get('planned_phases', []):
        phase = p.get('phase', '')
        agent = p.get('agent', '')
        if phase and agent:
            planned_set.add((phase, agent))

executed_set = set()
started_set = set()
for e in entries:
    key = (e.get('phase', ''), e.get('name', ''))
    if e.get('action') in ('completed', 'failed'):
        executed_set.add(key)
    if e.get('action') == 'started':
        started_set.add(key)

skipped = planned_set - executed_set - started_set
unplanned = executed_set - planned_set

total_duration = sum(e.get('duration_seconds', 0) for e in entries)
total_tools = sum(e.get('tool_calls', 0) for e in entries)

# Output markdown
print('### Execution Summary')
print()
if task:
    print(f'**Task:** {task}')
print(f'**Plugin version:** {plugin_version}')
print(f'**Planned phases:** {len(planned_set)}')
print(f'**Executed:** {len(executed_set)}')
print(f'**Skipped:** {len(skipped)}')
print(f'**Unplanned:** {len(unplanned)}')
if total_duration:
    print(f'**Total duration:** {total_duration}s')
if total_tools:
    print(f'**Total tool calls:** {total_tools}')
print()

# Execution Plan table
if plan and plan.get('planned_phases'):
    print('### Execution Plan')
    print()
    print('| # | Phase | Agent | Skills | Reason | Status |')
    print('|---|-------|-------|--------|--------|--------|')
    for p in plan['planned_phases']:
        order = p.get('order', '?')
        phase = p.get('phase', '?')
        agent = p.get('agent', '-')
        skills = ', '.join(p.get('skills', []))
        reason = p.get('reason', '-')
        key = (phase, agent)
        if key in executed_set:
            # Check if any failed
            failed = any(
                e.get('phase') == phase and e.get('name') == agent and e.get('action') == 'failed'
                for e in entries
            )
            status = 'failed' if failed else 'completed'
        elif key in started_set:
            status = 'in-progress'
        else:
            status = 'skipped'
        print(f'| {order} | {phase} | {agent} | {skills} | {reason} | {status} |')
    print()

    if unplanned:
        print('**Unplanned executions:**')
        for phase, name in sorted(unplanned):
            print(f'- {phase}/{name}')
        print()

# Audit Trail details
if entries:
    print('<details><summary>Audit Trail ({} entries)</summary>'.format(len(entries)))
    print()
    print('| Time | Phase | Name | Action | Duration | Tools | SHA |')
    print('|------|-------|------|--------|----------|-------|-----|')
    for e in entries:
        ts = e.get('timestamp', '?')
        if 'T' in ts:
            ts = ts.split('T')[1].replace('Z', '')
        phase = e.get('phase', '?')
        name = e.get('name', '?')
        action = e.get('action', '?')
        dur = str(e.get('duration_seconds', '-')) + 's' if 'duration_seconds' in e else '-'
        tools = str(e.get('tool_calls', '-')) if 'tool_calls' in e else '-'
        sha = e.get('sha', '?')
        ctx = e.get('context', '')
        action_str = action
        if ctx:
            action_str = f'{action}: {ctx}'
        print(f'| {ts} | {phase} | {name} | {action_str} | {dur} | {tools} | \`{sha}\` |')

    # Detect orphaned started entries
    orphaned = started_set - executed_set
    if orphaned:
        print()
        print('**Orphaned entries (started but no completion):**')
        for phase, name in sorted(orphaned):
            print(f'- {phase}/{name} — status unknown')

    print()
    print('</details>')
    print()
"
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

  AT_TRAIL_FILE="$TRAIL_FILE" \
    AT_TASK="$task" \
    python3 -c "
import json, os

trail = json.load(open(os.environ['AT_TRAIL_FILE']))
task = os.environ.get('AT_TASK', '')
entries = trail.get('entries', [])

print('─── Audit Trail ───')
if task:
    print(f'Task: {task}')
print(f'Plugin: v{trail.get(\"plugin_version\", \"unknown\")}')
print(f'Entries: {len(entries)}')
print()

if entries:
    for e in entries:
        ts = e.get('timestamp', '?')
        if 'T' in ts:
            ts = ts.split('T')[1].replace('Z', '')
        action = e.get('action', '?')
        icon = {'started': '▶', 'completed': '✓', 'failed': '✗'}.get(action, '?')
        name = e.get('name', '?')
        phase = e.get('phase', '?')
        ctx = e.get('context', '')
        line = f'  {icon} [{ts}] {phase}/{name} {action}'
        if ctx:
            line += f' — {ctx}'
        print(line)
"
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
