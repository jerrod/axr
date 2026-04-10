#!/usr/bin/env python3
"""Parse JaCoCo XML coverage reports into per-file line coverage.

Usage: python3 parse_jacoco.py <glob_pattern>
Output: JSON to stdout — dict of filepath -> {"lines": {"pct": N}}.
"""

import glob
import json
import sys
from xml.etree.ElementTree import fromstring as _xml_fromstring


def _safe_parse(path):
    """Parse XML rejecting entity definitions to mitigate XXE/billion-laughs."""
    # Read file content and reject DTD entity declarations
    with open(path) as f:
        content = f.read()
    if "<!ENTITY" in content:
        raise ValueError(f"XML contains entity declarations (potential XXE): {path}")
    return _xml_fromstring(content)


def _extract_line_pct(sourcefile_el):
    """Extract line coverage percentage from a JaCoCo sourcefile element."""
    for counter in sourcefile_el.iter("counter"):
        if counter.get("type") == "LINE":
            covered = int(counter.get("covered", 0))
            missed = int(counter.get("missed", 0))
            total = covered + missed
            return round(covered / total * 100, 1) if total > 0 else 0.0
    return None


def parse_jacoco(pattern):
    """Parse JaCoCo XML files matching glob pattern. Returns coverage dict."""
    coverage = {}

    for path in glob.glob(pattern, recursive=True):
        root = _safe_parse(path)

        for pkg in root.iter("package"):
            pkg_name = pkg.get("name", "")
            for sf in pkg.iter("sourcefile"):
                pct = _extract_line_pct(sf)
                if pct is not None:
                    fname = sf.get("name", "")
                    file_key = f"{pkg_name}/{fname}" if pkg_name else fname
                    coverage[file_key] = {"lines": {"pct": pct}}

    return coverage


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_jacoco.py <glob_pattern>", file=sys.stderr)
        sys.exit(1)
    result = parse_jacoco(sys.argv[1])
    json.dump(result, sys.stdout, indent=2)
    print()
