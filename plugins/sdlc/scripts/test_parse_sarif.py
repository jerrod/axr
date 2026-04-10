"""Tests for parse_sarif.py — SARIF v2.1.0 static analysis findings parser."""

import json
import os
import tempfile

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
