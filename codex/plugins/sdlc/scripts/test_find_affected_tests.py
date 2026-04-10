"""Tests for find_affected_tests.py — Python import graph walker."""

import os
import subprocess
import sys

import find_affected_tests as fat

SCRIPT = os.path.join(os.path.dirname(__file__), "find_affected_tests.py")


def run_finder(changed_files, project_dir):
    """Run find_affected_tests.py with given changed files in project_dir."""
    result = subprocess.run(
        [sys.executable, SCRIPT] + changed_files,
        capture_output=True,
        text=True,
        cwd=project_dir,
    )
    return sorted(result.stdout.strip().splitlines()) if result.stdout.strip() else []


def write_file(base, path, content=""):
    """Write a file at base/path, creating directories as needed."""
    full = os.path.join(base, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)
    return path


class TestFindAffectedTests:
    def test_direct_import(self, tmp_path):
        write_file(tmp_path, "calc.py", "def add(a,b): return a+b")
        write_file(
            tmp_path,
            "test_calc.py",
            "import calc\ndef test_add(): assert calc.add(1,2)==3",
        )
        write_file(tmp_path, "utils.py", "X=1")
        write_file(
            tmp_path, "test_utils.py", "import utils\ndef test_x(): assert utils.X==1"
        )

        result = run_finder(["calc.py"], str(tmp_path))
        assert result == ["test_calc.py"]

    def test_from_import(self, tmp_path):
        write_file(tmp_path, "math_ops.py", "def multiply(a,b): return a*b")
        write_file(
            tmp_path,
            "test_math.py",
            "from math_ops import multiply\ndef test_mul(): assert multiply(2,3)==6",
        )

        result = run_finder(["math_ops.py"], str(tmp_path))
        assert result == ["test_math.py"]

    def test_transitive_import(self, tmp_path):
        write_file(tmp_path, "core.py", "VALUE=42")
        write_file(tmp_path, "helper.py", "import core\ndef get(): return core.VALUE")
        write_file(
            tmp_path,
            "test_helper.py",
            "import helper\ndef test_get(): assert helper.get()==42",
        )

        result = run_finder(["core.py"], str(tmp_path))
        assert result == ["test_helper.py"]


class TestFindAffectedTestsNegative:
    def test_no_affected_tests(self, tmp_path):
        write_file(tmp_path, "unrelated.py", "X=1")
        write_file(tmp_path, "calc.py", "def add(a,b): return a+b")
        write_file(tmp_path, "test_calc.py", "import calc\ndef test_add(): pass")

        result = run_finder(["unrelated.py"], str(tmp_path))
        assert result == []

    def test_multiple_changed_files(self, tmp_path):
        write_file(tmp_path, "a.py", "A=1")
        write_file(tmp_path, "b.py", "B=2")
        write_file(tmp_path, "test_a.py", "import a\ndef test_a(): pass")
        write_file(tmp_path, "test_b.py", "import b\ndef test_b(): pass")

        result = run_finder(["a.py", "b.py"], str(tmp_path))
        assert result == ["test_a.py", "test_b.py"]


class TestFindAffectedTestsCliPaths:
    def test_subdirectory_imports(self, tmp_path):
        write_file(tmp_path, "pkg/__init__.py", "")
        write_file(tmp_path, "pkg/core.py", "X=1")
        write_file(tmp_path, "test_pkg.py", "from pkg import core\ndef test_x(): pass")

        result = run_finder(["pkg/core.py"], str(tmp_path))
        assert result == ["test_pkg.py"]

    def test_always_exits_zero(self, tmp_path):
        result = subprocess.run(
            [sys.executable, SCRIPT, "nonexistent.py"],
            capture_output=True,
            text=True,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""


class TestFindAffectedTestsEdgeCases:
    def test_test_files_in_subdirs(self, tmp_path):
        write_file(tmp_path, "lib/engine.py", "def run(): pass")
        write_file(
            tmp_path,
            "tests/test_engine.py",
            "from lib.engine import run\ndef test_run(): pass",
        )

        result = run_finder(["lib/engine.py"], str(tmp_path))
        assert result == ["tests/test_engine.py"]

    def test_circular_imports(self, tmp_path):
        write_file(tmp_path, "a.py", "import b\nX=1")
        write_file(tmp_path, "b.py", "import a\nY=2")
        write_file(tmp_path, "test_a.py", "import a\ndef test_a(): pass")

        result = run_finder(["a.py"], str(tmp_path))
        assert result == ["test_a.py"]

    def test_suffix_test_naming(self, tmp_path):
        write_file(tmp_path, "parser.py", "def parse(): pass")
        write_file(tmp_path, "parser_test.py", "import parser\ndef test_parse(): pass")

        result = run_finder(["parser.py"], str(tmp_path))
        assert result == ["parser_test.py"]


class TestUnitFunctions:
    def test_find_test_files_skips_non_py(self, tmp_path):
        write_file(tmp_path, "test_foo.py", "")
        write_file(tmp_path, "README.md", "")
        write_file(tmp_path, "test_bar.txt", "")
        result = fat.find_test_files(str(tmp_path))
        assert result == ["test_foo.py"]

    def test_extract_imports_missing_file(self, tmp_path):
        result = fat.extract_imports("nonexistent.py", str(tmp_path))
        assert result == []

    def test_extract_imports_syntax_error(self, tmp_path):
        write_file(tmp_path, "bad.py", "def broken(:\n    pass")
        result = fat.extract_imports("bad.py", str(tmp_path))
        assert result == []

    def test_extract_imports_from_no_module(self, tmp_path):
        # `from . import foo` has node.module = None — should not error
        write_file(tmp_path, "rel.py", "from . import foo")
        result = fat.extract_imports("rel.py", str(tmp_path))
        assert result == []


class TestDependencyGraphEdgeCases:
    def test_build_dependency_graph_self_import_excluded(self, tmp_path):
        # A file that imports itself (via alias) should not appear in its own deps
        write_file(tmp_path, "self_ref.py", "import self_ref")
        graph = fat.build_dependency_graph(str(tmp_path))
        assert "self_ref.py" not in graph.get("self_ref.py", set())

    def test_build_dependency_graph_circular_visited_branch(self, tmp_path):
        # Two files importing each other — exercises the `if dep in visited: continue` branch
        write_file(tmp_path, "ping.py", "import pong\nX=1")
        write_file(tmp_path, "pong.py", "import ping\nY=2")
        graph = fat.build_dependency_graph(str(tmp_path))
        # Both are reachable from each other; no infinite loop
        assert "pong.py" in graph["ping.py"]
        assert "ping.py" in graph["pong.py"]

    def test_main_no_args_returns_early(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setattr(sys, "argv", ["find_affected_tests.py"])
        monkeypatch.chdir(tmp_path)
        fat.main()
        captured = capsys.readouterr()
        assert captured.out == ""

    def test_main_exception_handler_in_dunder_main(self, tmp_path):
        # The __main__ try/except block — exercise by running script directly
        # with an empty cwd so no files are walked. Verifies the guard runs
        # and exits 0 on a normal invocation.
        result = subprocess.run(
            [sys.executable, SCRIPT],
            capture_output=True,
            text=True,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""


class TestNewResolverBehavior:
    """Coverage for main() body and sibling-relative import resolution."""

    def test_main_prints_affected_tests(self, tmp_path, monkeypatch, capsys):
        # Exercise main() body: changed file → test file walk
        write_file(tmp_path, "core.py", "X = 1")
        write_file(tmp_path, "test_core.py", "import core\nassert core.X == 1")
        monkeypatch.setattr(sys, "argv", ["find_affected_tests.py", "core.py"])
        monkeypatch.chdir(tmp_path)
        fat.main()
        assert "test_core.py" in capsys.readouterr().out

    def test_extract_from_import_with_module(self, tmp_path):
        # `from pkg import name` extracts both pkg and pkg.name candidates
        write_file(tmp_path, "user.py", "from pkg import name")
        result = fat.extract_imports("user.py", str(tmp_path))
        assert "pkg" in result
        assert "pkg.name" in result

    def test_resolve_sibling_relative_import(self, tmp_path):
        # importer in a subdir imports a sibling — must resolve via
        # importer_dir, not the project root
        write_file(tmp_path, "sub/sibling.py", "Y = 2")
        write_file(tmp_path, "sub/user.py", "import sibling\nZ = sibling.Y")
        graph = fat.build_dependency_graph(str(tmp_path))
        assert os.path.join("sub", "sibling.py") in graph.get(
            os.path.join("sub", "user.py"), set()
        )

    def test_resolve_import_returns_none_for_unresolvable(self):
        # A module name that doesn't exist in the project resolves to None
        assert fat.resolve_import_to_file("nonexistent_module", []) is None

    def test_directly_changed_test_file_is_reported(self, tmp_path, monkeypatch, capsys):
        # When a test file itself is the changed file, it must appear in
        # affected output even though self-edges are stripped from the dep
        # graph. Previously main() missed this case.
        write_file(tmp_path, "test_standalone.py", "def test_x(): assert True")
        monkeypatch.setattr(sys, "argv", ["find_affected_tests.py", "test_standalone.py"])
        monkeypatch.chdir(tmp_path)
        fat.main()
        assert "test_standalone.py" in capsys.readouterr().out
