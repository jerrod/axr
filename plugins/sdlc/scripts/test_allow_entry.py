"""Tests for allow_entry.py — shared allow-list entry helpers."""

import allow_entry


def test_file_key_wins():
    assert allow_entry.entry_pattern({"file": "foo.py", "reason": "x"}) == "foo.py"


def test_pattern_key_second():
    assert allow_entry.entry_pattern({"pattern": "@patch", "reason": "x"}) == "@patch"


def test_branch_key_third():
    assert allow_entry.entry_pattern({"branch": "feat/*", "reason": "x"}) == "feat/*"


def test_type_key_fourth():
    assert allow_entry.entry_pattern({"type": "unused_import", "reason": "x"}) == "unused_import"


def test_reason_only_returns_empty():
    assert allow_entry.entry_pattern({"reason": "no identifier"}) == ""


def test_file_wins_over_pattern_when_both_present():
    entry = {"file": "a.py", "pattern": "b", "reason": "x"}
    assert allow_entry.entry_pattern(entry) == "a.py"


def test_empty_file_falls_through_to_pattern():
    entry = {"file": "", "pattern": "x", "reason": "r"}
    assert allow_entry.entry_pattern(entry) == "x"
