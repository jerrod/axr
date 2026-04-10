#!/usr/bin/env python3
"""Parse Cobertura XML coverage reports into per-file line coverage.

Usage: python3 parse_cobertura.py <glob_pattern>
Output: JSON to stdout — dict of filepath -> {"lines": {"pct": N}}.
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


def parse_cobertura(pattern):
    """Parse Cobertura XML files matching glob pattern. Returns coverage dict."""
    coverage = {}

    paths = glob.glob(pattern, recursive=True)
    if not paths:
        return coverage

    for path in paths:
        root = _safe_parse(path)

        for cls in root.iter("class"):
            filename = cls.get("filename", "")
            line_rate = cls.get("line-rate")

            if filename and line_rate is not None:
                pct = round(float(line_rate) * 100, 1)
                coverage[filename] = {"lines": {"pct": pct}}

    return coverage


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_cobertura.py <glob_pattern>", file=sys.stderr)
        sys.exit(1)
    result = parse_cobertura(sys.argv[1])
    json.dump(result, sys.stdout, indent=2)
    print()
