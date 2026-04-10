"""Tests for analyze_complexity.py — entry point, file grouping, run_analysis."""

import json
from unittest.mock import patch

from analyze_complexity import group_files_by_language, main, parse_args, run_analysis


# --- group_files_by_language ---


def test_group_python_files():
    groups = group_files_by_language(["src/app.py", "lib/utils.py"])
    assert groups["python"] == ["src/app.py", "lib/utils.py"]
    assert groups["js_ts"] == []


def test_group_js_ts_files():
    groups = group_files_by_language(["app.ts", "comp.tsx", "lib.js", "x.jsx"])
    assert groups["js_ts"] == ["app.ts", "comp.tsx", "lib.js", "x.jsx"]


def test_group_go_files():
    groups = group_files_by_language(["main.go", "handler.go"])
    assert groups["go"] == ["main.go", "handler.go"]


def test_group_heuristic_files():
    groups = group_files_by_language(["lib.rs", "app.rb", "Main.java", "App.kt"])
    assert groups["heuristic"] == ["lib.rs", "app.rb", "Main.java", "App.kt"]


def test_group_mixed_files():
    files = ["a.py", "b.ts", "c.go", "d.rs", "e.jsx"]
    groups = group_files_by_language(files)
    assert groups["python"] == ["a.py"]
    assert groups["js_ts"] == ["b.ts", "e.jsx"]
    assert groups["go"] == ["c.go"]
    assert groups["heuristic"] == ["d.rs"]


def test_group_unknown_extension():
    groups = group_files_by_language(["readme.txt", "data.csv"])
    assert groups["heuristic"] == ["readme.txt", "data.csv"]


def test_group_empty_list():
    groups = group_files_by_language([])
    for lang_files in groups.values():
        assert lang_files == []


# --- run_analysis ---


def test_run_analysis_empty_files():
    violations = run_analysis([], 50, 8, {})
    assert violations == []


def test_run_analysis_with_allowlist(tmp_path):
    code = "def big_func():\n" + "    x = 1\n" * 55
    filepath = str(tmp_path / "allowed.py")
    with open(filepath, "w") as f:
        f.write(code)
    allow = {"complexity": [{"file": filepath}]}
    with patch(
        "complexity_tools.subprocess.run", side_effect=FileNotFoundError
    ):
        violations = run_analysis([filepath], 50, 8, allow)
    assert violations == []


def test_run_analysis_mixed_languages(tmp_path):
    py_code = "def big():\n" + "    x = 1\n" * 55
    ts_code = "export function big() {\n" + "  const x = 1;\n" * 55 + "}\n"
    py_file = str(tmp_path / "app.py")
    ts_file = str(tmp_path / "app.ts")
    with open(py_file, "w") as f:
        f.write(py_code)
    with open(ts_file, "w") as f:
        f.write(ts_code)
    with patch(
        "complexity_tools.subprocess.run", side_effect=FileNotFoundError
    ):
        violations = run_analysis([py_file, ts_file], 50, 8, {})
    length_violations = [v for v in violations if v["type"] == "function_length"]
    assert len(length_violations) == 2


def test_run_analysis_go_files(tmp_path):
    code = "func Big() {\n" + "\tx := 1\n" * 55 + "}\n"
    filepath = str(tmp_path / "main.go")
    with open(filepath, "w") as f:
        f.write(code)
    with patch(
        "complexity_tools.subprocess.run", side_effect=FileNotFoundError
    ):
        violations = run_analysis([filepath], 50, 8, {})
    length_violations = [v for v in violations if v["type"] == "function_length"]
    assert len(length_violations) == 1


def test_run_analysis_heuristic_files(tmp_path):
    code = "pub fn big_handler() {\n" + "    let x = 1;\n" * 55 + "}\n"
    filepath = str(tmp_path / "lib.rs")
    with open(filepath, "w") as f:
        f.write(code)
    violations = run_analysis([filepath], 50, 8, {})
    length_violations = [v for v in violations if v["type"] == "function_length"]
    assert len(length_violations) == 1


# --- parse_args ---


def test_parse_args_defaults():
    args = parse_args([])
    assert args.files == []
    assert args.max_function_lines == 50
    assert args.max_complexity == 8
    assert args.allow_json == "{}"


def test_parse_args_custom():
    args = parse_args([
        "--files", "a.py", "b.ts",
        "--max-function-lines", "100",
        "--max-complexity", "12",
        "--allow-json", '{"complexity": []}',
    ])
    assert args.files == ["a.py", "b.ts"]
    assert args.max_function_lines == 100
    assert args.max_complexity == 12


# --- main() ---


def test_main_empty_files(capsys):
    main([])
    captured = capsys.readouterr()
    assert json.loads(captured.out) == []


def test_main_with_violations(capsys, tmp_path):
    code = "def big():\n" + "    x = 1\n" * 55
    filepath = str(tmp_path / "test.py")
    with open(filepath, "w") as f:
        f.write(code)
    with patch(
        "complexity_tools.subprocess.run", side_effect=FileNotFoundError
    ):
        main(["--files", filepath, "--max-function-lines", "50"])
    captured = capsys.readouterr()
    violations = json.loads(captured.out)
    assert len(violations) >= 1
    assert violations[0]["type"] == "function_length"


def test_main_invalid_allow_json(capsys, tmp_path):
    code = "def small():\n    pass\n"
    filepath = str(tmp_path / "test.py")
    with open(filepath, "w") as f:
        f.write(code)
    with patch(
        "complexity_tools.subprocess.run", side_effect=FileNotFoundError
    ):
        main(["--files", filepath, "--allow-json", "not-json"])
    captured = capsys.readouterr()
    assert json.loads(captured.out) == []
