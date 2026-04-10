"""Tests for metrics_filters — infrastructure-vs-real failure filtering
and its integration into collect_gates()."""

from collect_metrics_payload import collect_gates
from conftest import _make_proof_dir
from metrics_filters import is_infrastructure_failure


# --- is_infrastructure_failure (unit) ---


def test_lint_with_check_none_is_infra():
    proof = {"failures": [{"check": "none", "output": "FATAL: No linters"}]}
    assert is_infrastructure_failure("lint", proof) is True


def test_lint_with_real_tool_is_not_infra():
    proof = {"failures": [{"check": "ruff", "output": "F401 unused"}]}
    assert is_infrastructure_failure("lint", proof) is False


def test_lint_with_empty_failures_is_not_infra():
    assert is_infrastructure_failure("lint", {"failures": []}) is False
    assert is_infrastructure_failure("lint", {}) is False


def test_tests_with_tests_ran_false_is_infra():
    assert is_infrastructure_failure("tests", {"tests_ran": False}) is True


def test_tests_with_tests_ran_true_is_not_infra():
    assert is_infrastructure_failure("tests", {"tests_ran": True}) is False


def test_tests_missing_tests_ran_field_is_not_infra():
    assert is_infrastructure_failure("tests", {}) is False


def test_other_gates_never_infra():
    # Only lint and tests have infra-failure detection; other gates are
    # always real failures.
    proof = {"failures": [{"check": "none"}], "tests_ran": False}
    assert is_infrastructure_failure("complexity", proof) is False
    assert is_infrastructure_failure("filesize", proof) is False
    assert is_infrastructure_failure("coverage", proof) is False


# --- collect_gates integration ---


def test_collect_gates_lint_no_tooling_excluded_from_catch_rate():
    """Lint failure with check=none must not count toward catch_rate —
    the critic cannot catch missing infrastructure."""
    d = _make_proof_dir({
        "lint": {
            "status": "fail",
            "failures": [
                {"check": "none", "output": "FATAL: No linters detected"}
            ],
        },
    })
    _, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is False  # still a failure
    assert fail_after == 0  # but not a critic miss
    assert missed == []


def test_collect_gates_tests_no_runner_excluded_from_catch_rate():
    """tests_ran=false means no test runner — not a code regression."""
    d = _make_proof_dir({
        "tests": {"status": "fail", "tests_ran": False},
    })
    _, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is False
    assert fail_after == 0
    assert missed == []


def test_collect_gates_mixed_infra_and_real_failure():
    """Infra failures filtered, real code failures still count."""
    d = _make_proof_dir({
        "lint": {
            "status": "fail",
            "failures": [{"check": "none", "output": "FATAL"}],
        },
        "complexity": {
            "status": "fail",
            "violations": [{"file": "foo.py", "complexity": 12}],
        },
    })
    _, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is False
    assert fail_after == 1
    assert missed == ["complexity"]


def test_collect_gates_real_lint_failure_still_counts():
    """Lint failure with a real tool output is a genuine escape."""
    d = _make_proof_dir({
        "lint": {
            "status": "fail",
            "failures": [{"check": "ruff", "output": "F401 unused import"}],
        },
    })
    _, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is False
    assert fail_after == 1
    assert missed == ["lint"]
