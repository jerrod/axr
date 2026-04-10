#!/usr/bin/env python3
"""Parse structured test output into compact failure summaries.

Usage: parse-test-failures.py <runner> [report-file]
  Reads raw output from stdin (jest/vitest/mocha/go/rspec JSON)
  or parses a report file (JUnit XML from pytest/gradle/maven).

Output: JSON array of failures, max 50 entries:
  [{"test": "name", "file": "path", "line": 42, "message": "expected X got Y"}]

Exit code: 0 if parsing succeeded (even if failures found), 1 if parse error.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


MAX_FAILURES = 50
MAX_MESSAGE_LENGTH = 500


def truncate(text, max_length=MAX_MESSAGE_LENGTH):
    if not text:
        return ""
    text = text.strip()
    if len(text) <= max_length:
        return text
    return text[:max_length] + "..."


def _build_jest_failure(result, filepath):
    """Build a failure entry from a single Jest/Vitest assertion result."""
    ancestors = result.get("ancestorTitles", [])
    title = result.get("title", result.get("fullName", "unknown"))
    full_name = " > ".join(ancestors + [title]) if ancestors else title
    messages = result.get("failureMessages", [])
    message = truncate("\n".join(messages)) if messages else ""
    location = result.get("location", {})
    return {
        "test": full_name,
        "file": filepath,
        "line": location.get("line"),
        "message": message,
    }


def parse_jest_vitest(raw_output):
    """Parse Jest/Vitest --json output."""
    failures = []
    # Jest/Vitest JSON may have non-JSON preamble — find the JSON object
    json_start = raw_output.find("{")
    if json_start == -1:
        return None
    try:
        data = json.loads(raw_output[json_start:])
    except json.JSONDecodeError:
        return None

    for suite in data.get("testResults", []):
        filepath = suite.get("name", "")
        for result in suite.get("assertionResults", suite.get("testResults", [])):
            if result.get("status") != "failed":
                continue
            failures.append(_build_jest_failure(result, filepath))
            if len(failures) >= MAX_FAILURES:
                return failures
    return failures


def parse_mocha(raw_output):
    """Parse Mocha --reporter json output."""
    failures = []
    json_start = raw_output.find("{")
    if json_start == -1:
        return None
    try:
        data = json.loads(raw_output[json_start:])
    except json.JSONDecodeError:
        return None

    for test in data.get("failures", []):
        err = test.get("err", {})
        failures.append(
            {
                "test": test.get("fullTitle", "unknown"),
                "file": test.get("file", ""),
                "line": None,
                "message": truncate(err.get("message", "")),
            }
        )
        if len(failures) >= MAX_FAILURES:
            break
    return failures


def _ensure_go_test_entry(failed_tests, key, package, test_name):
    """Ensure a test entry exists in the failed_tests dict."""
    if key not in failed_tests:
        failed_tests[key] = {"output": [], "package": package, "test": test_name}


def _process_go_event(event, failed_tests):
    """Process a single go test JSON event, updating failed_tests in place."""
    action = event.get("Action", "")
    test_name = event.get("Test", "")
    package = event.get("Package", "")
    if not test_name:
        return
    key = f"{package}/{test_name}"
    if action == "output":
        _ensure_go_test_entry(failed_tests, key, package, test_name)
        failed_tests[key]["output"].append(event.get("Output", ""))
    elif action == "fail":
        _ensure_go_test_entry(failed_tests, key, package, test_name)
        failed_tests[key]["failed"] = True


def _collect_go_failures(failed_tests):
    """Convert failed_tests dict into a list of failure entries."""
    failures = []
    for info in failed_tests.values():
        if not info.get("failed"):
            continue
        output_text = "".join(info["output"])
        failures.append(
            {
                "test": f"{info['package']}/{info['test']}",
                "file": info["package"],
                "line": None,
                "message": truncate(output_text),
            }
        )
        if len(failures) >= MAX_FAILURES:
            break
    return failures


def parse_go_json(raw_output):
    """Parse go test -json output (JSON lines)."""
    failed_tests = {}
    for line in raw_output.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        _process_go_event(event, failed_tests)
    return _collect_go_failures(failed_tests)


def parse_rspec_json(raw_output):
    """Parse RSpec --format json output."""
    failures = []
    json_start = raw_output.find("{")
    if json_start == -1:
        return None
    try:
        data = json.loads(raw_output[json_start:])
    except json.JSONDecodeError:
        return None

    for example in data.get("examples", []):
        if example.get("status") != "failed":
            continue
        exception = example.get("exception", {})
        failures.append(
            {
                "test": example.get("full_description", "unknown"),
                "file": example.get("file_path", ""),
                "line": example.get("line_number"),
                "message": truncate(exception.get("message", "")),
            }
        )
        if len(failures) >= MAX_FAILURES:
            break
    return failures


def _junit_failure_element(tc):
    """Return the <failure> or <error> child of a testcase, or None."""
    failure = tc.find("failure")
    if failure is not None:
        return failure
    return tc.find("error")


def _build_junit_failure(tc, element):
    """Build a failure entry from a JUnit <testcase> and its failure/error element."""
    classname = tc.get("classname", "")
    name = tc.get("name", "unknown")
    file_attr = tc.get("file", classname.replace(".", "/"))
    line_attr = tc.get("line")
    return {
        "test": f"{classname}::{name}" if classname else name,
        "file": file_attr,
        "line": int(line_attr) if line_attr else None,
        "message": truncate(element.get("message", element.text or "")),
    }


def parse_junit_xml(report_path):
    """Parse JUnit XML report (pytest --junitxml, gradle, maven)."""
    failures = []
    try:
        tree = ET.parse(report_path)
    except (ET.ParseError, FileNotFoundError):
        return None
    # Handle both <testsuites><testsuite>... and bare <testsuite>...
    for tc in tree.getroot().iter("testcase"):
        element = _junit_failure_element(tc)
        if element is None:
            continue
        failures.append(_build_junit_failure(tc, element))
        if len(failures) >= MAX_FAILURES:
            break
    return failures


def find_junit_reports():
    """Search for JUnit XML reports in common locations."""
    search_paths = [
        "test-results.xml",
        "junit.xml",
        "report.xml",
        "build/test-results/**/*.xml",
        "target/surefire-reports/*.xml",
        "target/failsafe-reports/*.xml",
        "build/reports/tests/**/*.xml",
    ]
    found = []
    for pattern in search_paths:
        found.extend(Path(".").glob(pattern))
    return found


def _dispatch_runner(runner, raw_output, report_file):
    """Dispatch parsing to the appropriate parser based on runner name."""
    if runner in ("jest", "vitest"):
        return parse_jest_vitest(raw_output)
    if runner == "mocha":
        return parse_mocha(raw_output)
    if runner == "go":
        return parse_go_json(raw_output)
    if runner == "rspec":
        return parse_rspec_json(raw_output)
    if runner in ("pytest", "gradle", "maven", "cargo", "junit"):
        return _parse_junit_runner(report_file)
    return None


def _parse_junit_runner(report_file):
    """Try an explicit report file then search common locations."""
    if report_file and Path(report_file).exists():
        return parse_junit_xml(report_file)
    for report in find_junit_reports():
        failures = parse_junit_xml(str(report))
        if failures is not None:
            return failures
    return None


def _clean_failures(failures):
    """Remove None/empty values from failure entries for cleaner JSON output."""
    cleaned = []
    for f in failures:
        entry = {"test": f["test"]}
        if f.get("file"):
            entry["file"] = f["file"]
        if f.get("line") is not None:
            entry["line"] = f["line"]
        if f.get("message"):
            entry["message"] = f["message"]
        cleaned.append(entry)
    return cleaned


def main():
    if len(sys.argv) < 2:
        print("Usage: parse-test-failures.py <runner> [report-file]", file=sys.stderr)
        sys.exit(1)

    runner = sys.argv[1]
    report_file = sys.argv[2] if len(sys.argv) > 2 else None
    raw_output = sys.stdin.read() if not report_file else ""

    failures = _dispatch_runner(runner, raw_output, report_file)

    if failures is None:
        # Couldn't parse structured output — return empty (caller falls back to raw)
        print("[]")
        sys.exit(1)

    print(json.dumps(_clean_failures(failures), indent=2))


if __name__ == "__main__":
    main()
