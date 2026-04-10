"""Tests for per-gate duration computation in collect_metrics_payload.py."""

from collect_metrics_payload import compute_per_gate_duration


def test_per_gate_duration_three_gates():
    gates = {
        "lint": {"gate_timestamp": "2025-01-01T10:00:00Z"},
        "tests": {"gate_timestamp": "2025-01-01T10:00:10Z"},
        "coverage": {"gate_timestamp": "2025-01-01T10:00:25Z"},
    }
    compute_per_gate_duration(gates)
    assert gates["lint"]["duration_ms"] == 0
    assert gates["tests"]["duration_ms"] == 10000
    assert gates["coverage"]["duration_ms"] == 15000


def test_per_gate_duration_single_gate():
    gates = {"lint": {"gate_timestamp": "2025-01-01T10:00:00Z"}}
    compute_per_gate_duration(gates)
    assert gates["lint"]["duration_ms"] == 0


def test_per_gate_duration_no_timestamps():
    gates = {"lint": {"status": "pass"}, "tests": {"status": "pass"}}
    compute_per_gate_duration(gates)
    assert "duration_ms" not in gates["lint"]
    assert "duration_ms" not in gates["tests"]


def test_per_gate_duration_mixed_timestamps():
    gates = {
        "lint": {"gate_timestamp": "2025-01-01T10:00:00Z"},
        "tests": {"status": "pass"},
        "coverage": {"gate_timestamp": "2025-01-01T10:00:30Z"},
    }
    compute_per_gate_duration(gates)
    assert gates["lint"]["duration_ms"] == 0
    assert gates["coverage"]["duration_ms"] == 30000
    assert "duration_ms" not in gates["tests"]


def test_per_gate_duration_skips_stale_proofs():
    """Gates with timestamps >10 min before newest are stale and excluded."""
    gates = {
        "performance": {"gate_timestamp": "2025-01-01T08:00:00Z"},  # 2h stale
        "lint": {"gate_timestamp": "2025-01-01T10:00:00Z"},
        "tests": {"gate_timestamp": "2025-01-01T10:00:10Z"},
    }
    compute_per_gate_duration(gates)
    assert "duration_ms" not in gates["performance"]
    assert gates["lint"]["duration_ms"] == 0
    assert gates["tests"]["duration_ms"] == 10000
