"""Integration tests for collect_metrics_payload.py — collect and build."""

import json
import os
import tempfile

from collect_metrics_payload import (
    build_payload,
    collect_gates,
    collect_single_gate,
)
from conftest import _make_proof_dir
from payload_context import PayloadContext


def _ctx(proof_dir, *, verdict="approved", count=0, repo="r", branch="b",
         sha="s", user="u", ts="t", phase="all", gate_name="", data_dir=""):
    """Build a PayloadContext for tests. Replaces the old _patch_globals
    monkeypatch helper — tests pass the context explicitly now."""
    return PayloadContext(
        proof_dir=proof_dir,
        critic_verdict_arg=verdict,
        critic_count_arg=count,
        repo=repo, branch=branch, sha=sha, user=user, timestamp=ts,
        phase=phase, gate_name=gate_name, metrics_data_dir=data_dir,
    )


# --- collect_gates ---


def test_collect_gates_all_pass():
    d = _make_proof_dir({
        "lint": {"status": "pass", "files_checked": 10},
        "tests": {"status": "pass", "files_checked": 5},
    })
    gates, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is True
    assert fail_after == 0
    assert missed == []
    assert "lint" in gates
    assert "tests" in gates


def test_collect_gates_with_failure():
    d = _make_proof_dir({
        "lint": {"status": "fail", "violations": ["x"]},
        "tests": {"status": "pass"},
    })
    gates, is_first_pass, fail_after, missed = collect_gates(d, "unknown")
    assert is_first_pass is False
    assert fail_after == 0
    assert missed == []


def test_collect_gates_failure_after_critic_approved():
    d = _make_proof_dir({
        "lint": {"status": "fail", "violations": ["x"]},
    })
    gates, is_first_pass, fail_after, missed = collect_gates(d, "approved")
    assert is_first_pass is False
    assert fail_after == 1
    assert missed == ["lint"]


def test_collect_gates_skips_reserved_names():
    d = _make_proof_dir({
        "critic": {"status": "pass"},
        "metrics": {"status": "pass"},
        "PROOF": {"status": "pass"},
        ".init": {"status": "pass"},
        "lint": {"status": "pass"},
    })
    gates, is_first_pass, _, _ = collect_gates(d, "unknown")
    assert list(gates.keys()) == ["lint"]
    assert is_first_pass is True


def test_collect_gates_skips_malformed_json():
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "bad.json"), "w") as f:
        f.write("{invalid")
    with open(os.path.join(d, "good.json"), "w") as f:
        json.dump({"status": "pass"}, f)
    gates, is_first_pass, _, _ = collect_gates(d, "unknown")
    assert "good" in gates
    assert "bad" not in gates


def test_collect_gates_empty_dir():
    d = tempfile.mkdtemp()
    gates, is_first_pass, fail_after, missed = collect_gates(d, "unknown")
    assert gates == {}
    # No gates found means proof files are missing — not a pass
    assert is_first_pass is False


# --- collect_single_gate ---


def test_collect_single_gate_found():
    d = _make_proof_dir({"lint": {"status": "pass", "files_checked": 5}})
    gates = collect_single_gate(d, "lint")
    assert "lint" in gates
    assert gates["lint"]["status"] == "pass"
    assert gates["lint"]["files_checked"] == 5


def test_collect_single_gate_hyphen_to_underscore():
    d = _make_proof_dir({"dead_code": {"status": "fail", "violations": ["x"]}})
    gates = collect_single_gate(d, "dead-code")
    assert "dead-code" in gates
    assert gates["dead-code"]["status"] == "fail"


def test_collect_single_gate_not_found():
    d = _make_proof_dir({"lint": {"status": "pass"}})
    gates = collect_single_gate(d, "nonexistent")
    assert gates == {}


# --- build_payload ---


def test_build_payload_identity_fields():
    d = _make_proof_dir({
        "lint": {"status": "pass", "files_checked": 3},
        "tests": {"status": "pass"},
    })
    payload = build_payload(_ctx(
        d, verdict="approved", repo="my-repo", branch="main",
        sha="abc1234", user="dev", ts="2025-01-01T00:00:00Z", phase="build",
    ))
    assert payload["repo"] == "my-repo"
    assert payload["sha"] == "abc1234"
    assert payload["phase"] == "build"
    assert payload["run_number"] == 1
    assert payload["gate_name"] is None


def test_build_payload_gate_results():
    d = _make_proof_dir({
        "lint": {"status": "pass", "files_checked": 3},
        "tests": {"status": "pass"},
    })
    payload = build_payload(_ctx(
        d, verdict="approved", repo="my-repo", branch="main",
        sha="abc1234", user="dev", ts="2025-01-01T00:00:00Z", phase="build",
    ))
    assert payload["critic_verdict"] == "approved"
    assert payload["gates_first_pass"] is True
    assert payload["gate_failures_after_critic"] == 0
    assert payload["missed_gates"] == []
    assert set(payload["gates_run"]) == {"lint", "tests"}


def test_build_payload_with_failures():
    d = _make_proof_dir({"lint": {"status": "fail", "violations": ["a"]}})
    payload = build_payload(_ctx(d, verdict=None))
    assert payload["gates_first_pass"] is False
    assert payload["critic_verdict"] == "unknown"
    assert payload["phase"] == "all"
    assert payload["run_number"] == 1


def test_build_payload_includes_duration():
    d = _make_proof_dir({
        "lint": {"status": "pass", "timestamp": "2025-01-01T10:00:00Z"},
        "tests": {"status": "pass", "timestamp": "2025-01-01T10:02:00Z"},
    })
    assert build_payload(_ctx(d))["duration_seconds"] == 120.0


def test_build_payload_no_duration_without_timestamps():
    d = _make_proof_dir({"lint": {"status": "pass"}})
    assert build_payload(_ctx(d))["duration_seconds"] is None


def test_build_payload_run_number_counts_only_summary_files():
    d = _make_proof_dir({"lint": {"status": "pass"}})
    with tempfile.TemporaryDirectory() as data_dir:
        # Summary file (sha-YYYYMMDDHHMMSS.json) — counts
        with open(os.path.join(data_dir, "abc-20250101120000.json"), "w") as f:
            f.write("{}")
        # Per-gate file (sha-gatename-YYYYMMDDHHMMSS.json) — does NOT count
        with open(os.path.join(data_dir, "abc-lint-20250102120000.json"), "w") as f:
            f.write("{}")
        payload = build_payload(_ctx(d, sha="abc", data_dir=data_dir))
        # Only the 1 summary file counts, so run_number = 2
        assert payload["run_number"] == 2


def test_build_payload_per_gate_mode():
    d = _make_proof_dir({
        "lint": {"status": "pass", "files_checked": 3},
        "tests": {"status": "fail", "failures": ["x"]},
    })
    payload = build_payload(_ctx(d, gate_name="lint", phase="build"))
    assert payload["gate_name"] == "lint"
    assert payload["gates_run"] == ["lint"]
    assert payload["gates_first_pass"] is True
    assert "tests" not in payload["gates"]


def test_build_payload_per_gate_mode_fail():
    d = _make_proof_dir({"lint": {"status": "fail", "violations": ["a"]}})
    payload = build_payload(_ctx(d, gate_name="lint"))
    assert payload["gate_name"] == "lint"
    assert payload["gates_first_pass"] is False


def test_build_payload_per_gate_not_found():
    d = _make_proof_dir({"lint": {"status": "pass"}})
    payload = build_payload(_ctx(d, gate_name="nonexistent"))
    assert payload["gate_name"] == "nonexistent"
    assert payload["gates_run"] == []
    assert payload["gates"] == {}
    # A missing gate proof is a failure, not vacuous success
    assert payload["gates_first_pass"] is False
