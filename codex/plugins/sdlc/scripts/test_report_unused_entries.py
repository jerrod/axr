"""Tests for report_unused_entries.py — stale allow-list entry warnings.

Plain top-level `import report_unused_entries` so coverage tracks the
source module and find_affected_tests.py picks up the dependency.
conftest.py adds SCRIPTS_DIR to sys.path before test collection.
"""

from __future__ import annotations

import json

import report_unused_entries


def _run_main(allow_config, gate, tracking_content, tmp_path):
    """Write tracking file and invoke main() in-process. Returns returncode."""
    tf = tmp_path / f"allow-tracking-{gate}.jsonl"
    tf.write_text(tracking_content)
    return report_unused_entries.main(
        ["prog", json.dumps(allow_config), gate, str(tf)]
    )


def test_no_entries_for_gate_no_output(tmp_path, capsys):
    rc = _run_main({}, "filesize", "", tmp_path)
    assert rc == 0
    assert capsys.readouterr().err == ""


def test_entry_matched_not_reported(tmp_path, capsys):
    cfg = {"filesize": [{"file": "a.txt", "reason": "long enough reason text"}]}
    key = json.dumps({"file": "a.txt"}, sort_keys=True)
    tracking = json.dumps({"entry_key": key}) + "\n"
    rc = _run_main(cfg, "filesize", tracking, tmp_path)
    assert rc == 0
    assert "never matched" not in capsys.readouterr().err


def test_unmatched_entry_reported(tmp_path, capsys):
    cfg = {"filesize": [{"file": "missing.txt", "reason": "long enough reason text"}]}
    rc = _run_main(cfg, "filesize", "", tmp_path)
    assert rc == 0
    err = capsys.readouterr().err
    assert "never matched" in err
    assert "missing.txt" in err


def test_duplicate_patterns_different_names_tracked_independently(tmp_path, capsys):
    # Two dead-code entries with same file but different names — only one matched
    cfg = {
        "dead-code": [
            {
                "file": "a.py",
                "name": "foo",
                "type": "unused_import",
                "reason": "r1 is long enough",
            },
            {
                "file": "a.py",
                "name": "bar",
                "type": "unused_import",
                "reason": "r2 is long enough",
            },
        ]
    }
    matched_key = json.dumps(
        {"file": "a.py", "name": "foo", "type": "unused_import"}, sort_keys=True
    )
    tracking = json.dumps({"entry_key": matched_key}) + "\n"
    _run_main(cfg, "dead-code", tracking, tmp_path)
    err = capsys.readouterr().err
    assert "never matched" in err
    assert "r2 is long enough" in err
    assert "r1 is long enough" not in err


def test_invalid_json_lines_skipped(tmp_path, capsys):
    cfg = {"filesize": [{"file": "a.txt", "reason": "long enough reason text"}]}
    tracking = "not json\n" + json.dumps({"entry_key": "x"}) + "\n"
    _run_main(cfg, "filesize", tracking, tmp_path)
    # a.txt not in tracking → should be reported
    assert "a.txt" in capsys.readouterr().err


def test_missing_tracking_file_all_reported(tmp_path, capsys):
    cfg = {"filesize": [{"file": "a.txt", "reason": "long enough reason text"}]}
    rc = report_unused_entries.main(
        ["prog", json.dumps(cfg), "filesize", str(tmp_path / "missing.jsonl")]
    )
    assert rc == 0
    assert "a.txt" in capsys.readouterr().err


def test_empty_pattern_entry_skipped(tmp_path, capsys):
    # A stale entry with ONLY a "reason" (no file/pattern/branch/type) would
    # produce pattern="" and should be silently skipped rather than reported
    # with an empty pattern string.
    cfg = {"filesize": [{"reason": "reason-only entry — no identifier fields"}]}
    _run_main(cfg, "filesize", "", tmp_path)
    # No "never matched" warning — the entry has no identifier to display
    assert "never matched" not in capsys.readouterr().err


def test_branch_entry_reported_as_stale(tmp_path, capsys):
    # A branch_reason entry (allow.plan, allow.review) that never matched
    # should be reported with the branch as the pattern.
    cfg = {"plan": [{"branch": "feat/retired", "reason": "tracked separately"}]}
    _run_main(cfg, "plan", "", tmp_path)
    err = capsys.readouterr().err
    assert "never matched" in err
    assert "feat/retired" in err
