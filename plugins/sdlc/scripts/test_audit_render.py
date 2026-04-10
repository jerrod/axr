"""Tests for audit_render.py — direct function tests + main subprocess test."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from audit_render import (
    _entries, _exec_sets, _format_entry_row, _load, _planned_set, _read_task,
    _render_plan_table, _render_report, _render_show, _render_summary_block,
    _render_trail_details, _row_status, main,
)


PLAN = {"planned_phases": [
    {"order": 1, "phase": "build", "agent": "writer",
     "skills": ["pair-build"], "reason": "implement"},
    {"order": 2, "phase": "review", "agent": "critic",
     "skills": ["review"], "reason": "verify"},
    {"order": 3, "phase": "ship", "agent": "shipper",
     "skills": [], "reason": "release"},
]}

ENTRIES = [
    {"timestamp": "2026-04-09T10:00:00Z", "phase": "build", "name": "writer",
     "action": "started", "sha": "abc", "context": "starting"},
    {"timestamp": "2026-04-09T10:05:00Z", "phase": "build", "name": "writer",
     "action": "completed", "duration_seconds": 300, "tool_calls": 12,
     "sha": "abc", "context": "done"},
    {"timestamp": "2026-04-09T10:06:00Z", "phase": "review", "name": "critic",
     "action": "failed", "duration_seconds": 60, "tool_calls": 4, "sha": "def"},
    {"timestamp": "2026-04-09T10:10:00Z", "phase": "extra", "name": "rogue",
     "action": "completed", "sha": "ghi"},
]


def test_load_valid_missing_and_bad(tmp_path):
    p = tmp_path / "x.json"
    p.write_text(json.dumps({"k": 1}))
    assert _load(str(p)) == {"k": 1}
    assert _load(str(tmp_path / "missing.json")) is None
    bad = tmp_path / "bad.json"
    bad.write_text("not json")
    assert _load(str(bad)) is None


def test_entries_helpers():
    assert _entries(None) == []
    assert _entries({"entries": [{"a": 1}]}) == [{"a": 1}]


def test_planned_set_variants():
    assert _planned_set(None) == set()
    assert _planned_set({"planned_phases": None}) == set()
    plan = {"planned_phases": PLAN["planned_phases"] + [{"phase": "", "agent": "x"}]}
    s = _planned_set(plan)
    assert ("build", "writer") in s
    assert ("", "x") not in s


def test_exec_sets():
    executed, started = _exec_sets(ENTRIES)
    assert {("build", "writer"), ("review", "critic"), ("extra", "rogue")} <= executed
    assert ("build", "writer") in started


def test_exec_sets_started_only_without_completion():
    """A phase that only emits `started` (no completed/failed) must appear
    in started_set but NOT in executed_set so _row_status can render it
    as in-progress."""
    in_progress_only = [
        {"timestamp": "2026-04-09T11:00:00Z", "phase": "ship", "name": "shipper",
         "action": "started"},
    ]
    executed, started = _exec_sets(in_progress_only)
    assert ("ship", "shipper") in started
    assert ("ship", "shipper") not in executed


def test_row_status_all_branches():
    executed, started = _exec_sets(ENTRIES)
    assert _row_status("build", "writer", ENTRIES, executed, started) == "completed"
    assert _row_status("review", "critic", ENTRIES, executed, started) == "failed"
    in_prog = [{"phase": "ship", "name": "s", "action": "started"}]
    e2, s2 = _exec_sets(in_prog)
    assert _row_status("ship", "s", in_prog, e2, s2) == "in-progress"
    assert _row_status("x", "y", [], set(), set()) == "skipped"


def test_read_task_present_and_missing(tmp_path):
    (tmp_path / "task.txt").write_text("  do the thing  \n")
    assert _read_task(str(tmp_path)) == "do the thing"
    empty = tmp_path / "empty"
    empty.mkdir()
    assert _read_task(str(empty)) == ""


def test_render_summary_full(capsys):
    _render_summary_block("my task", "1.2.3", {("a", "b")}, {("a", "b")},
                          {("c", "d")}, {("e", "f")}, 42, 7)
    out = capsys.readouterr().out
    assert "### Execution Summary" in out
    assert "**Task:** my task" in out
    assert "**Plugin version:** 1.2.3" in out
    assert "**Total duration:** 42s" in out
    assert "**Total tool calls:** 7" in out
    # Explicit skipped / unplanned assertions so a regression that swapped
    # the two labels or dropped a line would actually fail the test.
    assert "**Skipped:** 1" in out
    assert "**Unplanned:** 1" in out


def test_render_summary_minimal(capsys):
    _render_summary_block("", "v0", set(), set(), set(), set(), 0, 0)
    out = capsys.readouterr().out
    assert "**Task:**" not in out
    assert "**Total duration:**" not in out
    assert "**Total tool calls:**" not in out


def test_render_plan_table_with_unplanned(capsys):
    executed, started = _exec_sets(ENTRIES)
    unplanned = executed - _planned_set(PLAN)
    _render_plan_table(PLAN, ENTRIES, executed, started, unplanned)
    out = capsys.readouterr().out
    assert "### Execution Plan" in out
    # Assert on per-row field presence rather than a whitespace-exact row
    # match, so a future column-padding change cannot silently break the
    # test without a behavioral regression.
    lines = [line for line in out.splitlines() if "build" in line and "writer" in line]
    assert any("completed" in line and "pair-build" in line for line in lines)
    assert "skipped" in out
    assert "rogue" in out
    assert "failed" in out
    assert "skipped" in out
    assert "**Unplanned executions:**" in out
    assert "- extra/rogue" in out


def test_render_plan_table_empty(capsys):
    _render_plan_table(None, [], set(), set(), set())
    _render_plan_table({"planned_phases": []}, [], set(), set(), set())
    assert capsys.readouterr().out == ""


def test_render_plan_table_no_unplanned(capsys):
    _render_plan_table(PLAN, [], set(), set(), set())
    out = capsys.readouterr().out
    assert "### Execution Plan" in out
    assert "**Unplanned executions:**" not in out


def test_format_entry_row_full():
    row = _format_entry_row({
        "timestamp": "2026-04-09T10:05:00Z", "phase": "build", "name": "w",
        "action": "completed", "duration_seconds": 30, "tool_calls": 5,
        "sha": "abcd", "context": "ctx",
    })
    assert "10:05:00" in row
    assert "completed: ctx" in row
    assert "30s" in row
    assert "| 5 |" in row
    assert "`abcd`" in row


def test_format_entry_row_minimal_and_raw_ts():
    assert _format_entry_row({}) == "| ? | ? | ? | ? | - | - | `?` |"
    assert "raw-ts" in _format_entry_row({"timestamp": "raw-ts"})


def test_render_trail_details_with_orphans(capsys):
    entries = [{"timestamp": "T1", "phase": "p", "name": "n",
                "action": "started", "sha": "x"}]
    _render_trail_details(entries, {("p", "n"), ("orph", "ned")}, set())
    out = capsys.readouterr().out
    assert "<details>" in out
    assert "Audit Trail (1 entries)" in out
    assert "**Orphaned entries" in out
    assert "- orph/ned" in out
    assert "</details>" in out


def test_render_trail_details_empty(capsys):
    _render_trail_details([], set(), set())
    assert capsys.readouterr().out == ""


def test_render_trail_details_no_orphans(capsys):
    entries = [{"timestamp": "T1", "phase": "p", "name": "n",
                "action": "completed", "sha": "x"}]
    _render_trail_details(entries, {("p", "n")}, {("p", "n")})
    assert "**Orphaned entries" not in capsys.readouterr().out


def _setup_report(tmp_path, monkeypatch, plan, trail, task=None):
    plan_file = tmp_path / "plan.json"
    trail_file = tmp_path / "trail.json"
    plan_file.write_text(json.dumps(plan))
    trail_file.write_text(json.dumps(trail))
    if task is not None:
        (tmp_path / "task.txt").write_text(task)
    monkeypatch.setenv("AT_HAS_PLAN", "yes")
    monkeypatch.setenv("AT_HAS_TRAIL", "yes")
    monkeypatch.setenv("AT_AUDIT_DIR", str(tmp_path))
    monkeypatch.setenv("AT_PLAN_FILE", str(plan_file))
    monkeypatch.setenv("AT_TRAIL_FILE", str(trail_file))


def test_render_report_full(tmp_path, monkeypatch, capsys):
    _setup_report(tmp_path, monkeypatch, PLAN,
                  {"plugin_version": "9.9.9", "entries": ENTRIES},
                  task="render the audit")
    _render_report()
    out = capsys.readouterr().out
    assert "### Execution Summary" in out
    assert "**Task:** render the audit" in out
    assert "**Plugin version:** 9.9.9" in out
    assert "### Execution Plan" in out
    assert "Audit Trail (4 entries)" in out


def test_render_report_no_plan_no_trail(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("AT_HAS_PLAN", "no")
    monkeypatch.setenv("AT_HAS_TRAIL", "no")
    monkeypatch.setenv("AT_AUDIT_DIR", str(tmp_path))
    _render_report()
    out = capsys.readouterr().out
    assert "### Execution Summary" in out
    assert "**Plugin version:** unknown" in out
    assert "### Execution Plan" not in out


def test_render_show_full(tmp_path, monkeypatch, capsys):
    trail_file = tmp_path / "trail.json"
    trail_file.write_text(json.dumps({"plugin_version": "1.0", "entries": ENTRIES}))
    monkeypatch.setenv("AT_TRAIL_FILE", str(trail_file))
    monkeypatch.setenv("AT_TASK", "show task")
    _render_show()
    out = capsys.readouterr().out
    assert "─── Audit Trail ───" in out
    assert "Task: show task" in out
    assert "Plugin: v1.0" in out
    assert "Entries: 4" in out
    assert "▶" in out and "✓" in out and "✗" in out
    assert "starting" in out


def test_render_show_empty_trail_no_task(tmp_path, monkeypatch, capsys):
    trail_file = tmp_path / "trail.json"
    trail_file.write_text("not json")
    monkeypatch.setenv("AT_TRAIL_FILE", str(trail_file))
    monkeypatch.delenv("AT_TASK", raising=False)
    _render_show()
    out = capsys.readouterr().out
    assert "Plugin: vunknown" in out
    assert "Entries: 0" in out
    assert "Task:" not in out


def test_render_show_unknown_action_and_raw_ts(tmp_path, monkeypatch, capsys):
    trail_file = tmp_path / "trail.json"
    trail_file.write_text(json.dumps({"entries": [{
        "timestamp": "raw", "phase": "p", "name": "n", "action": "weird"
    }]}))
    monkeypatch.setenv("AT_TRAIL_FILE", str(trail_file))
    monkeypatch.setenv("AT_TASK", "")
    _render_show()
    out = capsys.readouterr().out
    assert "?" in out
    assert "weird" in out


def test_main_unknown_mode(monkeypatch, capsys):
    monkeypatch.setenv("AT_MODE", "")
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 1
    assert "unknown AT_MODE" in capsys.readouterr().err


def test_main_show_mode(tmp_path, monkeypatch, capsys):
    trail_file = tmp_path / "trail.json"
    trail_file.write_text(json.dumps({"entries": []}))
    monkeypatch.setenv("AT_MODE", "show")
    monkeypatch.setenv("AT_TRAIL_FILE", str(trail_file))
    monkeypatch.setenv("AT_TASK", "")
    main()
    assert "─── Audit Trail ───" in capsys.readouterr().out


def test_main_report_subprocess(tmp_path):
    plan_file = tmp_path / "plan.json"
    trail_file = tmp_path / "trail.json"
    plan_file.write_text(json.dumps({"planned_phases": [
        {"order": 1, "phase": "build", "agent": "w", "skills": [], "reason": "r"}
    ]}))
    trail_file.write_text(json.dumps({"plugin_version": "1.0", "entries": []}))
    env = {**os.environ, "AT_MODE": "report", "AT_HAS_PLAN": "yes",
           "AT_HAS_TRAIL": "yes", "AT_AUDIT_DIR": str(tmp_path),
           "AT_PLAN_FILE": str(plan_file), "AT_TRAIL_FILE": str(trail_file)}
    script = Path(__file__).parent / "audit_render.py"
    result = subprocess.run(
        [sys.executable, str(script)], env=env, capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "### Execution Summary" in result.stdout
    assert "### Execution Plan" in result.stdout
