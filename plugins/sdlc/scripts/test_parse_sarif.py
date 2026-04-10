"""Tests for parse_sarif.py — SARIF v2.1.0 static analysis findings parser."""

import json
import os
import tempfile

import pytest

import parse_sarif as parse_sarif_mod
from parse_sarif import parse_sarif


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


def _write_sarif(data):
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".sarif", delete=False)
    json.dump(data, f)
    f.flush()
    f.close()
    return f.name


def _run(data, rule_prefix=None):
    """Write data, parse, clean up, return findings."""
    path = _write_sarif(data)
    try:
        return parse_sarif(path, rule_prefix=rule_prefix)
    finally:
        os.unlink(path)


def test_parse_all_findings():
    path = _write_sarif(SAMPLE_SARIF)
    try:
        result = parse_sarif(path)
        assert len(result) == 3
    finally:
        os.unlink(path)


def test_filter_by_rule_prefix():
    path = _write_sarif(SAMPLE_SARIF)
    try:
        result = parse_sarif(path, rule_prefix="complexity/")
        assert len(result) == 2
        assert all(f["rule_id"].startswith("complexity/") for f in result)
    finally:
        os.unlink(path)


def test_filter_by_style_prefix():
    path = _write_sarif(SAMPLE_SARIF)
    try:
        result = parse_sarif(path, rule_prefix="style/Unused")
        assert len(result) == 1
        assert result[0]["rule_id"] == "style/UnusedPrivateMember"
    finally:
        os.unlink(path)


def test_finding_structure():
    path = _write_sarif(SAMPLE_SARIF)
    try:
        result = parse_sarif(path, rule_prefix="complexity/Cyclomatic")
        assert len(result) == 1
        f = result[0]
        assert f["file"] == "src/main/kotlin/com/example/Service.kt"
        assert f["line"] == 42
        assert f["level"] == "warning"
        assert f["rule_id"] == "complexity/CyclomaticComplexMethod"
        assert "complexity 12" in f["message"]
    finally:
        os.unlink(path)


def test_parse_no_matching_files():
    result = parse_sarif("/nonexistent/*.sarif")
    assert result == []


def test_parse_empty_runs_array():
    assert _run({"version": "2.1.0", "runs": []}) == []


def test_parse_run_with_no_results():
    assert _run({"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}}]}) == []


def test_parse_result_missing_optional_fields():
    # No level, message, ruleId, or locations — defaults should fill in.
    result = _run({"version": "2.1.0", "runs": [{"results": [{}]}]})
    assert result == [{"file": "", "line": 0, "level": "warning", "rule_id": "", "message": ""}]


def test_parse_result_with_multiple_locations_uses_first():
    result = _run({"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "error", "message": {"text": "boom"},
        "locations": [
            {"physicalLocation": {"artifactLocation": {"uri": "first.kt"}, "region": {"startLine": 1}}},
            {"physicalLocation": {"artifactLocation": {"uri": "second.kt"}, "region": {"startLine": 99}}},
        ],
    }]}]})
    assert result[0]["file"] == "first.kt"
    assert result[0]["line"] == 1


def test_parse_result_levels_preserved():
    result = _run({"version": "2.1.0", "runs": [{"results": [
        {"ruleId": "a", "level": "error", "message": {"text": "e"}},
        {"ruleId": "b", "level": "note", "message": {"text": "n"}},
        {"ruleId": "c", "level": "none", "message": {"text": "x"}},
    ]}]})
    assert [f["level"] for f in result] == ["error", "note", "none"]


def test_parse_result_with_empty_locations_list():
    result = _run({"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"}, "locations": [],
    }]}]})
    assert result[0]["file"] == "" and result[0]["line"] == 0


def test_parse_result_location_missing_physical_location():
    result = _run({"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"}, "locations": [{}],
    }]}]})
    assert result[0]["file"] == "" and result[0]["line"] == 0


def test_parse_result_location_missing_region():
    result = _run({"version": "2.1.0", "runs": [{"results": [{
        "ruleId": "r", "level": "warning", "message": {"text": "m"},
        "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.kt"}}}],
    }]}]})
    assert result[0]["file"] == "a.kt" and result[0]["line"] == 0


def test_parse_missing_top_level_runs_key():
    assert _run({"version": "2.1.0"}) == []


def test_parse_invalid_json_raises():
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".sarif", delete=False)
    f.write("{not valid json")
    f.flush()
    f.close()
    try:
        with pytest.raises(json.JSONDecodeError):
            parse_sarif(f.name)
    finally:
        os.unlink(f.name)


def test_rule_prefix_filter_skips_missing_rule_id():
    # Result with no ruleId — should be filtered out when a prefix is given.
    result = _run({"version": "2.1.0", "runs": [{"results": [
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


def test_parse_glob_multiple_files():
    dir = tempfile.mkdtemp()
    sarif1 = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}, "results": [
        {"ruleId": "r1", "level": "warning", "message": {"text": "m1"},
         "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.kt"}, "region": {"startLine": 1}}}]}
    ]}]}
    sarif2 = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "t"}}, "results": [
        {"ruleId": "r2", "level": "error", "message": {"text": "m2"},
         "locations": [{"physicalLocation": {"artifactLocation": {"uri": "b.kt"}, "region": {"startLine": 2}}}]}
    ]}]}
    p1 = os.path.join(dir, "a.sarif")
    p2 = os.path.join(dir, "b.sarif")
    with open(p1, "w") as f:
        json.dump(sarif1, f)
    with open(p2, "w") as f:
        json.dump(sarif2, f)
    try:
        result = parse_sarif(os.path.join(dir, "*.sarif"))
        assert len(result) == 2
    finally:
        os.unlink(p1)
        os.unlink(p2)
        os.rmdir(dir)
