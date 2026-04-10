#!/usr/bin/env python3
"""Find test files affected by changed source files via Python import graph.

Usage: find_affected_tests.py <changed_file1> [changed_file2 ...]
Output: One affected test file path per line on stdout.
Exit: Always 0 (empty output = no affected tests).

Walks the import graph transitively: if test_a.py imports helper.py
which imports changed.py, test_a.py is affected.
"""

import ast
import os
import sys


def find_test_files(root):
    """Find all test_*.py and *_test.py files under root."""
    test_files = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith(".py"):
                continue
            if name.startswith("test_") or name.endswith("_test.py"):
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                test_files.append(rel)
    return test_files


def find_all_python_files(root):
    """Find all .py files under root."""
    py_files = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".py"):
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                py_files.append(rel)
    return py_files


def extract_imports(filepath, root):
    """Extract imported module names from a Python file using ast."""
    full_path = os.path.join(root, filepath)
    if not os.path.isfile(full_path):
        return []
    try:
        with open(full_path) as f:
            tree = ast.parse(f.read(), filename=filepath)
    except (SyntaxError, UnicodeDecodeError):
        return []

    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imports.extend(_extract_from_import(node))
    return imports


def _extract_from_import(node):
    """Extract module names from an ast.ImportFrom node."""
    if not node.module:
        return []
    names = [node.module]
    # Also check sub-module candidates: `from pkg import core`
    # may reference pkg/core.py rather than pkg/__init__.py
    for alias in node.names:
        names.append(f"{node.module}.{alias.name}")
    return names


def resolve_import_to_file(module_name, all_files, importer_dir=""):
    """Resolve a dotted module name to a file path.

    Tries in order:
      1. Relative to the importing file's directory (sibling module)
      2. Relative to the project root (top-level module)
    Both packages (__init__.py) and single-file modules are checked.
    """
    parts = module_name.split(".")
    files_set = set(all_files)

    # 1. Sibling module relative to the importing file
    if importer_dir:
        for candidate in (
            os.path.join(importer_dir, *parts, "__init__.py"),
            os.path.join(importer_dir, *parts) + ".py",
        ):
            if candidate in files_set:
                return candidate

    # 2. Top-level module relative to the project root
    for candidate in (
        os.path.join(*parts, "__init__.py"),
        os.path.join(*parts) + ".py",
    ):
        if candidate in files_set:
            return candidate
    return None


def build_dependency_graph(root):
    """Build a mapping of file -> set of files it depends on (transitively)."""
    all_files = find_all_python_files(root)
    direct_deps = {}
    for filepath in all_files:
        imports = extract_imports(filepath, root)
        importer_dir = os.path.dirname(filepath)
        deps = set()
        for imp in imports:
            resolved = resolve_import_to_file(imp, all_files, importer_dir)
            if resolved and resolved != filepath:
                deps.add(resolved)
        direct_deps[filepath] = deps

    # Compute transitive closure (handles circular imports via visited set)
    transitive = {}
    for filepath in all_files:
        visited = set()
        stack = list(direct_deps.get(filepath, []))
        while stack:
            dep = stack.pop()
            visited.add(dep)
            stack.extend(direct_deps.get(dep, set()) - visited)
        transitive[filepath] = visited

    return transitive


def main():
    changed_files = set(sys.argv[1:])
    if not changed_files:
        return

    root = os.getcwd()
    test_files = find_test_files(root)
    dep_graph = build_dependency_graph(root)

    affected = set()
    for test_file in test_files:
        # A directly-changed test file is affected by definition (self-edges
        # are stripped from the dep graph to prevent circular-import loops,
        # so they don't reach the deps intersection check below).
        if test_file in changed_files:
            affected.add(test_file)
            continue
        deps = dep_graph.get(test_file, set())
        if deps & changed_files:
            affected.add(test_file)

    for test_file in sorted(affected):
        print(test_file)


if __name__ == "__main__":  # pragma: no cover — exercised via subprocess
    try:
        main()
    except Exception as exc:
        print(f"find_affected_tests.py: {exc}", file=sys.stderr)
        # Always exit 0 — empty output means no affected tests
