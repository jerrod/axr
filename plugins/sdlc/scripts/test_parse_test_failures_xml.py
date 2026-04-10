#!/usr/bin/env python3
"""XML safety, direct-function, and main-entry tests for parse_test_failures.

Runner-format integration tests live in test_parse_test_failures.py.
This file holds:
- TestXmlSafety: billion-laughs payload, file-size cap, defusedxml fallback,
  malformed XML
- TestDirectFunctionCoverage: direct unit tests for branch coverage of the
  helper-decomposed parse_* functions (jest/mocha/go/rspec/junit)
- TestMainEntry: CLI usage banner
"""

import importlib
import json
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PARSER = os.path.join(SCRIPT_DIR, "parse_test_failures.py")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
import parse_test_failures as ptf

BILLION_LAUGHS_XML = """<?xml version="1.0"?>
<!DOCTYPE lolz [
  <!ENTITY lol "lol">
  <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
  <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
  <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
]>
<testsuites><testsuite><testcase name="x">&lol4;</testcase></testsuite></testsuites>"""


class TestXmlSafety:
    def test_billion_laughs_payload_is_rejected(self):
        """Entity-expansion payloads must be neutralized.

        With defusedxml installed, parsing raises EntitiesForbidden and
        parse_junit_xml returns None. Without defusedxml, the size cap
        catches oversized payloads (this test uses a tiny payload to
        verify the entity-expansion defense specifically).
        """
        with tempfile.NamedTemporaryFile(suffix=".xml", mode="w", delete=False) as f:
            f.write(BILLION_LAUGHS_XML)
            f.flush()
            result = ptf.parse_junit_xml(f.name)
        os.unlink(f.name)
        # Either defusedxml refuses entities (returns None) OR stdlib parses
        # but yields no expanded text in the failure message.
        if result is None:
            return  # defusedxml hardened path
        # Stdlib fallback path: ensure no megabyte-scale string was produced
        for entry in result:
            assert len(entry.get("message", "")) <= ptf.MAX_MESSAGE_LENGTH + 3

    def test_file_size_cap_rejects_oversized_xml(self):
        """Files larger than MAX_XML_BYTES return None without parsing."""
        original = ptf.MAX_XML_BYTES
        try:
            ptf.MAX_XML_BYTES = 10  # tiny cap
            with tempfile.NamedTemporaryFile(
                suffix=".xml", mode="w", delete=False
            ) as f:
                f.write("<testsuites><testsuite/></testsuites>")
                f.flush()
                result = ptf.parse_junit_xml(f.name)
            os.unlink(f.name)
            assert result is None
        finally:
            ptf.MAX_XML_BYTES = original

    def test_defusedxml_fallback_import_path(self):
        """When defusedxml is unavailable, the module falls back to stdlib ET."""
        saved_modules = {
            k: v for k, v in sys.modules.items() if k.startswith("defusedxml")
        }
        for k in list(saved_modules):
            del sys.modules[k]
        sys.modules["defusedxml"] = None  # forces ImportError on submodule import
        try:
            reloaded = importlib.reload(ptf)
            assert reloaded.ET.__name__ == "xml.etree.ElementTree"
        finally:
            del sys.modules["defusedxml"]
            sys.modules.update(saved_modules)
            importlib.reload(ptf)

    def test_parse_junit_xml_handles_malformed_xml(self):
        """Malformed XML triggers ParseError and returns None."""
        with tempfile.NamedTemporaryFile(suffix=".xml", mode="w", delete=False) as f:
            f.write("<not-closed>")
            f.flush()
            result = ptf.parse_junit_xml(f.name)
        os.unlink(f.name)
        assert result is None


class TestDirectFunctionCoverage:
    """Direct unit tests covering branches not exercised by subprocess tests."""

    def test_truncate_empty_string(self):
        assert ptf.truncate("") == ""
        assert ptf.truncate(None) == ""

    def test_truncate_short_string(self):
        assert ptf.truncate("hello") == "hello"

    def test_parse_jest_no_brace(self):
        assert ptf.parse_jest_vitest("no json here") is None

    def test_parse_jest_invalid_json(self):
        assert ptf.parse_jest_vitest("{not valid json") is None

    def test_parse_jest_max_failures_cap(self):
        assertions = [
            {
                "status": "failed",
                "title": f"t{i}",
                "ancestorTitles": [],
                "failureMessages": ["x"],
            }
            for i in range(ptf.MAX_FAILURES + 5)
        ]
        data = json.dumps(
            {"testResults": [{"name": "f.ts", "assertionResults": assertions}]}
        )
        result = ptf.parse_jest_vitest(data)
        assert len(result) == ptf.MAX_FAILURES

    def test_parse_mocha_no_brace(self):
        assert ptf.parse_mocha("no json") is None

    def test_parse_mocha_invalid_json(self):
        assert ptf.parse_mocha("{garbage") is None

    def test_parse_mocha_max_failures_cap(self):
        failures = [
            {"fullTitle": f"t{i}", "file": "f.js", "err": {"message": "m"}}
            for i in range(ptf.MAX_FAILURES + 3)
        ]
        data = json.dumps({"failures": failures})
        result = ptf.parse_mocha(data)
        assert len(result) == ptf.MAX_FAILURES

    def test_parse_go_skips_blank_and_invalid_lines(self):
        lines = "\n".join(
            [
                "",
                "not json",
                json.dumps({"Action": "fail", "Package": "p", "Test": ""}),
                # Test that recorded output but never failed (covers skip branch)
                json.dumps(
                    {"Action": "output", "Package": "p", "Test": "T0", "Output": "ok"}
                ),
                json.dumps({"Action": "fail", "Package": "p", "Test": "T1"}),
                json.dumps(
                    {"Action": "output", "Package": "p", "Test": "T1", "Output": "x"}
                ),
            ]
        )
        result = ptf.parse_go_json(lines)
        assert len(result) == 1
        assert "T1" in result[0]["test"]

    def test_parse_go_max_failures_cap(self):
        events = []
        for i in range(ptf.MAX_FAILURES + 3):
            events.append(
                json.dumps({"Action": "fail", "Package": "p", "Test": f"T{i}"})
            )
        result = ptf.parse_go_json("\n".join(events))
        assert len(result) == ptf.MAX_FAILURES

    def test_parse_rspec_no_brace(self):
        assert ptf.parse_rspec_json("no json") is None

    def test_parse_rspec_invalid_json(self):
        assert ptf.parse_rspec_json("{garbage") is None

    def test_parse_rspec_max_failures_cap(self):
        examples = [
            {
                "status": "failed",
                "full_description": f"t{i}",
                "file_path": "f.rb",
                "line_number": 1,
                "exception": {"message": "m"},
            }
            for i in range(ptf.MAX_FAILURES + 3)
        ]
        data = json.dumps({"examples": examples})
        result = ptf.parse_rspec_json(data)
        assert len(result) == ptf.MAX_FAILURES

    def test_parse_junit_xml_with_error_element(self):
        """JUnit <error> elements (not just <failure>) are reported."""
        xml_content = """<?xml version="1.0"?>
<testsuite>
  <testcase classname="" name="boom">
    <error message="kaboom">stack trace</error>
  </testcase>
</testsuite>"""
        with tempfile.NamedTemporaryFile(suffix=".xml", mode="w", delete=False) as f:
            f.write(xml_content)
            f.flush()
            result = ptf.parse_junit_xml(f.name)
        os.unlink(f.name)
        assert len(result) == 1
        assert result[0]["test"] == "boom"
        assert "kaboom" in result[0]["message"]

    def test_parse_junit_xml_max_failures_cap(self):
        cases = "".join(
            f'<testcase name="t{i}"><failure message="m"/></testcase>'
            for i in range(ptf.MAX_FAILURES + 3)
        )
        xml_content = f"<testsuite>{cases}</testsuite>"
        with tempfile.NamedTemporaryFile(suffix=".xml", mode="w", delete=False) as f:
            f.write(xml_content)
            f.flush()
            result = ptf.parse_junit_xml(f.name)
        os.unlink(f.name)
        assert len(result) == ptf.MAX_FAILURES

    def test_dispatch_runner_unknown_runner(self):
        assert ptf._dispatch_runner("unknown", "", None) is None

    def test_parse_junit_runner_searches_when_no_explicit_file(self):
        """When no report_file is given, searches default locations."""
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as d:
            os.chdir(d)
            try:
                with open("junit.xml", "w") as f:
                    f.write(
                        '<testsuite><testcase name="t">'
                        '<failure message="m"/></testcase></testsuite>'
                    )
                result = ptf._parse_junit_runner(None)
                assert result is not None
                assert len(result) == 1
            finally:
                os.chdir(cwd)

    def test_parse_junit_runner_no_files_found(self):
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as d:
            os.chdir(d)
            try:
                assert ptf._parse_junit_runner(None) is None
            finally:
                os.chdir(cwd)

    def test_clean_failures_strips_empty_values(self):
        cleaned = ptf._clean_failures(
            [
                {"test": "t1", "file": "", "line": None, "message": ""},
                {"test": "t2", "file": "f", "line": 5, "message": "m"},
            ]
        )
        assert cleaned[0] == {"test": "t1"}
        assert cleaned[1] == {"test": "t2", "file": "f", "line": 5, "message": "m"}


class TestMainEntry:
    def test_main_no_args_prints_usage(self):
        result = subprocess.run(
            [sys.executable, PARSER],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 1
        assert "Usage" in result.stderr


if __name__ == "__main__":
    import pytest as pt

    pt.main([__file__, "-v"])
