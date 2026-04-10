#!/usr/bin/env python3
"""Parse SARIF v2.1.0 static analysis reports into structured findings.

Usage: python3 parse_sarif.py <glob_pattern> [rule_prefix]
Output: JSON array to stdout — each finding has file, line, level, rule_id, message.
"""

import glob
import json
import sys


def parse_sarif(pattern, rule_prefix=None):
    """Parse SARIF files matching glob pattern. Returns list of findings."""
    findings = []

    paths = glob.glob(pattern, recursive=True)
    if not paths:
        return findings

    for path in paths:
        with open(path) as f:
            data = json.load(f)

        for run in data.get("runs", []):
            for result in run.get("results", []):
                rule_id = result.get("ruleId", "")

                if rule_prefix and not rule_id.startswith(rule_prefix):
                    continue

                level = result.get("level", "warning")
                message = result.get("message", {}).get("text", "")

                # Extract first physical location
                file_path = ""
                line = 0
                locations = result.get("locations", [])
                if locations:
                    phys = locations[0].get("physicalLocation", {})
                    artifact = phys.get("artifactLocation", {})
                    file_path = artifact.get("uri", "")
                    region = phys.get("region", {})
                    line = region.get("startLine", 0)

                findings.append({
                    "file": file_path,
                    "line": line,
                    "level": level,
                    "rule_id": rule_id,
                    "message": message,
                })

    return findings


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_sarif.py <glob_pattern> [rule_prefix]", file=sys.stderr)
        sys.exit(1)
    prefix = sys.argv[2] if len(sys.argv) > 2 else None
    result = parse_sarif(sys.argv[1], rule_prefix=prefix)
    json.dump(result, sys.stdout, indent=2)
    print()
