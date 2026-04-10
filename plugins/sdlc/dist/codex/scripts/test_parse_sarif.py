"""Tests for parse_sarif.py — SARIF v2.1.0 static analysis findings parser."""

import json
import os

import pytest

import parse_sarif as parse_sarif_mod
from parse_sarif import parse_sarif


@pytest.fixture
def sarif_writer(tmp_path):
    """Return a function that writes SARIF JSON to tmp_path and returns its path."""
    counter = {"n": 0}

    def _write(data, name=None):
        counter["n"] += 1
        path = tmp_path / (name or f"report-{counter['n']}.sarif")
        path.write_text(json.dumps(data))
        return str(path)

    return _write


SAMPLE_SARIF = {
    "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
    "version": "2.1.0",
    "runs": [{
        "tool": {"driver": {"name": "detekt", "version": "1.23.8"}},
        "results": [
            {
                "ruleId": "complexity/CyclomaticComplexMethod",
                "level": "warning",
                "message": {"text": "Function processData has complexity 12."},
                "locations": [{
                    "physicalLocation": {
                        "artifactLocation": {"uri": "src/main/kotlin/com/example/Service.kt"},
                        "region": {"startLine": 42}
                    }
                }]
            },
            {
                "ruleId": "style/UnusedPrivateMember",
                "level": "warning",
                "message": {"text": "Private member 'helper' is unused."},
                "locations": [{
                    "physicalLocation": {
                        "artifactLocation": {"uri": "src/main/kotlin/com/example/Service.kt"},
                        "region": {"startLine": 100}
                    }
                }]
            },
            {
                "ruleId": "complexity/LongMethod",
                "level": "warning",
                "message": {"text": "Function build has 65 lines."},
                "locations": [{
                    "physicalLocation": {
                        "artifactLocation": {"uri": "src/main/kotlin/com/example/Builder.kt"},
                        "region": {"startLine": 10}
                    }
                }]
            }
        ]
    }]
}


def _run(sarif_writer, data, rule_prefix=None):
    """Write data, parse, return findings (cleanup via tmp_path fixture)."""
    path = sarif_writer(data)
    return parse_sarif(path, rule_prefix=rule_prefix)


def test_parse_all_findings(sarif_writer):
    result = _run(sarif_writer, SAMPLE_SARIF)
    assert len(result) == 3


def test_filter_by_rule_prefix(sarif_writer):
    result = _run(sarif_writer, SAMPLE_SARIF, rule_prefix="complexity/")
    assert len(result) == 2
    assert all(f["rule_id"].startswith("complexity/") for f in result)


def test_filter_by_style_prefix(sarif_writer):
    result = _run(sarif_writer, SAMPLE_SARIF, rule_prefix="style/Unused")
    assert len(result) == 1
    assert result[0]["rule_id"] == "style/UnusedPrivateMember"


def test_finding_structure(sarif_writer):
    result = _run(sarif_writer, SAMPLE_SARIF, rule_prefix="complexity/Cyclomatic")
    assert len(result) == 1
    f = result[0]
    assert f["file"] == "src/main/kotlin/com/example/Service.kt"
    assert f["line"] == 42
    assert f["level"] == "warning"
    assert f["rule_id"] == "complexity/CyclomaticComplexMethod"
    assert "complexity 12" in f["message"]


def test_parse_no_matching_files():
    result = parse_sarif("/nonexistent/*.sarif")
    assert result == []


def test_parse_empty_runs_array(sarif_writer):
    assert _run(sarif_writer, {"version": "2.1.0", "runs": []}) == []


def test_parse_run_with_no_results(sarif_writer):
    assert _run(sarif_writer, {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}}]}) == []


def test_parse_result_missing_optional_fields(sarif_writer):
    # No level, message, ruleId, or locations — defaults should fill in.
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [{}]}]})
    assert result == [{"file": "", "line": 0, "level": "warning", "rule_id": "", "message": ""}]


def test_parse_result_with_multiple_locations_uses_first(sarif_writer):
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "error", "message": {"text": "boom"},
        "locations": [
            {"physicalLocation": {"artifactLocation": {"uri": "first.kt"}, "region": {"startLine": 1}}},
            {"physicalLocation": {"artifactLocation": {"uri": "second.kt"}, "region": {"startLine": 99}}},
        ],
    }]}]})
    assert result[0]["file"] == "first.kt"
    assert result[0]["line"] == 1


def test_parse_result_levels_preserved(sarif_writer):
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [
        {"ruleId": "a", "level": "error", "message": {"text": "e"}},
        {"ruleId": "b", "level": "note", "message": {"text": "n"}},
        {"ruleId": "c", "level": "none", "message": {"text": "x"}},
    ]}]})
    assert [f["level"] for f in result] == ["error", "note", "none"]


def test_parse_result_with_empty_locations_list(sarif_writer):
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"}, "locations": [],
    }]}]})
    assert result[0]["file"] == "" and result[0]["line"] == 0


def test_parse_result_location_missing_physical_location(sarif_writer):
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"}, "locations": [{}],
    }]}]})
    assert result[0]["file"] == "" and result[0]["line"] == 0


def test_parse_result_location_missing_region(sarif_writer):
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"},
        "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.kt"}}}],
    }]}]})
    assert result[0]["file"] == "a.kt" and result[0]["line"] == 0


def test_parse_missing_top_level_runs_key(sarif_writer):
    assert _run(sarif_writer, {"version": "2.1.0"}) == []


def test_parse_invalid_json_raises(tmp_path):
    path = tmp_path / "bad.sarif"
    path.write_text("{not valid json")
    with pytest.raises(json.JSONDecodeError):
        parse_sarif(str(path))


def test_rule_prefix_filter_skips_missing_rule_id(sarif_writer):
    # Result with no ruleId — should be filtered out when a prefix is given.
    result = _run(sarif_writer, {"version": "2.1.0", "runs": [{"results": [
        {"level": "warning", "message": {"text": "no rule"}},
        {"ruleId": "keep/me", "level": "warning", "message": {"text": "yes"}},
    ]}]}, rule_prefix="keep/")
    assert len(result) == 1 and result[0]["rule_id"] == "keep/me"


# --- __main__ entrypoint — exercised via runpy so coverage sees the real block ---
_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(parse_sarif_mod.__file__)),
    "parse_sarif.py",
)


def test_main_no_args_exits_with_usage(monkeypatch, capsys):
    import runpy

    monkeypatch.setattr("sys.argv", ["parse_sarif.py"])
    with pytest.raises(SystemExit) as exc:
        runpy.run_path(_MODULE_PATH, run_name="__main__")
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "Usage" in err


def test_main_with_glob_prints_findings(tmp_path, monkeypatch, capsys):
    import runpy

    path = tmp_path / "report.sarif"
    path.write_text(json.dumps(SAMPLE_SARIF))
    monkeypatch.setattr("sys.argv", ["parse_sarif.py", str(path)])
    runpy.run_path(_MODULE_PATH, run_name="__main__")
    out = capsys.readouterr().out
    parsed = json.loads(out)
    assert len(parsed) == 3
    assert all("rule_id" in f for f in parsed)


def test_main_with_rule_prefix_filters(tmp_path, monkeypatch, capsys):
    import runpy

    path = tmp_path / "report.sarif"
    path.write_text(json.dumps(SAMPLE_SARIF))
    monkeypatch.setattr("sys.argv", ["parse_sarif.py", str(path), "complexity/"])
    runpy.run_path(_MODULE_PATH, run_name="__main__")
    out = capsys.readouterr().out
    parsed = json.loads(out)
    assert len(parsed) == 2
    assert all(f["rule_id"].startswith("complexity/") for f in parsed)


def test_parse_glob_multiple_files(tmp_path):
    sarif1 = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}, "results": [
        {"ruleId": "r1", "level": "warning", "message": {"text": "m1"},
         "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.kt"}, "region": {"startLine": 1}}}]}
    ]}]}
    sarif2 = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}, "results": [
        {"ruleId": "r2", "level": "error", "message": {"text": "m2"},
         "locations": [{"physicalLocation": {"artifactLocation": {"uri": "b.kt"}, "region": {"startLine": 2}}}]}
    ]}]}
    (tmp_path / "a.sarif").write_text(json.dumps(sarif1))
    (tmp_path / "b.sarif").write_text(json.dumps(sarif2))
    result = parse_sarif(os.path.join(str(tmp_path), "*.sarif"))
    assert len(result) == 2
