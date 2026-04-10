#!/usr/bin/env python3
"""Scan test files for disguised mock patterns.

Detects spyOn().mockImplementation() and similar patterns that replace
real code while wearing a spy costume. Outputs JSON array of violations.

Usage: python3 scan_disguised_mocks.py <test_file>
"""

import json
import os
import re
import sys


# JS/TS patterns that turn a spy into a mock
DISGUISED_MOCK_PATTERNS = [
    (
        r"(?:vi|jest)\.spyOn\([^)]+\)\.mockImplementation\(",
        "spyOn().mockImplementation()",
    ),
    (r"(?:vi|jest)\.spyOn\([^)]+\)\.mockReturnValue\(", "spyOn().mockReturnValue()"),
    (
        r"(?:vi|jest)\.spyOn\([^)]+\)\.mockResolvedValue\(",
        "spyOn().mockResolvedValue()",
    ),
    (
        r"(?:vi|jest)\.spyOn\([^)]+\)\.mockRejectedValue\(",
        "spyOn().mockRejectedValue()",
    ),
    (r"""(?:vi|jest)\.mock\(['"]\.\/""", "jest.mock() on relative import"),
]

# Python patterns
PYTHON_PATTERNS = [
    (r"@patch\([^)]*\)(?!.*wraps)", "@patch without wraps"),
    (
        r"patch\.object\([^)]*return_value\s*=(?!.*wraps)",
        "patch.object with return_value (no wraps)",
    ),
    (r"=\s*(?:Mock|MagicMock)\(", "Mock/MagicMock assignment"),
]

# Java/Kotlin patterns (Mockito, MockK)
JAVA_KOTLIN_PATTERNS = [
    (r"@Mock\b", "@Mock on class under test"),
    (r"Mockito\.mock\(", "Mockito.mock() on internal class"),
    (r"when\([^)]+\)\.thenReturn\(", "when().thenReturn() on internal method"),
    (r"every\s*\{[^}]*\}\s*returns\b", "MockK every{} returns on internal"),
    (r"mockk<", "mockk<>() on internal class"),
]

# Go patterns
GO_PATTERNS = [
    (r"mock\.Mock\b", "mock.Mock on own interface"),
]

# Ruby patterns (RSpec, Minitest)
RUBY_PATTERNS = [
    (r"allow\([^)]+\)\.to\s+receive\(", "allow().to receive() on internal"),
    (r"double\(", "double() for code under test"),
    (r"\.stub\(", ".stub() on own method"),
]


def _select_patterns(filepath):
    """Return the appropriate pattern list based on file extension."""
    ext = os.path.splitext(filepath)[1].lstrip(".")
    if ext in ("ts", "tsx", "js", "jsx"):
        return DISGUISED_MOCK_PATTERNS
    if ext == "py":
        return PYTHON_PATTERNS
    if ext in ("java", "kt", "kts"):
        return JAVA_KOTLIN_PATTERNS
    if ext == "go":
        return GO_PATTERNS
    if ext == "rb":
        return RUBY_PATTERNS
    return []


def _scan_lines(lines, patterns):
    """Scan lines against patterns and return violations."""
    violations = []
    for i, line in enumerate(lines, 1):
        for pattern, description in patterns:
            if re.search(pattern, line):
                violations.append(
                    {
                        "line": i,
                        "pattern": description,
                        "code": line.rstrip()[:120],
                    }
                )
    return violations


def scan_file(filepath):
    with open(filepath) as f:
        lines = f.readlines()
    return _scan_lines(lines, _select_patterns(filepath))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: scan_disguised_mocks.py <test_file>", file=sys.stderr)
        sys.exit(1)

    violations = scan_file(sys.argv[1])
    if violations:
        print(json.dumps(violations))
