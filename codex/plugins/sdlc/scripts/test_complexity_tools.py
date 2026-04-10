"""Tests for complexity_tools.py — AST tool wrappers."""

import json
from unittest.mock import patch

from complexity_tools import (
    _run_gocyclo,
    _run_radon,
    _violations_from_gocyclo,
    _violations_from_oxlint,
    _violations_from_radon,
    analyze_go_files,
    analyze_js_ts_files,
    analyze_python_files,
)


# --- _run_radon ---


def test_run_radon_success():
    radon_output = json.dumps({"a.py": [{"name": "f", "lineno": 1, "endline": 5, "complexity": 2}]})
    mock_result = type("R", (), {"returncode": 0, "stdout": radon_output, "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        data = _run_radon(["a.py"])
    assert data is not None
    assert "a.py" in data


def test_run_radon_not_installed():
    with patch("complexity_tools.subprocess.run", side_effect=FileNotFoundError):
        assert _run_radon(["a.py"]) is None


# --- _violations_from_radon ---


def test_radon_length_violation():
    data = {"x.py": [{"name": "big", "lineno": 1, "endline": 60, "complexity": 2}]}
    violations = _violations_from_radon(data, 50, 8)
    assert len(violations) == 1
    assert violations[0]["type"] == "function_length"


def test_radon_no_violations():
    data = {"x.py": [{"name": "ok", "lineno": 1, "endline": 10, "complexity": 2}]}
    assert _violations_from_radon(data, 50, 8) == []


def test_radon_skips_class_entries():
    """Classes are not functions; their methods are counted independently.

    Including the enclosing class would double-count and falsely flag any
    multi-test class (e.g., TestJestVitest) against max_function_lines.
    Regression test for the TestJestVitest false positive.
    """
    data = {
        "test_parse_test_failures.py": [
            # A 75-line class — would be flagged against max_lines=50 if not skipped
            {
                "type": "class",
                "name": "TestJestVitest",
                "lineno": 27,
                "endline": 101,
                "complexity": 1,
            },
            # A method inside that class — small, should NOT be flagged
            {
                "type": "method",
                "name": "TestJestVitest.test_one",
                "lineno": 30,
                "endline": 40,
                "complexity": 2,
            },
            # Another method that IS too long — SHOULD be flagged
            {
                "type": "method",
                "name": "TestJestVitest.test_long",
                "lineno": 41,
                "endline": 100,
                "complexity": 2,
            },
        ]
    }
    violations = _violations_from_radon(data, 50, 8)
    # Exactly one violation: the 60-line method, NOT the 75-line class
    assert len(violations) == 1
    assert violations[0]["function"] == "TestJestVitest.test_long"
    assert violations[0]["type"] == "function_length"
    assert violations[0]["lines"] == 60
    # Make sure the class itself is not in the violations list
    assert not any(v["function"] == "TestJestVitest" for v in violations)


# --- _violations_from_oxlint ---


def test_oxlint_complexity_violation():
    data = {"diagnostics": [{
        "message": "function `f` has a complexity of 12. Maximum allowed is 8.",
        "code": "eslint(complexity)", "severity": "error",
        "filename": "x.ts", "labels": [],
    }]}
    violations = _violations_from_oxlint(data, 50, 8)
    assert len(violations) == 1
    assert violations[0]["complexity"] == 12


def test_oxlint_length_violation():
    data = {"diagnostics": [{
        "message": "The function `f` has too many lines (60). Maximum allowed is 50.",
        "code": "eslint(max-lines-per-function)", "severity": "error",
        "filename": "x.ts", "labels": [],
    }]}
    violations = _violations_from_oxlint(data, 50, 8)
    assert len(violations) == 1
    assert violations[0]["lines"] == 60


def test_oxlint_empty():
    assert _violations_from_oxlint({"diagnostics": []}, 50, 8) == []


# --- _violations_from_gocyclo ---


def test_gocyclo_parse():
    lines = ["9 pkg.F main.go:10:1"]
    violations = _violations_from_gocyclo(lines)
    assert violations[0]["complexity"] == 9
    assert violations[0]["file"] == "main.go"


def test_gocyclo_empty():
    assert _violations_from_gocyclo([]) == []


# --- _run_gocyclo ---


def test_run_gocyclo_success():
    mock_result = type("R", (), {"returncode": 1, "stdout": "9 pkg.F f.go:1:1\n", "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        lines = _run_gocyclo(["f.go"], 8)
    assert lines is not None
    assert len(lines) == 1


def test_run_gocyclo_not_installed():
    with patch("complexity_tools.subprocess.run", side_effect=FileNotFoundError):
        assert _run_gocyclo(["f.go"], 8) is None


def test_run_gocyclo_no_violations():
    mock_result = type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        lines = _run_gocyclo(["clean.go"], 8)
    assert lines == []


# --- analyze_python_files ---


def test_analyze_python_with_radon():
    radon_out = json.dumps({"a.py": [{"name": "f", "lineno": 1, "endline": 60, "complexity": 2}]})
    mock_result = type("R", (), {"returncode": 0, "stdout": radon_out, "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        violations = analyze_python_files(["a.py"], 50, 8)
    assert any(v["type"] == "function_length" for v in violations)


def test_analyze_python_fallback(tmp_path):
    filepath = str(tmp_path / "app.py")
    with open(filepath, "w") as f:
        f.write("def small():\n    pass\n")
    with patch("complexity_tools.subprocess.run", side_effect=FileNotFoundError):
        violations = analyze_python_files([filepath], 50, 8)
    assert violations == []


# --- analyze_js_ts_files ---


def test_analyze_js_ts_with_oxlint():
    oxlint_out = json.dumps({"diagnostics": [{
        "message": "function `f` has a complexity of 12. Maximum allowed is 8.",
        "code": "eslint(complexity)", "severity": "error",
        "filename": "x.ts", "labels": [],
    }]})
    mock_result = type("R", (), {"returncode": 1, "stdout": oxlint_out, "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        violations = analyze_js_ts_files(["x.ts"], 50, 8)
    assert len(violations) == 1


def test_analyze_js_ts_fallback(tmp_path):
    filepath = str(tmp_path / "x.ts")
    with open(filepath, "w") as f:
        f.write("function f() { return 1; }\n")
    with patch("complexity_tools.subprocess.run", side_effect=FileNotFoundError):
        violations = analyze_js_ts_files([filepath], 50, 8)
    assert violations == []


# --- analyze_go_files ---


def test_analyze_go_with_gocyclo():
    mock_result = type("R", (), {"returncode": 1, "stdout": "9 pkg.F f.go:1:1\n", "stderr": ""})()
    with patch("complexity_tools.subprocess.run", return_value=mock_result):
        violations = analyze_go_files(["f.go"], None, 8)
    assert any(v["type"] == "cyclomatic_complexity" for v in violations)


def test_analyze_go_fallback(tmp_path):
    filepath = str(tmp_path / "main.go")
    with open(filepath, "w") as f:
        f.write("func small() {\n\tx := 1\n}\n")
    with patch("complexity_tools.subprocess.run", side_effect=FileNotFoundError):
        violations = analyze_go_files([filepath], 50, 8)
    assert violations == []
