"""Tests for build_payload schema contract — always-present fields."""
import json
import os
import tempfile

from collect_metrics_payload import build_payload
from payload_context import PayloadContext


def _ctx(proof_dir, *, gate_name="", user_email=""):
    """PayloadContext with test-friendly defaults."""
    return PayloadContext(
        proof_dir=proof_dir,
        critic_verdict_arg="unknown",
        critic_count_arg=0,
        repo="test-repo",
        branch="main",
        sha="abc123",
        user="dev",
        user_email=user_email,
        timestamp="2026-03-21T00:00:00Z",
        phase="all",
        gate_name=gate_name,
        metrics_data_dir="",
    )


def test_payload_has_schema_version():
    """Every payload must include schema_version."""
    with tempfile.TemporaryDirectory() as d:
        payload = build_payload(_ctx(d))
        assert "schema_version" in payload
        assert payload["schema_version"] == 2


def test_payload_includes_user_email():
    """Payload must include user_email field."""
    with tempfile.TemporaryDirectory() as d:
        payload = build_payload(_ctx(d, user_email="test@example.com"))
        assert payload["user_email"] == "test@example.com"


def test_payload_user_email_null_when_empty():
    """user_email should be None when not configured."""
    with tempfile.TemporaryDirectory() as d:
        payload = build_payload(_ctx(d, user_email=""))
        assert payload["user_email"] is None


def test_payload_always_has_gate_name_null_for_summary():
    """gate_name must be present as None for summary events."""
    with tempfile.TemporaryDirectory() as d:
        payload = build_payload(_ctx(d, gate_name=""))
        assert "gate_name" in payload
        assert payload["gate_name"] is None


def test_payload_always_has_gate_name_string_for_per_gate():
    """gate_name must be present as a string for per-gate events."""
    with tempfile.TemporaryDirectory() as d:
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 0, "violations": [],
        }
        with open(os.path.join(d, "filesize.json"), "w") as f:
            json.dump(proof, f)
        payload = build_payload(_ctx(d, gate_name="filesize"))
        assert payload["gate_name"] == "filesize"


def test_payload_always_has_duration_seconds():
    """duration_seconds must always be present (None when not computable)."""
    with tempfile.TemporaryDirectory() as d:
        payload = build_payload(_ctx(d))
        assert "duration_seconds" in payload
