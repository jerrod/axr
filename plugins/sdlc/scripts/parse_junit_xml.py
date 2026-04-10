#!/usr/bin/env python3
"""Parse JUnit XML test reports into structured JSON.

Usage: python3 parse_junit_xml.py <glob_pattern>
Output: JSON to stdout with total/passed/failed/skipped/errored counts and failure details.
"""

import glob
import json
import sys

try:
    from defusedxml import ElementTree as ET
except ImportError:
    from xml.etree import ElementTree as ET


def _safe_parse(path):
    """Parse XML rejecting entity definitions to mitigate XXE/billion-laughs.

    defusedxml forbids DTD/entity declarations at parse time. When defusedxml
    is not installed, the stdlib fallback is combined with an explicit entity
    scan so the parser still refuses obvious XXE payloads.
    """
    with open(path) as f:
        content = f.read()
    if "<!ENTITY" in content:
        raise ValueError(f"XML contains entity declarations (potential XXE): {path}")
    return ET.fromstring(content)


def _failure_detail(tc, el):
    """Extract test name and message from a failure/error element."""
    classname = tc.get("classname", "")
    name = tc.get("name", "")
    test_name = f"{classname}.{name}" if classname else name
    msg = el.get("message", el.text or "")
    return {"test": test_name, "message": msg}


def _classify_testcase(tc):
    """Classify a testcase element. Returns (status, detail_or_none)."""
    failure_el = tc.find("failure")
    if failure_el is not None:
        return "failed", _failure_detail(tc, failure_el)
    error_el = tc.find("error")
    if error_el is not None:
        return "errored", _failure_detail(tc, error_el)
    if tc.find("skipped") is not None:
        return "skipped", None
    return "passed", None


def _iter_suites(root):
    """Yield testsuite elements from either <testsuites> or <testsuite> root."""
    if root.tag == "testsuites":
        yield from root.iter("testsuite")
    elif root.tag == "testsuite":
        yield root
    else:
        yield from root.iter("testsuite")


def _empty_result():
    return {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "errored": 0, "failures": []}


def parse_junit_xml(pattern):
    """Parse JUnit XML files matching glob pattern. Returns summary dict."""
    paths = glob.glob(pattern, recursive=True)
    if not paths:
        return _empty_result()

    counts = {"passed": 0, "failed": 0, "skipped": 0, "errored": 0}
    failures = []

    for path in paths:
        root = _safe_parse(path)
        for suite in _iter_suites(root):
            for tc in suite.findall("testcase"):
                status, detail = _classify_testcase(tc)
                counts[status] += 1
                if detail:
                    failures.append(detail)

    return {
        "total": sum(counts.values()),
        "failures": failures,
        **counts,
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_junit_xml.py <glob_pattern>", file=sys.stderr)
        sys.exit(1)
    result = parse_junit_xml(sys.argv[1])
    json.dump(result, sys.stdout, indent=2)
    print()
