"""Tests for parse_junit_xml.py — JUnit XML test report parser."""

import json
import os
import subprocess
import sys
import tempfile

import pytest

from parse_junit_xml import parse_junit_xml


SAMPLE_PASSING = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="com.example.FooTest" tests="3" failures="0" errors="0" skipped="0">
  <testcase classname="com.example.FooTest" name="testAdd" time="0.012"/>
  <testcase classname="com.example.FooTest" name="testSubtract" time="0.008"/>
  <testcase classname="com.example.FooTest" name="testMultiply" time="0.005"/>
</testsuite>
"""

SAMPLE_FAILURES = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="com.example.BarTest" tests="2" failures="1" errors="0" skipped="1">
  <testcase classname="com.example.BarTest" name="testOk" time="0.010"/>
  <testcase classname="com.example.BarTest" name="testBroken" time="0.020">
    <failure message="expected 42 but got 0">
      java.lang.AssertionError: expected 42 but got 0
        at com.example.BarTest.testBroken(BarTest.kt:15)
    </failure>
  </testcase>
  <testcase classname="com.example.BarTest" name="testSkipped" time="0.000">
    <skipped/>
  </testcase>
</testsuite>
"""

SAMPLE_MULTI_FILE_TESTSUITES = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Suite1" tests="1" failures="0">
    <testcase classname="Suite1" name="test1"/>
  </testsuite>
  <testsuite name="Suite2" tests="1" failures="1">
    <testcase classname="Suite2" name="test2">
      <failure message="fail"/>
    </testcase>
  </testsuite>
</testsuites>
"""


def _write_xml(content):
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False)
    f.write(content)
    f.flush()
    f.close()
    return f.name


def test_parse_all_passing():
    path = _write_xml(SAMPLE_PASSING)
    try:
        result = parse_junit_xml(path)
        assert result["total"] == 3
        assert result["passed"] == 3
        assert result["failed"] == 0
        assert result["skipped"] == 0
        assert result["errored"] == 0
        assert result["failures"] == []
    finally:
        os.unlink(path)


def test_parse_with_failure_and_skip():
    path = _write_xml(SAMPLE_FAILURES)
    try:
        result = parse_junit_xml(path)
        assert result["total"] == 3  # 3 testcase elements (ok + broken + skipped)
        assert result["passed"] == 1
        assert result["failed"] == 1
        assert result["skipped"] == 1
        assert len(result["failures"]) == 1
        assert result["failures"][0]["test"] == "com.example.BarTest.testBroken"
        assert "expected 42" in result["failures"][0]["message"]
    finally:
        os.unlink(path)


def test_parse_testsuites_wrapper():
    path = _write_xml(SAMPLE_MULTI_FILE_TESTSUITES)
    try:
        result = parse_junit_xml(path)
        assert result["total"] == 2
        assert result["failed"] == 1
        assert len(result["failures"]) == 1
    finally:
        os.unlink(path)


SAMPLE_WITH_ERROR = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="ErrTest" tests="1" failures="0" errors="1">
  <testcase classname="ErrTest" name="testBoom">
    <error message="NullPointerException">stack trace here</error>
  </testcase>
</testsuite>
"""

SAMPLE_ERROR_NO_MESSAGE_NO_CLASSNAME = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="ErrTest" tests="1" failures="0" errors="1">
  <testcase name="bareTest">
    <error>raw body text</error>
  </testcase>
</testsuite>
"""

SAMPLE_FAILURE_AND_ERROR = """\
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="Both" tests="1" failures="1" errors="1">
  <testcase classname="Both" name="testBoth">
    <failure message="failed first"/>
    <error message="also errored"/>
  </testcase>
</testsuite>
"""

SAMPLE_UNKNOWN_ROOT = """\
<?xml version="1.0" encoding="UTF-8"?>
<report>
  <testsuite name="Nested" tests="1">
    <testcase classname="Nested" name="ok"/>
  </testsuite>
</report>
"""

SAMPLE_WITH_ENTITY = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE lolz [<!ENTITY lol "lol">]>
<testsuite name="Evil" tests="1">
  <testcase classname="Evil" name="boom"/>
</testsuite>
"""


def test_parse_with_error_element():
    """Line 39: error element classification."""
    path = _write_xml(SAMPLE_WITH_ERROR)
    try:
        result = parse_junit_xml(path)
        assert result["total"] == 1
        assert result["errored"] == 1
        assert result["passed"] == 0
        assert len(result["failures"]) == 1
        assert result["failures"][0]["test"] == "ErrTest.testBoom"
        assert result["failures"][0]["message"] == "NullPointerException"
    finally:
        os.unlink(path)


def test_parse_error_falls_back_to_text_and_empty_classname():
    """Covers _failure_detail fallback to element text and no-classname branch."""
    path = _write_xml(SAMPLE_ERROR_NO_MESSAGE_NO_CLASSNAME)
    try:
        result = parse_junit_xml(path)
        assert result["errored"] == 1
        assert result["failures"][0]["test"] == "bareTest"
        assert "raw body text" in result["failures"][0]["message"]
    finally:
        os.unlink(path)


def test_failure_takes_precedence_over_error():
    """_classify_testcase: failure element wins when both present."""
    path = _write_xml(SAMPLE_FAILURE_AND_ERROR)
    try:
        result = parse_junit_xml(path)
        assert result["failed"] == 1
        assert result["errored"] == 0
        assert result["failures"][0]["message"] == "failed first"
    finally:
        os.unlink(path)


def test_parse_unknown_root_tag():
    """Line 52: root is neither testsuites nor testsuite — iter fallback."""
    path = _write_xml(SAMPLE_UNKNOWN_ROOT)
    try:
        result = parse_junit_xml(path)
        assert result["total"] == 1
        assert result["passed"] == 1
    finally:
        os.unlink(path)


def test_parse_rejects_entity_declarations():
    """Line 19: _safe_parse raises on <!ENTITY to mitigate XXE."""
    path = _write_xml(SAMPLE_WITH_ENTITY)
    try:
        with pytest.raises(ValueError, match="entity declarations"):
            parse_junit_xml(path)
    finally:
        os.unlink(path)


def test_parse_no_matching_files_returns_empty_result():
    """Lines 56, 63: glob with no matches returns _empty_result()."""
    result = parse_junit_xml("/nonexistent/path/**/*.xml")
    assert result == {
        "total": 0,
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "errored": 0,
        "failures": [],
    }


def test_main_missing_argument_exits_with_usage():
    """Lines 85-87: __main__ with no args prints usage and exits 1."""
    script = os.path.join(os.path.dirname(__file__), "parse_junit_xml.py")
    proc = subprocess.run(
        [sys.executable, script],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 1
    assert "Usage" in proc.stderr


def test_main_prints_json_for_glob():
    """Lines 88-90: __main__ happy path dumps JSON to stdout."""
    dir = tempfile.mkdtemp()
    xml_path = os.path.join(dir, "result.xml")
    with open(xml_path, "w") as f:
        f.write(SAMPLE_PASSING)
    script = os.path.join(os.path.dirname(__file__), "parse_junit_xml.py")
    try:
        proc = subprocess.run(
            [sys.executable, script, os.path.join(dir, "*.xml")],
            capture_output=True,
            text=True,
        )
        assert proc.returncode == 0
        data = json.loads(proc.stdout)
        assert data["total"] == 3
        assert data["passed"] == 3
    finally:
        os.unlink(xml_path)
        os.rmdir(dir)


def test_parse_glob_multiple_files():
    dir = tempfile.mkdtemp()
    path1 = os.path.join(dir, "TEST-FooTest.xml")
    path2 = os.path.join(dir, "TEST-BarTest.xml")
    with open(path1, "w") as f:
        f.write(SAMPLE_PASSING)
    with open(path2, "w") as f:
        f.write(SAMPLE_FAILURES)
    try:
        result = parse_junit_xml(os.path.join(dir, "*.xml"))
        assert result["total"] == 6  # 3 + 3
        assert result["failed"] == 1
        assert result["passed"] == 4  # 3 + 1
    finally:
        os.unlink(path1)
        os.unlink(path2)
        os.rmdir(dir)
