#!/usr/bin/env python3
"""Tests for parse-test-failures.py — runner-format parsing.

XML-safety tests, direct-function unit tests, and main-entry coverage
live in test_parse_test_failures_xml.py.
"""

import json
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PARSER = os.path.join(SCRIPT_DIR, "parse_test_failures.py")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)


def run_parser(runner, stdin_input="", report_file=None):
    cmd = [sys.executable, PARSER, runner]
    if report_file:
        cmd.append(report_file)
    result = subprocess.run(
        cmd,
        input=stdin_input,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout), result.returncode


class TestJestVitest:
    def test_parses_failed_tests(self):
        jest_output = json.dumps(
            {
                "testResults": [
                    {
                        "name": "/app/src/utils.test.ts",
                        "assertionResults": [
                            {
                                "status": "passed",
                                "title": "adds numbers",
                                "ancestorTitles": ["math"],
                            },
                            {
                                "status": "failed",
                                "title": "subtracts numbers",
                                "ancestorTitles": ["math"],
                                "failureMessages": ["Expected 5 but got 3"],
                                "location": {"line": 12},
                            },
                        ],
                    }
                ],
            }
        )
        failures, exit_code = run_parser("jest", jest_output)
        assert exit_code == 0
        assert len(failures) == 1
        assert failures[0]["test"] == "math > subtracts numbers"
        assert failures[0]["file"] == "/app/src/utils.test.ts"
        assert failures[0]["line"] == 12
        assert "Expected 5 but got 3" in failures[0]["message"]

    def test_returns_empty_on_all_passing(self):
        jest_output = json.dumps(
            {
                "testResults": [
                    {
                        "name": "/app/src/utils.test.ts",
                        "assertionResults": [
                            {
                                "status": "passed",
                                "title": "works",
                                "ancestorTitles": [],
                            },
                        ],
                    }
                ],
            }
        )
        failures, _ = run_parser("vitest", jest_output)
        assert failures == []

    def test_handles_preamble_before_json(self):
        raw = "Some random console output\n" + json.dumps(
            {
                "testResults": [
                    {
                        "name": "test.ts",
                        "assertionResults": [
                            {
                                "status": "failed",
                                "title": "broken",
                                "ancestorTitles": [],
                                "failureMessages": ["oops"],
                            },
                        ],
                    }
                ],
            }
        )
        failures, _ = run_parser("jest", raw)
        assert len(failures) == 1

    def test_returns_empty_on_garbage_input(self):
        _, exit_code = run_parser("jest", "not json at all")
        assert exit_code == 1


class TestMocha:
    def test_parses_failures(self):
        mocha_output = json.dumps(
            {
                "failures": [
                    {
                        "fullTitle": "Array #indexOf should return -1",
                        "file": "test/array.js",
                        "err": {"message": "expected 0 to equal -1"},
                    },
                ],
            }
        )
        failures, _ = run_parser("mocha", mocha_output)
        assert len(failures) == 1
        assert failures[0]["test"] == "Array #indexOf should return -1"
        assert "expected 0 to equal -1" in failures[0]["message"]


class TestGoJson:
    def test_parses_failed_tests(self):
        lines = "\n".join(
            [
                json.dumps(
                    {
                        "Action": "output",
                        "Package": "pkg/math",
                        "Test": "TestAdd",
                        "Output": "    got: 3\n",
                    }
                ),
                json.dumps(
                    {
                        "Action": "output",
                        "Package": "pkg/math",
                        "Test": "TestAdd",
                        "Output": "    want: 5\n",
                    }
                ),
                json.dumps(
                    {"Action": "fail", "Package": "pkg/math", "Test": "TestAdd"}
                ),
                json.dumps(
                    {"Action": "pass", "Package": "pkg/math", "Test": "TestSub"}
                ),
            ]
        )
        failures, _ = run_parser("go", lines)
        assert len(failures) == 1
        assert "TestAdd" in failures[0]["test"]
        assert "got: 3" in failures[0]["message"]


class TestRspecJson:
    def test_parses_failures(self):
        rspec_output = json.dumps(
            {
                "examples": [
                    {"status": "passed", "full_description": "works"},
                    {
                        "status": "failed",
                        "full_description": "User validates email",
                        "file_path": "spec/models/user_spec.rb",
                        "line_number": 42,
                        "exception": {"message": "expected valid? to be true"},
                    },
                ],
            }
        )
        failures, _ = run_parser("rspec", rspec_output)
        assert len(failures) == 1
        assert failures[0]["test"] == "User validates email"
        assert failures[0]["line"] == 42


class TestJunitXml:
    def test_parses_failures_from_xml(self):
        xml_content = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="tests" tests="2" failures="1">
    <testcase classname="test_math" name="test_add" file="test_math.py" line="10"/>
    <testcase classname="test_math" name="test_sub" file="test_math.py" line="15">
      <failure message="assert 3 == 5">AssertionError: assert 3 == 5</failure>
    </testcase>
  </testsuite>
</testsuites>"""
        with tempfile.NamedTemporaryFile(suffix=".xml", mode="w", delete=False) as f:
            f.write(xml_content)
            f.flush()
            failures, _ = run_parser("pytest", report_file=f.name)
        os.unlink(f.name)
        assert len(failures) == 1
        assert failures[0]["test"] == "test_math::test_sub"
        assert failures[0]["line"] == 15
        assert "assert 3 == 5" in failures[0]["message"]

    def test_handles_missing_file(self):
        _, exit_code = run_parser("pytest", report_file="/nonexistent/file.xml")
        assert exit_code == 1


class TestMessageTruncation:
    def test_long_messages_truncated(self):
        long_msg = "x" * 1000
        jest_output = json.dumps(
            {
                "testResults": [
                    {
                        "name": "test.ts",
                        "assertionResults": [
                            {
                                "status": "failed",
                                "title": "test",
                                "ancestorTitles": [],
                                "failureMessages": [long_msg],
                            }
                        ],
                    }
                ],
            }
        )
        failures, _ = run_parser("jest", jest_output)
        assert len(failures[0]["message"]) <= 503  # 500 + "..."


if __name__ == "__main__":
    import pytest as pt

    pt.main([__file__, "-v"])
