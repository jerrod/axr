"""Tests for render_exceptions.py — every function, every branch, in-process."""
import json

import pytest

import render_exceptions
from allow_entry import entry_key
from render_exceptions import (
    _collect_active, _find_stale, _load_config,
    _print_table, _resolve_config_file, _stale_for_gate, main,
)


def _write_jsonl(path, records):
    with open(path, "w") as f:
        for rec in records:
            f.write(json.dumps(rec) + "\n")


def test_entry_key_excludes_reason_field():
    assert entry_key({"file": "foo.py", "reason": "legacy"}) == '{"file": "foo.py"}'


def test_entry_key_sorted_canonical_independent_of_insertion_order():
    a = entry_key({"file": "x.py", "name": "bar", "type": "var"})
    b = entry_key({"type": "var", "name": "bar", "file": "x.py"})
    assert a == b == '{"file": "x.py", "name": "bar", "type": "var"}'


def test_entry_key_with_only_reason_is_empty_object():
    assert entry_key({"reason": "r"}) == "{}"


def test_load_config_empty_path_returns_empty_dict():
    assert _load_config("") == {}


def test_load_config_nonexistent_file_returns_empty_dict(tmp_path):
    assert _load_config(str(tmp_path / "missing.json")) == {}


def test_load_config_directory_path_returns_empty_dict(tmp_path):
    # os.path.isfile() is False for directories → returns {}.
    assert _load_config(str(tmp_path)) == {}


def test_load_config_happy_path(tmp_path):
    path = tmp_path / "cfg.json"
    payload = {"allow": {"filesize": [{"file": "big.py", "reason": "legacy"}]}}
    path.write_text(json.dumps(payload))
    assert _load_config(str(path)) == payload


def test_load_config_malformed_json_returns_empty_dict(tmp_path):
    path = tmp_path / "bad.json"
    path.write_text("{not valid json")
    assert _load_config(str(path)) == {}


def test_collect_active_empty_dir_returns_empty(tmp_path):
    assert _collect_active(str(tmp_path)) == ([], {})


def test_collect_active_dedupes_repeated_entry_keys_across_multiple_gates(tmp_path):
    dup = {"entry_key": '{"file": "a.py"}', "file": "a.py", "reason": "r1"}
    _write_jsonl(tmp_path / "allow-tracking-filesize.jsonl", [dup, dup])
    _write_jsonl(
        tmp_path / "allow-tracking-complexity.jsonl",
        [{"entry_key": '{"file": "hard.py"}', "file": "hard.py"}],
    )
    active, matched = _collect_active(str(tmp_path))
    assert len(active) == 2
    assert {r["file"] for r in active} == {"a.py", "hard.py"}
    assert matched == {
        "filesize": {'{"file": "a.py"}'},
        "complexity": {'{"file": "hard.py"}'},
    }


def test_collect_active_skips_malformed_json_lines(tmp_path):
    path = tmp_path / "allow-tracking-filesize.jsonl"
    with open(path, "w") as f:
        f.write("{not json\n")
        f.write(json.dumps({"entry_key": '{"file": "ok.py"}', "file": "ok.py"}) + "\n")
        f.write("also garbage\n")
    active, matched = _collect_active(str(tmp_path))
    assert [r["file"] for r in active] == ["ok.py"]
    assert matched == {"filesize": {'{"file": "ok.py"}'}}


def test_collect_active_record_without_entry_key_tracked_in_matched_only(tmp_path):
    # Missing entry_key → key is "", added to matched but skipped for active
    # (the `if key and key not in seen_keys` short-circuits on empty string).
    _write_jsonl(tmp_path / "allow-tracking-filesize.jsonl", [{"file": "orphan.py"}])
    active, matched = _collect_active(str(tmp_path))
    assert active == []
    assert matched == {"filesize": {""}}


def test_collect_active_unreadable_file_skipped(tmp_path, monkeypatch):
    # Force open() to raise for this specific tracking file so the OSError
    # branch in _collect_active is exercised.
    target = tmp_path / "allow-tracking-filesize.jsonl"
    target.write_text("")
    real_open = open

    def fake_open(path, *a, **kw):
        if str(path) == str(target):
            raise OSError("permission denied")
        return real_open(path, *a, **kw)

    monkeypatch.setattr("builtins.open", fake_open)
    active, matched = _collect_active(str(tmp_path))
    # Gate key was initialized before the OSError; active is empty.
    assert active == []
    assert matched == {"filesize": set()}


def test_stale_for_gate_matched_entry_excluded():
    entries = [{"file": "matched.py", "reason": "live"}]
    assert _stale_for_gate("filesize", entries, {entry_key(entries[0])}) == []


@pytest.mark.parametrize("entry,pattern", [
    ({"file": "stale.py", "reason": "old"}, "stale.py"),
    ({"pattern": "**/*.legacy", "reason": "x"}, "**/*.legacy"),
    ({"branch": "release/2025-q1", "reason": "freeze"}, "release/2025-q1"),
    ({"type": "unused_variable", "reason": "x"}, "unused_variable"),
])
def test_stale_for_gate_resolves_pattern_via_entry_pattern_helper(entry, pattern):
    # Finding 2: branch key must resolve too. Helper is owned by allow_entry.
    result = _stale_for_gate("g", [entry], set())
    assert result == [{"gate": "g", "pattern": pattern, "reason": entry["reason"]}]


def test_stale_for_gate_entry_without_identifiable_field_is_dropped():
    # No file / pattern / type → pattern is "" → skipped.
    assert _stale_for_gate("lint", [{"reason": "mystery"}], set()) == []


def test_stale_for_gate_mixed_matched_and_stale():
    entries = [
        {"file": "live.py", "reason": "active"},
        {"file": "dead.py", "reason": "stale"},
    ]
    result = _stale_for_gate("filesize", entries, {entry_key(entries[0])})
    assert result == [{"gate": "filesize", "pattern": "dead.py", "reason": "stale"}]


def test_stale_for_gate_missing_reason_defaults_to_empty_string():
    assert _stale_for_gate("filesize", [{"file": "x.py"}], set()) == [
        {"gate": "filesize", "pattern": "x.py", "reason": ""}
    ]


def test_find_stale_no_config_file_returns_empty(tmp_path):
    assert _find_stale(str(tmp_path / "missing.json"), {"filesize": set()}) == []


def test_find_stale_gate_with_no_tracking_file_flags_all_entries(tmp_path):
    # Finding 1: gates absent from matched_keys_per_gate (because they wrote
    # no tracking file — i.e., zero violations) must still have their allow
    # entries checked. Otherwise stale-detection silently skips precisely the
    # case it's meant to catch.
    path = tmp_path / "cfg.json"
    path.write_text(json.dumps({"allow": {"filesize": [{"file": "x.py"}]}}))
    assert _find_stale(str(path), {"lint": set()}) == [
        {"gate": "filesize", "pattern": "x.py", "reason": ""}
    ]


def test_find_stale_returns_unmatched_entries(tmp_path):
    live = {"file": "live.py", "reason": "a"}
    dead = {"file": "dead.py", "reason": "b"}
    path = tmp_path / "cfg.json"
    path.write_text(json.dumps({"allow": {"filesize": [live, dead]}}))
    matched = {"filesize": {entry_key(live)}}
    assert _find_stale(str(path), matched) == [
        {"gate": "filesize", "pattern": "dead.py", "reason": "b"}
    ]


def test_find_stale_config_without_allow_key(tmp_path):
    path = tmp_path / "cfg.json"
    path.write_text(json.dumps({"other": "data"}))
    assert _find_stale(str(path), {"filesize": set()}) == []


def test_print_table_empty_rows_prints_nothing(capsys):
    _print_table("Title", "desc", [])
    assert capsys.readouterr().out == ""


def test_print_table_renders_header_count_description_and_row(capsys):
    _print_table(
        "Active",
        "Desc here.",
        [{"gate": "filesize", "pattern": "big.py", "reason": "legacy"}],
    )
    out = capsys.readouterr().out
    assert "## Active (1)" in out
    assert "Desc here." in out
    assert "| Gate | Pattern | Reason |" in out
    assert "|------|---------|--------|" in out
    assert "| filesize | `big.py` | legacy |" in out


@pytest.mark.parametrize("row,expected", [
    # Pipe escaping in pattern and reason fields.
    ({"gate": "g", "pattern": "a|b", "reason": "x|y"}, "| g | `a\\|b` | x\\|y |"),
    # Missing pattern/reason render as empty strings, no crash.
    ({"gate": "g"}, "| g | `` |  |"),
    # Finding 3: missing "gate" key falls back to "unknown" (no KeyError).
    ({"pattern": "p", "reason": "r"}, "| unknown | `p` | r |"),
    # Finding 4: pipe in gate field is escaped like pattern/reason.
    ({"gate": "a|b", "pattern": "p", "reason": "r"}, "| a\\|b | `p` | r |"),
])
def test_print_table_row_rendering(capsys, row, expected):
    _print_table("T", "D", [row])
    assert expected in capsys.readouterr().out


def test_print_table_row_count_reflects_row_length(capsys):
    rows = [{"gate": f"g{i}", "pattern": "p", "reason": "r"} for i in range(3)]
    _print_table("Many", "D", rows)
    assert "## Many (3)" in capsys.readouterr().out


def test_resolve_config_file_from_env(monkeypatch):
    monkeypatch.setenv("SDLC_CONFIG_FILE", "/path/to/custom.json")
    assert _resolve_config_file() == "/path/to/custom.json"


def test_resolve_config_file_prefers_sdlc_over_dot_sdlc(tmp_path, monkeypatch):
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    monkeypatch.chdir(tmp_path)
    (tmp_path / "sdlc.config.json").write_text("{}")
    (tmp_path / ".sdlc.config.json").write_text("{}")
    assert _resolve_config_file() == "sdlc.config.json"


def test_resolve_config_file_finds_dot_sdlc_when_no_plain(tmp_path, monkeypatch):
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".sdlc.config.json").write_text("{}")
    assert _resolve_config_file() == ".sdlc.config.json"


def test_resolve_config_file_no_candidates_returns_empty(tmp_path, monkeypatch):
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    monkeypatch.chdir(tmp_path)
    assert _resolve_config_file() == ""


def test_main_empty_proof_dir_prints_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PROOF_DIR", str(tmp_path))
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    main()
    assert capsys.readouterr().out == ""


def test_main_active_and_stale_both_rendered(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    proof_dir = tmp_path / "proof"
    proof_dir.mkdir()
    live = {"file": "live.py", "reason": "active"}
    dead = {"file": "dead.py", "reason": "obsolete"}
    tracking = {"gate": "filesize", "pattern": "live.py",
                "entry_key": entry_key(live), **live}
    _write_jsonl(proof_dir / "allow-tracking-filesize.jsonl", [tracking])
    (tmp_path / "sdlc.config.json").write_text(
        json.dumps({"allow": {"filesize": [live, dead]}})
    )
    monkeypatch.setenv("PROOF_DIR", str(proof_dir))
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    main()
    out = capsys.readouterr().out
    assert "## Active Exceptions (1)" in out
    assert "live.py" in out
    assert "## Stale Exceptions (1)" in out
    assert "dead.py" in out
    assert "obsolete" in out


def test_module_runs_as_main(tmp_path, monkeypatch, capsys):
    import runpy
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PROOF_DIR", str(tmp_path))
    monkeypatch.delenv("SDLC_CONFIG_FILE", raising=False)
    monkeypatch.setattr("sys.argv", ["render_exceptions.py"])
    runpy.run_path(render_exceptions.__file__, run_name="__main__")
    assert capsys.readouterr().out == ""
