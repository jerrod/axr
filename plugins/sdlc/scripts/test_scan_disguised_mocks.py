"""Tests for scan_disguised_mocks.py — direct unit tests for the scanner."""

import json
import os
import subprocess
import sys
import tempfile

from scan_disguised_mocks import scan_file


def _write_temp(content, suffix=".test.ts"):
    fd, path = tempfile.mkstemp(suffix=suffix)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path


def _scan(content, suffix=".test.ts"):
    path = _write_temp(content, suffix)
    try:
        return scan_file(path)
    finally:
        os.unlink(path)


# --- JS/TS: should detect ---


def test_spy_on_mock_implementation():
    violations = _scan('vi.spyOn(mod, "fn").mockImplementation(() => fake);')
    assert len(violations) == 1
    assert violations[0]["pattern"] == "spyOn().mockImplementation()"


def test_spy_on_mock_return_value():
    violations = _scan("jest.spyOn(utils, 'calc').mockReturnValue(42);")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "spyOn().mockReturnValue()"


def test_spy_on_mock_resolved_value():
    violations = _scan("vi.spyOn(svc, 'fetch').mockResolvedValue({ data: [] });")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "spyOn().mockResolvedValue()"


def test_spy_on_mock_rejected_value():
    violations = _scan("vi.spyOn(svc, 'save').mockRejectedValue(new Error('x'));")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "spyOn().mockRejectedValue()"


def test_jest_mock_relative_import():
    violations = _scan("jest.mock('./my-module');")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "jest.mock() on relative import"


def test_vi_mock_relative_import():
    violations = _scan("vi.mock('./my-module');")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "jest.mock() on relative import"


def test_multiple_violations_in_one_file():
    content = """
vi.spyOn(a, 'x').mockImplementation(() => 1);
vi.spyOn(b, 'y').mockReturnValue(2);
jest.mock('./internal');
"""
    violations = _scan(content)
    assert len(violations) == 3


# --- JS/TS: should NOT detect ---


def test_real_spy_no_mock_chain():
    violations = _scan("const spy = jest.spyOn(svc, 'charge');")
    assert len(violations) == 0


def test_jest_mock_external_package():
    violations = _scan("jest.mock('axios');")
    assert len(violations) == 0


def test_vi_mock_external_package():
    violations = _scan("vi.mock('stripe');")
    assert len(violations) == 0


def test_plain_function_call():
    violations = _scan("""
import { calc } from '../calc';
test('works', () => { expect(calc(1)).toBe(2); });
""")
    assert len(violations) == 0


# --- Python: should detect ---


def test_python_patch_without_wraps():
    violations = _scan("@patch('mymod.func')\ndef test_it(): pass", suffix="_test.py")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "@patch without wraps"


def test_python_patch_object_return_value():
    violations = _scan(
        "with patch.object(proc, 'validate', return_value=True):",
        suffix="_test.py",
    )
    assert len(violations) == 1
    assert violations[0]["pattern"] == "patch.object with return_value (no wraps)"


def test_python_mock_assignment():
    violations = _scan("service.handler = Mock()", suffix="_test.py")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "Mock/MagicMock assignment"


def test_python_magic_mock_assignment():
    violations = _scan("service.handler = MagicMock()", suffix="_test.py")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "Mock/MagicMock assignment"


# --- Python: should NOT detect ---


def test_python_patch_with_wraps():
    violations = _scan(
        "with patch.object(proc, 'validate', wraps=proc.validate) as spy:",
        suffix="_test.py",
    )
    assert len(violations) == 0


def test_python_plain_test():
    violations = _scan(
        "def test_parse():\n    result = parse('x')\n    assert result == 'y'",
        suffix="_test.py",
    )
    assert len(violations) == 0


# --- Ruby: should detect ---


def test_ruby_allow_receive():
    violations = _scan(
        'allow(service).to receive(:process).and_return(true)', suffix="_spec.rb"
    )
    assert len(violations) == 1
    assert violations[0]["pattern"] == "allow().to receive() on internal"


def test_ruby_double():
    violations = _scan('let(:user) { double("User", name: "Test") }', suffix="_spec.rb")
    assert len(violations) == 1
    assert violations[0]["pattern"] == "double() for code under test"


def test_ruby_stub():
    violations = _scan("obj.stub(:method).and_return(42)", suffix="_spec.rb")
    assert len(violations) == 1
    assert violations[0]["pattern"] == ".stub() on own method"


# --- Ruby: should NOT detect ---


def test_ruby_plain_rspec_test():
    violations = _scan(
        'it "returns true" do\n  expect(subject.valid?).to be true\nend',
        suffix="_spec.rb",
    )
    assert len(violations) == 0


def test_ruby_expect_receive_not_flagged():
    # expect().to receive is a message expectation (spy), not a mock replacement
    violations = _scan(
        'expect(service).to receive(:call).with(params)', suffix="_spec.rb"
    )
    assert len(violations) == 0


# --- Line numbers ---


def test_reports_correct_line_number():
    content = "line1\nline2\nvi.spyOn(x, 'y').mockImplementation(fn);\nline4"
    violations = _scan(content)
    assert len(violations) == 1
    assert violations[0]["line"] == 3


def test_truncates_long_code():
    long_line = "vi.spyOn(x, 'y').mockImplementation(" + "a" * 200 + ");"
    violations = _scan(long_line)
    assert len(violations) == 1
    assert len(violations[0]["code"]) <= 120


# --- CLI entry point ---

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "scan_disguised_mocks.py")


def test_cli_no_args_prints_usage():
    result = subprocess.run(
        [sys.executable, SCRIPT_PATH],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "Usage:" in result.stderr


def test_cli_with_violations_prints_json():
    path = _write_temp('vi.spyOn(mod, "fn").mockImplementation(() => fake);')
    try:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, path],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        violations = json.loads(result.stdout)
        assert len(violations) == 1
        assert violations[0]["pattern"] == "spyOn().mockImplementation()"
    finally:
        os.unlink(path)


def test_cli_clean_file_no_output():
    path = _write_temp("const x = 1;")
    try:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, path],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == ""
    finally:
        os.unlink(path)
