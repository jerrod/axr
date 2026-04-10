"""Tests for PayloadContext — dataclass construction from argv."""

from dataclasses import FrozenInstanceError

import pytest

from payload_context import PayloadContext


# Minimum argv the CLI ever passes — proof_dir, critic_verdict,
# critic_count, repo, branch, sha, user, timestamp.
MIN_ARGV = [
    "script.py", "/p", "approved", "0",
    "r", "main", "sha1", "dev", "2025-01-01T00:00:00Z",
]


def test_from_argv_minimum_fields():
    ctx = PayloadContext.from_argv(MIN_ARGV)
    expected = {
        "proof_dir": "/p",
        "critic_verdict_arg": "approved",
        "critic_count_arg": 0,
        "repo": "r",
        "branch": "main",
        "sha": "sha1",
        "user": "dev",
        "timestamp": "2025-01-01T00:00:00Z",
        # Optional fields take their defaults
        "phase": "all",
        "gate_name": "",
        "metrics_data_dir": "",
        "user_email": "",
    }
    for attr, value in expected.items():
        assert getattr(ctx, attr) == value, attr


def test_from_argv_all_fields():
    ctx = PayloadContext.from_argv(
        MIN_ARGV + ["build", "lint", "/data", "dev@example.com"]
    )
    assert ctx.phase == "build"
    assert ctx.gate_name == "lint"
    assert ctx.metrics_data_dir == "/data"
    assert ctx.user_email == "dev@example.com"


def test_from_argv_empty_critic_verdict_becomes_none():
    argv = list(MIN_ARGV)
    argv[2] = ""  # empty verdict → None
    ctx = PayloadContext.from_argv(argv)
    assert ctx.critic_verdict_arg is None


def test_from_argv_empty_critic_count_becomes_zero():
    argv = list(MIN_ARGV)
    argv[3] = ""  # empty count → 0
    ctx = PayloadContext.from_argv(argv)
    assert ctx.critic_count_arg == 0


def test_from_argv_partial_optional_fields():
    # Only phase supplied; gate_name, data_dir, email default
    ctx = PayloadContext.from_argv(MIN_ARGV + ["review"])
    assert ctx.phase == "review"
    assert ctx.gate_name == ""
    assert ctx.metrics_data_dir == ""
    assert ctx.user_email == ""


def test_context_is_frozen():
    ctx = PayloadContext.from_argv(MIN_ARGV)
    with pytest.raises(FrozenInstanceError):
        ctx.repo = "other"
