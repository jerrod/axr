"""Tests for collect_metrics_payload.py — unit tests for helper functions."""

import json
import os
import tempfile

from collect_metrics_payload import (
    _copy_list_details,
    _copy_matching_keys,
    _parse_timestamp,
    compute_duration,
    count_run_number,
    extract_gate_details,
    normalize_list_value,
    resolve_critic,
)


# --- normalize_list_value and _copy_matching_keys ---


def test_normalize_list_value_with_list():
    assert normalize_list_value([1, 2, 3]) == 3
    assert normalize_list_value([]) == 0


def test_normalize_list_value_with_non_list():
    assert normalize_list_value(42) == 42
    assert normalize_list_value("hello") == "hello"
    assert normalize_list_value(None) is None


def test_copy_matching_keys_no_transform():
    proof = {"files_checked": 10, "message": "ok", "extra": "ignored"}
    gate = {}
    _copy_matching_keys(proof, {"files_checked", "message"}, gate)
    assert gate == {"files_checked": 10, "message": "ok"}


def test_copy_matching_keys_with_transform():
    proof = {"violations": [1, 2], "failures": []}
    gate = {}
    _copy_matching_keys(proof, {"violations", "failures"}, gate, len)
    assert gate == {"violations": 2, "failures": 0}


def test_copy_matching_keys_missing_key_skipped():
    gate = {}
    _copy_matching_keys({"files_checked": 5}, {"files_checked", "absent"}, gate)
    assert gate == {"files_checked": 5}


# --- _copy_list_details ---


def test_copy_list_details_copies_raw_lists():
    proof = {"violations": ["a", "b"], "failures": []}
    gate = {}
    _copy_list_details(proof, {"violations", "failures"}, gate)
    assert gate["violations_details"] == ["a", "b"]
    assert gate["failures_details"] == []


def test_copy_list_details_skips_non_list():
    proof = {"violations": 7}
    gate = {}
    _copy_list_details(proof, {"violations"}, gate)
    assert "violations_details" not in gate


def test_copy_list_details_skips_missing_key():
    gate = {}
    _copy_list_details({}, {"violations"}, gate)
    assert gate == {}


# --- resolve_critic ---


def test_resolve_critic_from_args():
    assert resolve_critic("/nonexistent", "approved", 3) == ("approved", 3, [])


def test_resolve_critic_from_proof_file():
    findings = [
        {"rule": "FILE_SIZE", "file": "a.py"},
        {"rule": "COMPLEXITY", "file": "b.py"},
    ]
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "critic.json"), "w") as f:
            json.dump({"verdict": "needs-fixes", "findings": findings}, f)
        verdict, count, found = resolve_critic(d, None, 0)
        assert verdict == "needs-fixes"
        assert count == 2
        assert found == findings


def test_resolve_critic_no_args_no_file():
    assert resolve_critic("/nonexistent", None, 0) == ("unknown", 0, [])


def test_resolve_critic_args_take_precedence():
    """When verdict_arg is provided, proof file is not read."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "critic.json"), "w") as f:
            json.dump({"verdict": "needs-fixes", "findings": ["a"]}, f)
        assert resolve_critic(d, "approved", 5) == ("approved", 5, [])


def test_resolve_critic_empty_verdict_arg_reads_file():
    """Empty string verdict_arg is falsy, should read the file."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "critic.json"), "w") as f:
            json.dump({"verdict": "approved", "findings": []}, f)
        assert resolve_critic(d, "", 0) == ("approved", 0, [])


def test_resolve_critic_malformed_json():
    """Malformed critic.json should raise JSONDecodeError."""
    import pytest
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "critic.json"), "w") as f:
            f.write("{bad json")
        with pytest.raises(json.JSONDecodeError):
            resolve_critic(d, None, 0)


# --- _parse_timestamp ---


def test_parse_timestamp_utc_format():
    from datetime import datetime
    result = _parse_timestamp("2025-01-15T10:30:00Z")
    assert result == datetime(2025, 1, 15, 10, 30, 0)


def test_parse_timestamp_no_z_format():
    from datetime import datetime
    result = _parse_timestamp("2025-01-15T10:30:00")
    assert result == datetime(2025, 1, 15, 10, 30, 0)


def test_parse_timestamp_invalid():
    assert _parse_timestamp("not-a-date") is None
    assert _parse_timestamp("") is None


# --- extract_gate_details ---


def test_extract_gate_details_minimal_and_defaults():
    assert extract_gate_details({"status": "pass"}) == {"status": "pass"}
    assert extract_gate_details({})["status"] == "unknown"


def test_extract_gate_details_copies_timestamp():
    gate = extract_gate_details({"status": "pass", "timestamp": "2025-01-01"})
    assert gate["gate_timestamp"] == "2025-01-01"


def test_extract_gate_details_scalar_keys():
    proof = {
        "status": "pass",
        "files_checked": 12,
        "message": "all clear",
        "test_runner": "pytest",
    }
    gate = extract_gate_details(proof)
    assert gate["files_checked"] == 12
    assert gate["message"] == "all clear"
    assert gate["test_runner"] == "pytest"


def test_extract_gate_details_list_count_and_details():
    proof = {
        "status": "fail",
        "violations": ["a", "b", "c"],
        "failures": [],
    }
    gate = extract_gate_details(proof)
    assert gate["violations"] == 3
    assert gate["failures"] == 0
    assert gate["violations_details"] == ["a", "b", "c"]
    assert gate["failures_details"] == []


def test_extract_gate_details_list_count_non_list():
    """Non-list values for LIST_COUNT_KEYS are passed through."""
    proof = {"status": "pass", "violations": 7}
    gate = extract_gate_details(proof)
    assert gate["violations"] == 7
    assert "violations_details" not in gate


def test_extract_gate_details_dict_keys():
    proof = {
        "status": "pass",
        "summary": {"total": 5, "passed": 5},
        "categories": {"lint": "ok"},
    }
    gate = extract_gate_details(proof)
    assert gate["summary"] == {"total": 5, "passed": 5}
    assert gate["categories"] == {"lint": "ok"}


def test_extract_gate_details_ignores_unknown_keys():
    proof = {"status": "pass", "random_key": "ignored"}
    gate = extract_gate_details(proof)
    assert "random_key" not in gate


# --- compute_duration ---


def test_compute_duration_with_timestamps():
    gates = {
        "lint": {"gate_timestamp": "2025-01-01T10:00:00Z"},
        "tests": {"gate_timestamp": "2025-01-01T10:05:00Z"},
    }
    assert compute_duration(gates) == 300.0


def test_compute_duration_single_timestamp():
    gates = {"lint": {"gate_timestamp": "2025-01-01T10:00:00Z"}}
    assert compute_duration(gates) is None


def test_compute_duration_no_timestamps():
    gates = {"lint": {"status": "pass"}, "tests": {"status": "pass"}}
    assert compute_duration(gates) is None


def test_compute_duration_empty_gates():
    assert compute_duration({}) is None


def test_compute_duration_invalid_timestamps():
    gates = {
        "lint": {"gate_timestamp": "not-a-date"},
        "tests": {"gate_timestamp": "also-not"},
    }
    assert compute_duration(gates) is None


# --- count_run_number ---


def test_count_run_number_no_dir():
    assert count_run_number("", "abc") == 1
    assert count_run_number("/nonexistent/path", "abc") == 1


def test_count_run_number_empty_dir():
    with tempfile.TemporaryDirectory() as d:
        assert count_run_number(d, "abc") == 1


def test_count_run_number_with_existing_files():
    with tempfile.TemporaryDirectory() as d:
        # Summary file (sha-YYYYMMDDHHMMSS.json) — counts
        with open(os.path.join(d, "abc-20250101120000.json"), "w") as f:
            f.write("{}")
        # Per-gate file (sha-gatename-YYYYMMDDHHMMSS.json) — does NOT count
        with open(os.path.join(d, "abc-lint-20250102120000.json"), "w") as f:
            f.write("{}")
        # Only 1 summary file, so run_number = 2
        assert count_run_number(d, "abc") == 2


def test_count_run_number_ignores_other_shas():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "xyz-20250101120000.json"), "w") as f:
            f.write("{}")
        assert count_run_number(d, "abc") == 1



# build_payload contract tests are in test_build_payload_contract.py
# Per-gate duration tests are in test_per_gate_duration.py
