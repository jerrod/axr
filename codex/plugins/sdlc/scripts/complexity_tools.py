#!/usr/bin/env python3
"""Per-language AST tool wrappers for complexity analysis.

Wraps radon (Python), oxlint (JS/TS), and gocyclo (Go).
Falls back to heuristic analysis when tools are unavailable.
All functions return a list of violation dicts with keys:
  file, function, lines|complexity, max, type
"""

import json
import os
import re
import subprocess
import sys
import tempfile

from complexity_heuristic import heuristic_analyze

# --- Python: radon ---


def _run_radon(files):
    """Run radon cc -j on Python files. Returns parsed JSON or None."""
    try:
        result = subprocess.run(
            ["uv", "tool", "run", "radon", "cc", "-j"] + files,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None


def _radon_func_violations(filepath, func, max_lines, max_complexity):
    """Return violations for a single radon function/method entry.

    Class entries are skipped here — their methods are already counted
    independently by radon as type=="method". Including the enclosing
    class would double-count and produce false positives on legitimate
    multi-test classes (TestJestVitest, etc.).
    """
    if func.get("type") == "class":
        return []

    name = func.get("name", "unknown")
    lineno = func.get("lineno", 0)
    endline = func.get("endline", 0)
    complexity = func.get("complexity", 0)
    func_length = endline - lineno + 1 if endline >= lineno else 0

    out = []
    if max_lines and func_length > max_lines:
        out.append({
            "file": filepath,
            "function": name,
            "lines": func_length,
            "max": max_lines,
            "type": "function_length",
        })
    if max_complexity and complexity > max_complexity:
        out.append({
            "file": filepath,
            "function": name,
            "complexity": complexity,
            "max": max_complexity,
            "type": "cyclomatic_complexity",
        })
    return out


def _violations_from_radon(data, max_lines, max_complexity):
    """Extract violations from radon JSON output."""
    violations = []
    for filepath, functions in data.items():
        for func in functions:
            violations.extend(
                _radon_func_violations(filepath, func, max_lines, max_complexity)
            )
    return violations


def analyze_python_files(files, max_lines, max_complexity):
    """Analyze Python files with radon, fallback to heuristic."""
    print("Analyzing Python files with radon...", file=sys.stderr)
    data = _run_radon(files)
    if data is not None:
        return _violations_from_radon(data, max_lines, max_complexity)
    print("radon unavailable, using heuristic fallback", file=sys.stderr)
    return heuristic_analyze(files, max_lines, max_complexity)


# --- JS/TS: oxlint ---


def _run_oxlint(files, max_lines, max_complexity):
    """Run oxlint with complexity rules. Returns parsed JSON or None."""
    config = {
        "rules": {
            "complexity": ["error", {"max": max_complexity or 8}],
            "max-lines-per-function": [
                "error",
                {"max": max_lines or 50},
            ],
        }
    }
    config_fd = None
    config_path = None
    try:
        config_fd, config_path = tempfile.mkstemp(
            suffix=".json", prefix="oxlint-"
        )
        with os.fdopen(config_fd, "w") as f:
            json.dump(config, f)
            config_fd = None  # fdopen took ownership

        result = subprocess.run(
            ["npx", "oxlint", "-c", config_path, "--format", "json"] + files,
            capture_output=True,
            text=True,
            timeout=60,
        )
        # oxlint exits non-zero when violations found — that's expected
        if result.stdout.strip():
            return json.loads(result.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    finally:
        if config_fd is not None:
            os.close(config_fd)
        if config_path and os.path.exists(config_path):
            os.unlink(config_path)
    return None


def _violations_from_oxlint(data, max_lines, max_complexity):
    """Extract violations from oxlint JSON output."""
    violations = []
    diagnostics = data.get("diagnostics", [])
    for diag in diagnostics:
        code = diag.get("code", "")
        message = diag.get("message", "")
        filename = diag.get("filename", "")

        if code == "eslint(complexity)":
            match = re.search(
                r"function `(.+?)` has a complexity of (\d+)", message
            )
            if match:
                violations.append({
                    "file": filename,
                    "function": match.group(1),
                    "complexity": int(match.group(2)),
                    "max": max_complexity,
                    "type": "cyclomatic_complexity",
                })

        elif code == "eslint(max-lines-per-function)":
            match = re.search(
                r"function `(.+?)` has too many lines \((\d+)\)", message
            )
            if match:
                violations.append({
                    "file": filename,
                    "function": match.group(1),
                    "lines": int(match.group(2)),
                    "max": max_lines,
                    "type": "function_length",
                })

    return violations


def analyze_js_ts_files(files, max_lines, max_complexity):
    """Analyze JS/TS files with oxlint, fallback to heuristic."""
    print("Analyzing JS/TS files with oxlint...", file=sys.stderr)
    data = _run_oxlint(files, max_lines, max_complexity)
    if data is not None:
        return _violations_from_oxlint(data, max_lines, max_complexity)
    print("oxlint unavailable, using heuristic fallback", file=sys.stderr)
    return heuristic_analyze(files, max_lines, max_complexity)


# --- Go: gocyclo ---


def _run_gocyclo(files, threshold):
    """Run gocyclo. Returns list of output lines or None."""
    try:
        result = subprocess.run(
            ["gocyclo", "-over", str(threshold)] + files,
            capture_output=True,
            text=True,
            timeout=60,
        )
        # gocyclo exits 1 when violations found
        output = result.stdout.strip()
        if output:
            return output.splitlines()
        return []
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def _violations_from_gocyclo(lines, max_complexity=0):
    """Parse gocyclo output lines into violations.

    Format: '8 pkg.FuncName path/file.go:10:1'
    The ``max_complexity`` argument is recorded on each violation so callers
    don't have to post-process the list. It defaults to 0 only to keep older
    test fixtures that don't care about the threshold working.
    """
    violations = []
    for line in lines:
        parts = line.split()
        if len(parts) < 3 or not parts[0].isdigit():
            # Skip blank lines, malformed output, and gocyclo warning
            # banners that start with a non-numeric first token.
            continue
        try:
            complexity = int(parts[0])
        except ValueError:
            continue
        func_name = parts[1]
        file_info = parts[2]
        filepath = file_info.split(":")[0]
        violations.append({
            "file": filepath,
            "function": func_name,
            "complexity": complexity,
            "max": max_complexity,
            "type": "cyclomatic_complexity",
        })
    return violations


def analyze_go_files(files, max_lines, max_complexity):
    """Analyze Go files: gocyclo for complexity, heuristic for length."""
    violations = []

    # Complexity via gocyclo
    if max_complexity:
        print("Analyzing Go complexity with gocyclo...", file=sys.stderr)
        lines = _run_gocyclo(files, max_complexity)
        if lines is not None:
            violations.extend(_violations_from_gocyclo(lines, max_complexity))
        else:
            print(
                "gocyclo unavailable, using heuristic for complexity",
                file=sys.stderr,
            )
            violations.extend(
                heuristic_analyze(files, None, max_complexity)
            )

    # Function length always via heuristic (no standard Go tool)
    if max_lines:
        violations.extend(heuristic_analyze(files, max_lines, None))

    return violations
