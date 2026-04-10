"""Render audit-trail data as PR markdown (report) or terminal text (show).

Invoked by audit-helpers.sh::cmd_report and ::cmd_show. Lives in its own
module so audit-helpers.sh stays under the 300-line per-file gate.

Inputs come via environment variables (same convention used elsewhere in
this plugin to keep shell-to-python wiring auditable):
  AT_MODE          'report' | 'show'
  AT_HAS_PLAN      'yes' | 'no'         (report only)
  AT_HAS_TRAIL     'yes' | 'no'         (report only)
  AT_AUDIT_DIR     audit dir path       (report only — for task.txt lookup)
  AT_PLAN_FILE     execution-plan.json path
  AT_TRAIL_FILE    trail.json path
  AT_TASK          task string          (show only)
"""

from __future__ import annotations

import json
import os
import sys


def _load(path: str):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return None


def _entries(trail):
    return trail.get("entries", []) if trail else []


def _planned_set(plan):
    s = set()
    if not plan:
        return s
    for p in plan.get("planned_phases", []) or []:
        phase = p.get("phase", "")
        agent = p.get("agent", "")
        if phase and agent:
            s.add((phase, agent))
    return s


def _exec_sets(entries):
    executed, started = set(), set()
    for e in entries:
        key = (e.get("phase", ""), e.get("name", ""))
        if e.get("action") in ("completed", "failed"):
            executed.add(key)
        if e.get("action") == "started":
            started.add(key)
    return executed, started


def _row_status(phase, agent, entries, executed_set, started_set):
    key = (phase, agent)
    if key in executed_set:
        failed = any(
            e.get("phase") == phase
            and e.get("name") == agent
            and e.get("action") == "failed"
            for e in entries
        )
        return "failed" if failed else "completed"
    if key in started_set:
        return "in-progress"
    return "skipped"


def _read_task(audit_dir):
    try:
        with open(os.path.join(audit_dir, "task.txt")) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return ""


def _render_summary_block(task, plugin_version, planned_set, executed_set,
                          skipped, unplanned, total_duration, total_tools):
    print("### Execution Summary")
    print()
    if task:
        print(f"**Task:** {task}")
    print(f"**Plugin version:** {plugin_version}")
    print(f"**Planned phases:** {len(planned_set)}")
    print(f"**Executed:** {len(executed_set)}")
    print(f"**Skipped:** {len(skipped)}")
    print(f"**Unplanned:** {len(unplanned)}")
    if total_duration:
        print(f"**Total duration:** {total_duration}s")
    if total_tools:
        print(f"**Total tool calls:** {total_tools}")
    print()


def _render_plan_table(plan, entries, executed_set, started_set, unplanned):
    if not (plan and plan.get("planned_phases")):
        return
    print("### Execution Plan")
    print()
    print("| # | Phase | Agent | Skills | Reason | Status |")
    print("|---|-------|-------|--------|--------|--------|")
    for p in plan["planned_phases"]:
        order = p.get("order", "?")
        phase = p.get("phase", "?")
        agent = p.get("agent", "-")
        skills = ", ".join(p.get("skills", []))
        reason = p.get("reason", "-")
        status = _row_status(phase, agent, entries, executed_set, started_set)
        print(f"| {order} | {phase} | {agent} | {skills} | {reason} | {status} |")
    print()

    if unplanned:
        print("**Unplanned executions:**")
        for phase, name in sorted(unplanned):
            print(f"- {phase}/{name}")
        print()


def _format_entry_row(e):
    ts = e.get("timestamp", "?")
    if "T" in ts:
        ts = ts.split("T")[1].replace("Z", "")
    phase = e.get("phase", "?")
    name = e.get("name", "?")
    action = e.get("action", "?")
    dur = (
        str(e.get("duration_seconds", "-")) + "s"
        if "duration_seconds" in e
        else "-"
    )
    tools = str(e.get("tool_calls", "-")) if "tool_calls" in e else "-"
    sha = e.get("sha", "?")
    ctx = e.get("context", "")
    action_str = f"{action}: {ctx}" if ctx else action
    return f"| {ts} | {phase} | {name} | {action_str} | {dur} | {tools} | `{sha}` |"


def _render_trail_details(entries, started_set, executed_set):
    if not entries:
        return
    print(f"<details><summary>Audit Trail ({len(entries)} entries)</summary>")
    print()
    print("| Time | Phase | Name | Action | Duration | Tools | SHA |")
    print("|------|-------|------|--------|----------|-------|-----|")
    for e in entries:
        print(_format_entry_row(e))

    orphaned = started_set - executed_set
    if orphaned:
        print()
        print("**Orphaned entries (started but no completion):**")
        for phase, name in sorted(orphaned):
            print(f"- {phase}/{name} — status unknown")

    print()
    print("</details>")
    print()


def _render_report():
    has_plan = os.environ.get("AT_HAS_PLAN") == "yes"
    has_trail = os.environ.get("AT_HAS_TRAIL") == "yes"
    audit_dir = os.environ.get("AT_AUDIT_DIR", "")

    task = _read_task(audit_dir)
    plan = _load(os.environ.get("AT_PLAN_FILE", "")) if has_plan else None
    trail = _load(os.environ.get("AT_TRAIL_FILE", "")) if has_trail else None
    entries = _entries(trail)
    plugin_version = trail.get("plugin_version", "unknown") if trail else "unknown"

    planned_set = _planned_set(plan)
    executed_set, started_set = _exec_sets(entries)
    skipped = planned_set - executed_set - started_set
    unplanned = executed_set - planned_set
    total_duration = sum(e.get("duration_seconds", 0) for e in entries)
    total_tools = sum(e.get("tool_calls", 0) for e in entries)

    _render_summary_block(task, plugin_version, planned_set, executed_set,
                          skipped, unplanned, total_duration, total_tools)
    _render_plan_table(plan, entries, executed_set, started_set, unplanned)
    _render_trail_details(entries, started_set, executed_set)


def _render_show():
    trail = _load(os.environ.get("AT_TRAIL_FILE", "")) or {}
    task = os.environ.get("AT_TASK", "")
    entries = trail.get("entries", [])

    print("─── Audit Trail ───")
    if task:
        print(f"Task: {task}")
    print(f'Plugin: v{trail.get("plugin_version", "unknown")}')
    print(f"Entries: {len(entries)}")
    print()

    icons = {"started": "▶", "completed": "✓", "failed": "✗"}
    for e in entries:
        ts = e.get("timestamp", "?")
        if "T" in ts:
            ts = ts.split("T")[1].replace("Z", "")
        action = e.get("action", "?")
        icon = icons.get(action, "?")
        name = e.get("name", "?")
        phase = e.get("phase", "?")
        ctx = e.get("context", "")
        line = f"  {icon} [{ts}] {phase}/{name} {action}"
        if ctx:
            line += f" — {ctx}"
        print(line)


def main():
    mode = os.environ.get("AT_MODE", "")
    if mode == "report":
        _render_report()
    elif mode == "show":
        _render_show()
    else:
        print(f"audit_render.py: unknown AT_MODE: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
