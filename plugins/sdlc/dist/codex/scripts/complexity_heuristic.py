#!/usr/bin/env python3
"""Regex-based heuristic complexity analysis and allowlist filtering.

Fallback for when AST tools (radon, oxlint, gocyclo) are not available.
Uses regex patterns to detect function boundaries and count branches.
"""

import fnmatch
import os
import re

# --- Function patterns per language ---

FUNC_PATTERNS = {
    "py": re.compile(
        r"^(\s*)(async\s+)?def\s+(\w+)"
    ),
    "rb": re.compile(
        r"^(\s*)(def\s+(?:self\.)?(\w+[?!=]?))"
    ),
    "go": re.compile(
        r"^func\s+(?:\([^)]*\)\s+)?(\w+)"
    ),
    "rs": re.compile(
        r"^(\s*)(pub\s+)?(async\s+)?fn\s+(\w+)"
    ),
    "java": re.compile(
        r"^\s*(public|private|protected|static|final|abstract|synchronized)"
        r"\s+.*?(\w+)\s*\("
    ),
    "kt": re.compile(
        r"^\s*(fun|override\s+fun|private\s+fun|internal\s+fun"
        r"|public\s+fun|protected\s+fun)\s+(\w+)"
    ),
    "ts": re.compile(
        r"^\s*(export\s+)?(async\s+)?function\s+(\w+)"
        r"|^\s*(const|let|var)\s+(\w+)\s*=\s*(async\s+)?\("
        r"|^\s*(public|private|protected|static|async)\s+(\w+)\s*\("
    ),
}

BRANCH_PATTERN = re.compile(
    r"\b(if|else\s+if|elif|elsif|unless|until"
    r"|for|while|case|when|catch|except|rescue)\b"
    r"|[?]\s*.*:"
    r"|\&\&|\|\|"
    r"|\band\b|\bor\b"
)


def _get_func_pattern(ext):
    """Return the function-detection regex for a file extension."""
    if ext in ("ts", "tsx", "js", "jsx"):
        return FUNC_PATTERNS.get("ts")
    return FUNC_PATTERNS.get(ext)


# Map each language to which regex groups contain the function name.
# Tried in order; first non-None match wins.
_NAME_GROUPS = {
    "ts": (3, 5, 8),
    "tsx": (3, 5, 8),
    "js": (3, 5, 8),
    "jsx": (3, 5, 8),
    "go": (1,),
    "rs": (4,),
    "py": (3,),
    "rb": (3,),
    "java": (2,),
    "kt": (2,),
}


def _extract_func_name(match, ext):
    """Extract the function name from a regex match."""
    groups = _NAME_GROUPS.get(ext, ())
    for group_index in groups:
        name = match.group(group_index)
        if name:
            return name
    return "anonymous"


def _find_functions(lines, pattern, ext):
    """Find function boundaries in source lines. Returns [(name, start, end)]."""
    functions = []
    for i, line in enumerate(lines):
        match = pattern.match(line)
        if match:
            name = _extract_func_name(match, ext)
            functions.append((name, i))

    # Determine end lines: each function ends at the line before the next
    result = []
    for idx, (name, start) in enumerate(functions):
        if idx + 1 < len(functions):
            end = functions[idx + 1][1] - 1
        else:
            end = len(lines) - 1
        result.append((name, start, end))
    return result


def _read_file_content(filepath):
    """Read file content, returning None if unreadable."""
    try:
        with open(filepath) as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def _count_branches(lines, start, end):
    """Count branching keywords in a range of source lines."""
    count = 1  # base complexity
    for line in lines[start:end + 1]:
        if BRANCH_PATTERN.search(line):
            count += 1
    return count


def _check_function(filepath, func_name, func_length, branch_count,
                    max_lines, max_complexity):
    """Build violation dicts for a single function if thresholds exceeded."""
    violations = []
    if max_lines and func_length > max_lines:
        violations.append({
            "file": filepath, "function": func_name,
            "lines": func_length, "max": max_lines,
            "type": "function_length",
        })
    if max_complexity and branch_count > max_complexity:
        violations.append({
            "file": filepath, "function": func_name,
            "complexity": branch_count, "max": max_complexity,
            "type": "cyclomatic_complexity",
        })
    return violations


def _analyze_single_file(filepath, max_lines, max_complexity):
    """Analyze one file with the regex heuristic."""
    ext = filepath.rsplit(".", 1)[-1] if "." in filepath else ""
    pattern = _get_func_pattern(ext)
    if not pattern:
        return []

    content = _read_file_content(filepath)
    if content is None:
        return []

    lines = content.splitlines()
    functions = _find_functions(lines, pattern, ext)
    violations = []

    for func_name, start, end in functions:
        func_length = end - start + 1
        branch_count = _count_branches(lines, start, end)
        violations.extend(
            _check_function(
                filepath, func_name, func_length, branch_count,
                max_lines, max_complexity,
            )
        )
    return violations


def heuristic_analyze(files, max_lines, max_complexity):
    """Analyze files with regex heuristic, return violations."""
    violations = []
    for filepath in files:
        if not os.path.isfile(filepath):
            continue
        violations.extend(
            _analyze_single_file(filepath, max_lines, max_complexity)
        )
    return violations


# --- Allowlist ---


def check_allowlist(allow_config, violation):
    """Check if a violation is in the allowlist. Returns True to skip."""
    entries = allow_config.get("complexity", [])
    if not entries:
        return False

    for entry in entries:
        match = True
        for key, value in entry.items():
            if key == "reason":
                continue
            violation_value = str(violation.get(key, ""))
            entry_value = str(value)
            if not fnmatch.fnmatch(violation_value, entry_value) and (
                violation_value != entry_value
            ):
                match = False
                break
        if match:
            return True
    return False
