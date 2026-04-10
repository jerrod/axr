"""Tests for parse_junit_xml.py — JUnit XML test report parser."""

import os
import tempfile

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
