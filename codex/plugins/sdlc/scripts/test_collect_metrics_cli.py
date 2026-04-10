"""CLI entry-point tests for collect_metrics_payload.py."""

import json
import os
import subprocess
import sys
import tempfile

from conftest import _make_proof_dir


SCRIPT = os.path.join(os.path.dirname(__file__), "collect_metrics_payload.py")


def _run_cli(proof_dir, *, verdict="", phase="build", gate="", data_dir="",
             sha="abc", repo="repo"):
    """Run the payload CLI and return parsed JSON."""
    args = [sys.executable, SCRIPT, proof_dir, verdict, "0",
            repo, "main", sha, "dev", "2025-01-01T00:00:00Z", phase]
    if gate:
        args.append(gate)
    elif data_dir:
        args.extend(["", data_dir])
    if gate and data_dir:
        args.append(data_dir)
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_cli_produces_valid_json():
    d = _make_proof_dir({"lint": {"status": "pass", "files_checked": 2}})
    payload = _run_cli(d, verdict="approved")
    assert payload["repo"] == "repo"
    assert payload["phase"] == "build"
    assert "lint" in payload["gates"]


def test_cli_per_gate_mode():
    d = _make_proof_dir({
        "lint": {"status": "pass", "files_checked": 2},
        "tests": {"status": "fail"},
    })
    payload = _run_cli(d, gate="lint")
    assert payload["gate_name"] == "lint"
    assert payload["gates_run"] == ["lint"]
    assert "tests" not in payload["gates"]


def test_cli_defaults_phase_and_gate():
    d = _make_proof_dir({"lint": {"status": "pass"}})
    payload = _run_cli(d, phase="all")
    assert payload["phase"] == "all"
    assert payload["gate_name"] is None


def test_cli_run_number_increments_with_data_dir():
    """Prove run_number increments via CLI, ignoring per-gate files."""
    d = _make_proof_dir({"lint": {"status": "pass"}})
    with tempfile.TemporaryDirectory() as data_dir:
        assert _run_cli(d, data_dir=data_dir)["run_number"] == 1

        # Summary file — counts
        with open(os.path.join(data_dir, "abc-20250101120000.json"), "w") as f:
            f.write("{}")
        assert _run_cli(d, data_dir=data_dir)["run_number"] == 2

        # Per-gate file — does NOT count
        with open(os.path.join(data_dir, "abc-lint-20250101120001.json"), "w") as f:
            f.write("{}")
        assert _run_cli(d, data_dir=data_dir)["run_number"] == 2

        # Another summary file — counts
        with open(os.path.join(data_dir, "abc-20250101120002.json"), "w") as f:
            f.write("{}")
        assert _run_cli(d, data_dir=data_dir)["run_number"] == 3
