#!/usr/bin/env python3
"""AST-based complexity analysis engine.

Dispatches to real tools (radon, oxlint, gocyclo) when available,
falling back to a regex-based heuristic. Outputs JSON violations to stdout.

Usage:
    python3 analyze_complexity.py --files f1.py f2.ts \\
        --max-function-lines 50 --max-complexity 8 \\
        [--allow-json '{"complexity": [...]}']
"""

import argparse
import json

from complexity_heuristic import check_allowlist, heuristic_analyze
from complexity_tools import (
    analyze_go_files,
    analyze_js_ts_files,
    analyze_python_files,
)

LANGUAGE_EXTENSIONS = {
    "python": {"py"},
    "js_ts": {"ts", "tsx", "js", "jsx"},
    "go": {"go"},
    "heuristic": {"rs", "rb", "java", "kt"},
}


def group_files_by_language(files):
    """Group file paths by their language category."""
    groups = {lang: [] for lang in LANGUAGE_EXTENSIONS}
    for filepath in files:
        ext = filepath.rsplit(".", 1)[-1] if "." in filepath else ""
        matched = False
        for lang, extensions in LANGUAGE_EXTENSIONS.items():
            if ext in extensions:
                groups[lang].append(filepath)
                matched = True
                break
        if not matched:
            groups["heuristic"].append(filepath)
    return groups


def run_analysis(files, max_function_lines, max_complexity, allow_config):
    """Run complexity analysis on all files, return violations list."""
    groups = group_files_by_language(files)
    violations = []

    if groups["python"]:
        violations.extend(
            analyze_python_files(
                groups["python"], max_function_lines, max_complexity
            )
        )

    if groups["js_ts"]:
        violations.extend(
            analyze_js_ts_files(
                groups["js_ts"], max_function_lines, max_complexity
            )
        )

    if groups["go"]:
        violations.extend(
            analyze_go_files(groups["go"], max_function_lines, max_complexity)
        )

    if groups["heuristic"]:
        violations.extend(
            heuristic_analyze(
                groups["heuristic"], max_function_lines, max_complexity
            )
        )

    # Filter out allowed violations
    if allow_config:
        violations = [
            v
            for v in violations
            if not check_allowlist(allow_config, v)
        ]

    return violations


def parse_args(argv=None):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description="AST-based complexity analysis")
    parser.add_argument(
        "--files", nargs="*", default=[], help="Files to analyze"
    )
    parser.add_argument(
        "--max-function-lines",
        type=int,
        default=50,
        help="Maximum lines per function",
    )
    parser.add_argument(
        "--max-complexity",
        type=int,
        default=8,
        help="Maximum cyclomatic complexity",
    )
    parser.add_argument(
        "--allow-json",
        default="{}",
        help="JSON string of allowlist config",
    )
    return parser.parse_args(argv)


def main(argv=None):
    """Entry point: parse args, run analysis, print JSON violations."""
    args = parse_args(argv)

    if not args.files:
        print("[]")
        return

    try:
        allow_config = json.loads(args.allow_json)
    except (json.JSONDecodeError, TypeError):
        allow_config = {}

    violations = run_analysis(
        args.files, args.max_function_lines, args.max_complexity, allow_config
    )

    print(json.dumps(violations))


if __name__ == "__main__":
    main()
