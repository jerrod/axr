"""Tests for parse_simplecov.py — exercises every branch with inline JSON fixtures."""
import json
import os

import pytest

import parse_simplecov
from parse_simplecov import (
    _compute_percentage,
    _extract_lines,
    _file_entry,
    _normalize_path,
    parse,
)


# --- _extract_lines ---
def test_extract_lines_dict_form_returns_lines_key():
    assert _extract_lines({"lines": [1, 0, None]}) == [1, 0, None]


def test_extract_lines_dict_form_missing_lines_key_returns_empty():
    assert _extract_lines({}) == []


def test_extract_lines_flat_array_form_returned_as_is():
    assert _extract_lines([1, 1, 0, None]) == [1, 1, 0, None]


# --- _compute_percentage ---
def test_compute_percentage_all_lines_covered():
    assert _compute_percentage([1, 1, 1, 1]) == 100.0


def test_compute_percentage_half_covered():
    assert _compute_percentage([1, 0, 1, 0]) == 50.0


def test_compute_percentage_ignores_none_lines():
    # None = non-relevant (comment/blank). Only 2 relevant lines, 1 covered = 50%.
    assert _compute_percentage([None, 1, None, 0]) == 50.0


def test_compute_percentage_empty_array_returns_100():
    assert _compute_percentage([]) == 100.0


def test_compute_percentage_only_none_lines_returns_100():
    # A file with no executable lines is considered fully covered.
    assert _compute_percentage([None, None, None]) == 100.0


def test_compute_percentage_zero_covered_lines():
    assert _compute_percentage([0, 0, 0]) == 0.0


# --- _normalize_path ---
def test_normalize_path_strips_cwd_prefix():
    assert _normalize_path("/repo/lib/foo.rb", "/repo") == "lib/foo.rb"


def test_normalize_path_leaves_paths_outside_cwd_unchanged():
    assert _normalize_path("/other/place/bar.rb", "/repo") == "/other/place/bar.rb"


def test_normalize_path_does_not_strip_partial_prefix_match():
    # "/repo2" must not be stripped when cwd is "/repo".
    assert _normalize_path("/repo2/x.rb", "/repo") == "/repo2/x.rb"


# --- _file_entry ---
def test_file_entry_dict_form():
    entry = _file_entry({"lines": [1, 1, 0, 1]})
    assert entry == {"lines": {"pct": 75.0}}


def test_file_entry_flat_form():
    entry = _file_entry([1, 1, 1, 1])
    assert entry == {"lines": {"pct": 100.0}}


def test_file_entry_rounds_to_two_decimals():
    # 1 of 3 = 33.333...%, should round to 33.33
    entry = _file_entry([1, 0, 0])
    assert entry == {"lines": {"pct": 33.33}}


# --- parse — end-to-end with real JSON files ---
def _write_json(tmp_path, payload):
    path = tmp_path / "resultset.json"
    path.write_text(json.dumps(payload))
    return str(path)


def test_parse_happy_path_dict_line_form(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/lib/foo.rb": {"lines": [1, 1, None, 0, 1, 1, 0, 1]},
            },
            "timestamp": 1700000000,
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    # 7 relevant lines (None skipped), 5 covered = 71.43%
    assert result == {"lib/foo.rb": {"lines": {"pct": 71.43}}}


def test_parse_happy_path_flat_array_form(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "Minitest": {
            "coverage": {
                f"{cwd}/app/bar.rb": [1, 1, 1, 1],
            },
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {"app/bar.rb": {"lines": {"pct": 100.0}}}


def test_parse_multiple_files_in_one_suite(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/a.rb": {"lines": [1, 1]},
                f"{cwd}/b.rb": {"lines": [0, 0]},
            }
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {
        "a.rb": {"lines": {"pct": 100.0}},
        "b.rb": {"lines": {"pct": 0.0}},
    }


def test_parse_multiple_suites_merged(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/a.rb": {"lines": [1, 1]},
            }
        },
        "Cucumber": {
            "coverage": {
                f"{cwd}/b.rb": {"lines": [1, 0]},
            }
        },
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result["a.rb"] == {"lines": {"pct": 100.0}}
    assert result["b.rb"] == {"lines": {"pct": 50.0}}


def test_parse_suite_without_coverage_key(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    payload = {"RSpec": {"timestamp": 1700000000}}
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {}


def test_parse_empty_file_list(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    payload = {"RSpec": {"coverage": {}}}
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {}


def test_parse_file_with_zero_relevant_lines(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/blank.rb": {"lines": [None, None, None]},
            }
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {"blank.rb": {"lines": {"pct": 100.0}}}


def test_parse_file_with_no_covered_lines(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/dead.rb": {"lines": [0, 0, 0, 0]},
            }
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {"dead.rb": {"lines": {"pct": 0.0}}}


def test_parse_absolute_paths_outside_cwd_preserved(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                "/elsewhere/gem.rb": {"lines": [1, 1]},
            }
        }
    }
    path = _write_json(tmp_path, payload)
    result = parse(path)
    assert result == {"/elsewhere/gem.rb": {"lines": {"pct": 100.0}}}


def test_parse_malformed_json_raises(tmp_path):
    path = tmp_path / "bad.json"
    path.write_text("{not valid json")
    with pytest.raises(json.JSONDecodeError):
        parse(str(path))


def test_parse_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        parse(str(tmp_path / "does_not_exist.json"))


# --- __main__ entrypoint — exercised via runpy so coverage sees the real block ---
_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(parse_simplecov.__file__)),
    "parse_simplecov.py",
)


def test_main_no_args_prints_empty_object(monkeypatch, capsys):
    import runpy

    monkeypatch.setattr("sys.argv", ["parse_simplecov.py"])
    with pytest.raises(SystemExit) as exc:
        runpy.run_path(_MODULE_PATH, run_name="__main__")
    assert exc.value.code == 0
    out = capsys.readouterr().out.strip()
    assert out == "{}"


def test_main_with_arg_prints_parsed_json(tmp_path, monkeypatch, capsys):
    import runpy

    monkeypatch.chdir(tmp_path)
    cwd = str(tmp_path)
    payload = {
        "RSpec": {
            "coverage": {
                f"{cwd}/x.rb": {"lines": [1, 1, 0]},
            }
        }
    }
    path = _write_json(tmp_path, payload)
    monkeypatch.setattr("sys.argv", ["parse_simplecov.py", path])
    runpy.run_path(_MODULE_PATH, run_name="__main__")
    out = capsys.readouterr().out.strip()
    parsed = json.loads(out)
    assert parsed == {"x.rb": {"lines": {"pct": 66.67}}}
