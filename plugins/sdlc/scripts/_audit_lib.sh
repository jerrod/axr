#!/usr/bin/env bash
# Helpers for audit-trail.sh — plan registration, report/show rendering,
# and per-entry merge. Sourced, not executed directly.
#
# These live in their own file so audit-trail.sh stays under the 300-line
# per-file gate. All functions here rely on variables exported by the
# parent script: AUDIT_DIR, TRAIL_FILE, PLAN_FILE. cmd_init is defined in
# audit-trail.sh because cmd_log and merge_pending_entries both call it
# and keeping it there avoids a circular source.

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
