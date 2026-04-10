#!/usr/bin/env python3
"""Parse SimpleCov .resultset.json into coverage dict for gate-coverage.sh.

Output format matches JaCoCo/Cobertura parsers:
  {"path/to/file.rb": {"lines": {"pct": 85.5}}, ...}

Usage: python3 parse_simplecov.py coverage/.resultset.json
"""
import json
import os
import sys


def _extract_lines(file_data):
    """Return the raw line-hit array from a SimpleCov file entry.

    SimpleCov uses either a dict with a "lines" key or a flat array of
    per-line hit counts.
    """
    if isinstance(file_data, dict):
        return file_data.get("lines", [])
    return file_data


def _compute_percentage(lines):
    """Compute covered-line percentage from a SimpleCov line-hit array."""
    relevant = [hit for hit in lines if hit is not None]
    total = len(relevant)
    if total == 0:
        return 100.0
    covered = len([hit for hit in relevant if hit > 0])
    return covered / total * 100


def _normalize_path(abs_path, cwd):
    """Convert an absolute SimpleCov path to a repo-relative path when possible."""
    prefix = cwd + "/"
    if abs_path.startswith(prefix):
        return abs_path[len(prefix):]
    return abs_path


def _file_entry(file_data):
    """Compute the coverage entry for a single SimpleCov file record."""
    lines = _extract_lines(file_data)
    pct = _compute_percentage(lines)
    return {"lines": {"pct": round(pct, 2)}}


def parse(resultset_path):
    with open(resultset_path) as f:
        data = json.load(f)

    coverage = {}
    cwd = os.getcwd()

    for _suite_name, suite_data in data.items():
        file_coverage = suite_data.get("coverage", {})
        for abs_path, file_data in file_coverage.items():
            rel_path = _normalize_path(abs_path, cwd)
            coverage[rel_path] = _file_entry(file_data)

    return coverage


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("{}")
        sys.exit(0)
    result = parse(sys.argv[1])
    print(json.dumps(result))
