#!/usr/bin/env python3
"""Parse SimpleCov .resultset.json into coverage dict for gate-coverage.sh.

Output format matches JaCoCo/Cobertura parsers:
  {"path/to/file.rb": {"lines": {"pct": 85.5}}, ...}

Usage: python3 parse_simplecov.py coverage/.resultset.json
"""
import json
import os
import sys


def parse(resultset_path):
    with open(resultset_path) as f:
        data = json.load(f)

    coverage = {}
    cwd = os.getcwd()

    for _suite_name, suite_data in data.items():
        file_coverage = suite_data.get("coverage", {})
        for abs_path, file_data in file_coverage.items():
            # Extract line data — SimpleCov uses either a dict with "lines" key
            # or a flat array of line counts
            if isinstance(file_data, dict):
                lines = file_data.get("lines", [])
            else:
                lines = file_data

            relevant = [l for l in lines if l is not None]
            total = len(relevant)
            covered = len([l for l in relevant if l > 0])
            pct = (covered / total * 100) if total > 0 else 100.0

            # Convert absolute path to relative
            rel_path = abs_path
            if abs_path.startswith(cwd + "/"):
                rel_path = abs_path[len(cwd) + 1:]

            coverage[rel_path] = {"lines": {"pct": round(pct, 2)}}

    return coverage


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("{}")
        sys.exit(0)
    result = parse(sys.argv[1])
    print(json.dumps(result))
