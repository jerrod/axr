"""Tests for complexity_heuristic.py — regex fallback and allowlist."""

import pytest

from complexity_heuristic import (
    _analyze_single_file,
    _check_function,
    _count_branches,
    _extract_func_name,
    _find_functions,
    _get_func_pattern,
    _read_file_content,
    check_allowlist,
    heuristic_analyze,
)


# --- _get_func_pattern ---


def test_get_func_pattern_known():
    for ext in ("py", "go", "rs", "java", "kt", "ts", "tsx", "js", "jsx", "rb"):
        assert _get_func_pattern(ext) is not None


def test_get_func_pattern_unknown():
    assert _get_func_pattern("txt") is None
    assert _get_func_pattern("") is None


# --- _extract_func_name ---


def test_extract_python_func_name():
    pattern = _get_func_pattern("py")
    match = pattern.match("def my_func():")
    assert _extract_func_name(match, "py") == "my_func"


def test_extract_go_func_name():
    pattern = _get_func_pattern("go")
    match = pattern.match("func HandleRequest() {")
    assert _extract_func_name(match, "go") == "HandleRequest"


def test_extract_rust_func_name():
    pattern = _get_func_pattern("rs")
    match = pattern.match("pub async fn serve() {")
    assert _extract_func_name(match, "rs") == "serve"


def test_extract_js_named_func():
    pattern = _get_func_pattern("ts")
    match = pattern.match("export function handler() {")
    assert _extract_func_name(match, "ts") == "handler"


def test_extract_ruby_func_name():
    pattern = _get_func_pattern("rb")
    match = pattern.match("def process")
    assert _extract_func_name(match, "rb") == "process"


@pytest.mark.parametrize("line,expected", [
    ("def self.find_by_name", "find_by_name"),
    ("  def valid?", "valid?"),
    ("  def save!", "save!"),
    ("  def name=", "name="),
    ("def self.enabled?", "enabled?"),
])
def test_extract_ruby_method_variants(line, expected):
    pattern = _get_func_pattern("rb")
    match = pattern.match(line)
    assert match is not None
    assert _extract_func_name(match, "rb") == expected


def test_extract_java_func_name():
    pattern = _get_func_pattern("java")
    match = pattern.match("public void run() {")
    assert _extract_func_name(match, "java") == "run"


def test_extract_kotlin_func_name():
    pattern = _get_func_pattern("kt")
    match = pattern.match("fun execute() {")
    assert _extract_func_name(match, "kt") == "execute"


def test_extract_unknown_ext_returns_anonymous():
    # Simulate unknown ext with no groups
    pattern = _get_func_pattern("py")
    match = pattern.match("def foo():")
    assert _extract_func_name(match, "unknown") == "anonymous"


# --- _find_functions ---


def test_find_two_functions():
    lines = ["def a():", "    pass", "def b():", "    pass"]
    result = _find_functions(lines, _get_func_pattern("py"), "py")
    assert len(result) == 2
    assert result[0] == ("a", 0, 1)
    assert result[1] == ("b", 2, 3)


def test_find_no_functions():
    lines = ["x = 1", "y = 2"]
    result = _find_functions(lines, _get_func_pattern("py"), "py")
    assert result == []


# --- _read_file_content ---


def test_read_valid_file(tmp_path):
    filepath = str(tmp_path / "test.py")
    with open(filepath, "w") as f:
        f.write("hello")
    assert _read_file_content(filepath) == "hello"


def test_read_nonexistent_file():
    assert _read_file_content("/nonexistent/path.py") is None


def test_read_binary_file(tmp_path):
    filepath = str(tmp_path / "bin.py")
    with open(filepath, "wb") as f:
        f.write(b"\x80\x81\x82" * 100)
    assert _read_file_content(filepath) is None


# --- _count_branches ---


def test_count_branches_with_ifs():
    lines = ["def f():", "    if x:", "    elif y:", "    else:", "    pass"]
    assert _count_branches(lines, 0, 4) >= 3


def test_count_branches_no_branches():
    lines = ["def f():", "    x = 1", "    return x"]
    assert _count_branches(lines, 0, 2) == 1


@pytest.mark.parametrize("lines,expected", [
    (["def f", "  if x", "  elsif y", "  elsif z", "  end"], 4),
    (["def f", "  unless banned?", "    proceed", "  end"], 2),
    (["def f", "  begin", "    risky", "  rescue StandardError", "  end"], 2),
    (["def f", "  case status", "  when :active", "  when :pending", "  end"], 4),
    (["def f", "  until done?", "    work", "  end"], 2),
    (["def f", "  ok = a and b", "  ok = x or y", "  z = true"], 3),
])
def test_count_branches_ruby_keywords(lines, expected):
    assert _count_branches(lines, 0, len(lines) - 1) == expected


# --- _check_function ---


def test_check_function_length_violation():
    violations = _check_function("f.py", "big", 60, 2, 50, 8)
    assert len(violations) == 1
    assert violations[0]["type"] == "function_length"


def test_check_function_complexity_violation():
    violations = _check_function("f.py", "branchy", 10, 12, 50, 8)
    assert len(violations) == 1
    assert violations[0]["type"] == "cyclomatic_complexity"


def test_check_function_no_violation():
    violations = _check_function("f.py", "small", 10, 2, 50, 8)
    assert violations == []


def test_check_function_both_violations():
    violations = _check_function("f.py", "bad", 60, 12, 50, 8)
    assert len(violations) == 2


# --- _analyze_single_file ---


def test_analyze_single_file_with_violation(tmp_path):
    code = "def big():\n" + "    x = 1\n" * 55
    filepath = str(tmp_path / "app.py")
    with open(filepath, "w") as f:
        f.write(code)
    violations = _analyze_single_file(filepath, 50, 8)
    assert len(violations) >= 1


def test_analyze_ruby_file_with_class_methods(tmp_path):
    code = "def self.big_query\n" + "    x = 1\n" * 55 + "end\n"
    filepath = str(tmp_path / "model.rb")
    with open(filepath, "w") as f:
        f.write(code)
    violations = _analyze_single_file(filepath, 50, 8)
    assert len(violations) >= 1
    assert violations[0]["function"] == "big_query"


def test_analyze_ruby_complexity(tmp_path):
    code = (
        "def complex_method\n"
        "  if a\n"
        "  elsif b\n"
        "  elsif c\n"
        "  end\n"
        "  unless d\n"
        "  end\n"
        "  case x\n"
        "  when 1\n"
        "  when 2\n"
        "  when 3\n"
        "  end\n"
        "  y if z and w\n"
        "end\n"
    )
    filepath = str(tmp_path / "service.rb")
    with open(filepath, "w") as f:
        f.write(code)
    violations = _analyze_single_file(filepath, 50, 8)
    complexity_violations = [v for v in violations if v["type"] == "cyclomatic_complexity"]
    assert len(complexity_violations) == 1


def test_analyze_single_file_unknown_ext(tmp_path):
    filepath = str(tmp_path / "data.txt")
    with open(filepath, "w") as f:
        f.write("text\n" * 100)
    assert _analyze_single_file(filepath, 50, 8) == []


# --- heuristic_analyze ---


def test_heuristic_nonexistent_file():
    assert heuristic_analyze(["/no/such/file.py"], 50, 8) == []


def test_heuristic_clean_file(tmp_path):
    filepath = str(tmp_path / "clean.py")
    with open(filepath, "w") as f:
        f.write("def small():\n    return 1\n")
    assert heuristic_analyze([filepath], 50, 8) == []


# --- check_allowlist ---


def test_allowlist_match():
    allow = {"complexity": [{"file": "src/x.py"}]}
    assert check_allowlist(allow, {"file": "src/x.py"}) is True


def test_allowlist_no_match():
    allow = {"complexity": [{"file": "src/x.py"}]}
    assert check_allowlist(allow, {"file": "src/y.py"}) is False


def test_allowlist_empty():
    assert check_allowlist({}, {"file": "x.py"}) is False
