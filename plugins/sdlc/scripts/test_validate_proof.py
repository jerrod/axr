"""Tests for validate_proof module."""
import json
import os
import subprocess
import sys
import tempfile

import pytest

import validate_proof as vp
from validate_proof import validate_gate_proof, validate_metrics_event


SCHEMA_DIR = os.path.join(os.path.dirname(__file__), "schemas")


class TestProofFilesizeLint:
    def test_valid_filesize_proof(self):
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 10, "violations": []
        }
        assert validate_gate_proof(proof, "filesize", SCHEMA_DIR) is True

    def test_missing_required_field_raises(self):
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 10
        }
        with pytest.raises(Exception):
            validate_gate_proof(proof, "filesize", SCHEMA_DIR)

    def test_crash_proof_with_error(self):
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "fail",
            "timestamp": "2026-03-21T00:00:00Z",
            "error": "script crashed with exit code 1",
            "files_checked": 0, "violations": []
        }
        assert validate_gate_proof(proof, "filesize", SCHEMA_DIR) is True

    def test_valid_lint_proof(self):
        proof = {
            "gate": "lint", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "failures": []
        }
        assert validate_gate_proof(proof, "lint", SCHEMA_DIR) is True


class TestProofComplexityDeadCode:
    def test_valid_complexity_cyclomatic(self):
        proof = {
            "gate": "complexity", "sha": "abc123", "status": "fail",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 5,
            "violations": [{
                "file": "a.py", "function": "f",
                "complexity": 12, "max": 8,
                "type": "cyclomatic_complexity",
            }]
        }
        assert validate_gate_proof(proof, "complexity", SCHEMA_DIR) is True

    def test_valid_complexity_function_length(self):
        proof = {
            "gate": "complexity", "sha": "abc123", "status": "fail",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 5,
            "violations": [{
                "file": "a.py", "function": "f",
                "lines": 60, "max": 50,
                "type": "function_length",
            }]
        }
        assert validate_gate_proof(proof, "complexity", SCHEMA_DIR) is True

    def test_valid_dead_code_variants(self):
        proof = {
            "gate": "dead-code", "sha": "abc123", "status": "fail",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "violations": [
                {"type": "unused_import", "file": "a.py",
                 "name": "os", "line": 1},
                {"type": "commented_code", "details": "lines 10-15"},
                {"type": "rubocop_dead_code", "file": "b.rb",
                 "cop": "Lint/UselessAssignment", "line": 5,
                 "message": "unused var"},
            ]
        }
        assert validate_gate_proof(proof, "dead-code", SCHEMA_DIR) is True


class TestProofAdvancedGates:
    def test_valid_tests_proof(self):
        proof = {
            "gate": "tests", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "fingerprint": "abc", "test_runner": "pytest",
            "test_failures": [], "missing_tests": [],
            "failed_subprojects": []
        }
        assert validate_gate_proof(proof, "tests", SCHEMA_DIR) is True

    def test_valid_coverage_proof(self):
        proof = {
            "gate": "coverage", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "coverage_tool": "py", "below_threshold": []
        }
        assert validate_gate_proof(proof, "coverage", SCHEMA_DIR) is True

    def test_valid_test_quality_proof(self):
        proof = {
            "gate": "test-quality", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "scanned_files": 5, "violations": []
        }
        assert validate_gate_proof(proof, "test-quality", SCHEMA_DIR) is True

    def test_valid_qa_proof(self):
        proof = {
            "gate": "qa", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "message": "ok", "flows_tested": 0, "flows_passed": 0,
            "flows_failed": 0, "issues": [], "recordings": []
        }
        assert validate_gate_proof(proof, "qa", SCHEMA_DIR) is True

    def test_valid_design_audit_proof(self):
        proof = {
            "gate": "design-audit", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "message": "ok", "overall_grade": "A",
            "categories": {}, "screenshots": []
        }
        assert validate_gate_proof(proof, "design-audit", SCHEMA_DIR) is True

    def test_valid_performance_proof(self):
        proof = {
            "gate": "performance", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "summary": {
                "critical": 0, "high": 0,
                "medium": 0, "advisory": 0,
            },
            "findings": []
        }
        assert validate_gate_proof(proof, "performance", SCHEMA_DIR) is True


class TestMetricsEventValid:
    def test_valid_summary_event(self):
        event = {
            "schema_version": 1, "repo": "test", "branch": "main",
            "sha": "abc123", "user": "dev",
            "timestamp": "2026-03-21T00:00:00Z",
            "phase": "all", "run_number": 1, "gate_name": None,
            "critic_verdict": "unknown", "critic_findings_count": 0,
            "critic_findings_by_rule": {}, "critic_findings": [],
            "gates_first_pass": True, "gate_failures_after_critic": 0,
            "missed_gates": [], "gates_run": ["filesize"],
            "gates": {
                "filesize": {
                    "status": "pass",
                    "gate_timestamp": "2026-03-21T00:00:00Z",
                    "duration_ms": 0,
                },
            },
            "duration_seconds": None
        }
        assert validate_metrics_event(event, SCHEMA_DIR) is True

    def test_valid_per_gate_event(self):
        event = {
            "schema_version": 1, "repo": "test", "branch": "main",
            "sha": "abc123", "user": "dev",
            "timestamp": "2026-03-21T00:00:00Z",
            "phase": "all", "run_number": 1, "gate_name": "filesize",
            "critic_verdict": "unknown", "critic_findings_count": 0,
            "critic_findings_by_rule": {}, "critic_findings": [],
            "gates_first_pass": True, "gate_failures_after_critic": 0,
            "missed_gates": [], "gates_run": ["filesize"],
            "gates": {
                "filesize": {
                    "status": "pass",
                    "gate_timestamp": "2026-03-21T00:00:00Z",
                    "duration_ms": 0,
                },
            },
            "duration_seconds": None
        }
        assert validate_metrics_event(event, SCHEMA_DIR) is True


class TestMetricsEventInvalid:
    def test_missing_schema_version_raises(self):
        event = {
            "repo": "test", "branch": "main", "sha": "abc123",
            "user": "dev", "timestamp": "2026-03-21T00:00:00Z",
            "phase": "all", "run_number": 1, "gate_name": None,
            "critic_verdict": "unknown", "critic_findings_count": 0,
            "critic_findings_by_rule": {}, "critic_findings": [],
            "gates_first_pass": True, "gate_failures_after_critic": 0,
            "missed_gates": [], "gates_run": [],
            "gates": {}, "duration_seconds": None
        }
        with pytest.raises(Exception):
            validate_metrics_event(event, SCHEMA_DIR)

    def test_extra_field_raises(self):
        event = {
            "schema_version": 1, "repo": "test", "branch": "main",
            "sha": "abc123", "user": "dev",
            "timestamp": "2026-03-21T00:00:00Z",
            "phase": "all", "run_number": 1, "gate_name": None,
            "critic_verdict": "unknown", "critic_findings_count": 0,
            "critic_findings_by_rule": {}, "critic_findings": [],
            "gates_first_pass": True, "gate_failures_after_critic": 0,
            "missed_gates": [], "gates_run": [],
            "gates": {}, "duration_seconds": None,
            "bogus_field": "should fail"
        }
        with pytest.raises(Exception):
            validate_metrics_event(event, SCHEMA_DIR)


class TestCliEntryPoint:
    def test_valid_proof_via_cli(self):
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 10, "violations": [],
        }
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(proof, f)
            f.flush()
            result = subprocess.run(
                [sys.executable, "validate_proof.py",
                 f.name, "filesize", SCHEMA_DIR],
                capture_output=True, text=True,
                cwd=os.path.dirname(__file__),
            )
        os.unlink(f.name)
        assert result.returncode == 0
        assert "VALID" in result.stdout

    def test_invalid_proof_via_cli(self):
        proof = {"gate": "filesize", "sha": "abc123", "status": "pass"}
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(proof, f)
            f.flush()
            result = subprocess.run(
                [sys.executable, "validate_proof.py",
                 f.name, "filesize", SCHEMA_DIR],
                capture_output=True, text=True,
                cwd=os.path.dirname(__file__),
            )
        os.unlink(f.name)
        assert result.returncode == 1
        assert "INVALID" in result.stderr


class TestNoJsonschema:
    def test_gate_proof_returns_true_without_jsonschema(self, monkeypatch):
        monkeypatch.setattr(vp, "_HAS_JSONSCHEMA", False)
        assert validate_gate_proof({}, "filesize") is True

    def test_metrics_event_returns_true_without_jsonschema(self, monkeypatch):
        monkeypatch.setattr(vp, "_HAS_JSONSCHEMA", False)
        assert validate_metrics_event({}) is True


class TestDefaultSchemaDir:
    def test_gate_proof_uses_default_schema_dir(self):
        proof = {
            "gate": "filesize", "sha": "abc123", "status": "pass",
            "timestamp": "2026-03-21T00:00:00Z", "error": None,
            "files_checked": 0, "violations": [],
        }
        assert validate_gate_proof(proof, "filesize") is True

    def test_metrics_event_uses_default_schema_dir(self):
        event = {
            "schema_version": 1, "repo": "t", "branch": "m",
            "sha": "a", "user": "d", "timestamp": "2026-03-21T00:00:00Z",
            "phase": "all", "run_number": 1, "gate_name": None,
            "critic_verdict": "u", "critic_findings_count": 0,
            "critic_findings_by_rule": {}, "critic_findings": [],
            "gates_first_pass": True, "gate_failures_after_critic": 0,
            "missed_gates": [], "gates_run": [],
            "gates": {}, "duration_seconds": None,
        }
        assert validate_metrics_event(event) is True
