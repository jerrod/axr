"""Tests for inspect_pr_checks — mocks only subprocess.run."""
import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

import inspect_pr_checks

REPO = Path("/fake/repo")
_build = inspect_pr_checks._build_check_base


def make_cp(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)


class TestBuildCheckBase:
    @pytest.mark.parametrize("key,url,run_id,job_id", [
        ("detailsUrl", "https://github.com/o/r/actions/runs/123/job/456", "123", "456"),
        ("detailsUrl", "https://example.com/runs/789", "789", None),
        ("detailsUrl", "https://example.com/job/999", None, "999"),
        ("detailsUrl", "https://external.com/check/abc", None, None),
        ("link", "https://github.com/o/r/actions/runs/111/job/222", "111", "222"),
    ])
    def test_id_extraction(self, key, url, run_id, job_id):
        base = _build({"name": "CI", key: url})
        assert base["runId"] == run_id
        assert base["jobId"] == job_id
        assert base["detailsUrl"] == url
        assert base["name"] == "CI"

    def test_missing_url(self):
        base = _build({"name": "X"})
        assert base["runId"] is None and base["jobId"] is None


class TestParseChecksJson:
    def test_invalid_json(self, capsys):
        assert inspect_pr_checks._parse_checks_json("not json{") is None
        assert "parse" in capsys.readouterr().err

    def test_non_list_shape(self, capsys):
        assert inspect_pr_checks._parse_checks_json('{"x": 1}') is None
        assert "shape" in capsys.readouterr().err

    def test_empty_stdout_returns_empty_list(self):
        assert inspect_pr_checks._parse_checks_json("") == []


class TestFetchChecks:
    @patch("subprocess.run")
    def test_primary_fields_success(self, mock_run):
        checks = [{"name": "CI", "conclusion": "failure"}]
        mock_run.return_value = make_cp(stdout=json.dumps(checks))
        result = inspect_pr_checks.fetch_checks("42", REPO)
        assert result == checks

    @patch("subprocess.run")
    def test_fallback_on_field_error(self, mock_run):
        error_msg = (
            "Unknown field\nAvailable fields:\n"
            "  name\n  state\n  bucket\n  link\n"
            "  startedAt\n  completedAt\n  workflow\n"
        )
        fallback_data = [{"name": "CI", "state": "failure"}]
        mock_run.side_effect = [
            make_cp(returncode=1, stderr=error_msg),
            make_cp(stdout=json.dumps(fallback_data)),
        ]
        result = inspect_pr_checks.fetch_checks("42", REPO)
        assert result == fallback_data

    @patch("subprocess.run")
    def test_total_failure(self, mock_run):
        mock_run.return_value = make_cp(returncode=1, stderr="bad error")
        result = inspect_pr_checks.fetch_checks("42", REPO)
        assert result is None

    @patch("subprocess.run")
    def test_retry_also_fails(self, mock_run, capsys):
        error_msg = (
            "Unknown field\nAvailable fields:\n"
            "  name\n  state\n  bucket\n  link\n"
        )
        mock_run.side_effect = [
            make_cp(returncode=1, stderr=error_msg),
            make_cp(returncode=2, stderr="retry denied"),
        ]
        assert inspect_pr_checks.fetch_checks("42", REPO) is None
        assert "retry denied" in capsys.readouterr().err


class TestAssembleResult:
    def test_pending_status(self):
        base = {"name": "CI", "runId": "1"}
        result = inspect_pr_checks._assemble_result(
            base, {"status": "in_progress"},
            "", "still in progress", "pending", 160, 30,
        )
        assert result["status"] == "log_pending"
        assert result["run"] == {"status": "in_progress"}

    def test_ok_with_snippet_and_tier(self):
        base = {"name": "CI", "runId": "1"}
        log = "line1\nAssertionError: expected 5 got 3\nline3"
        result = inspect_pr_checks._assemble_result(
            base, {"conclusion": "failure"}, log, "", "ok", 160, 30,
        )
        assert result["status"] == "ok"
        assert "AssertionError" in result["logSnippet"]
        assert result["tier"] == "test"
        assert "tierContext" in result

    def test_error_status(self):
        base = {"name": "CI", "runId": "1"}
        result = inspect_pr_checks._assemble_result(
            base, None, "", "log fetch failed", "error", 160, 30,
        )
        assert result["status"] == "log_unavailable"
        assert result["error"] == "log fetch failed"

    def test_no_metadata_omits_run_key(self):
        error_result = inspect_pr_checks._assemble_result(
            {"name": "CI", "runId": "1"}, None, "", "denied", "error", 160, 30,
        )
        pending_result = inspect_pr_checks._assemble_result(
            {"name": "CI", "runId": "2"}, None, "", "pending", "pending", 160, 30,
        )
        assert "run" not in error_result
        assert "run" not in pending_result
        assert pending_result["status"] == "log_pending"


CI_CHECK = {"name": "CI", "detailsUrl": "https://github.com/o/r/actions/runs/100"}


class TestAnalyzeCheck:
    @patch("subprocess.run")
    def test_external_check(self, mock_run):
        check = {"name": "Codecov", "detailsUrl": "https://codecov.io/check"}
        result = inspect_pr_checks.analyze_check(check, REPO, 160, 30)
        assert result["status"] == "external"
        mock_run.assert_not_called()

    @patch("subprocess.run")
    def test_pending_log(self, mock_run):
        mock_run.side_effect = [
            make_cp(stdout=json.dumps({"status": "in_progress"})),
            make_cp(returncode=1, stderr="Run still in progress"),
        ]
        result = inspect_pr_checks.analyze_check(CI_CHECK, REPO, 160, 30)
        assert result["status"] == "log_pending"

    @patch("subprocess.run")
    def test_ok_with_tier(self, mock_run):
        mock_run.side_effect = [
            make_cp(stdout=json.dumps({"conclusion": "failure"})),
            make_cp(stdout="running\nAssertionError: expected 1\ngot 2"),
        ]
        result = inspect_pr_checks.analyze_check(CI_CHECK, REPO, 160, 30)
        assert result["status"] == "ok"
        assert result["tier"] == "test"
        assert "tierContext" in result

    @patch("subprocess.run")
    def test_log_unavailable(self, mock_run):
        mock_run.side_effect = [
            make_cp(stdout=json.dumps({"conclusion": "failure"})),
            make_cp(returncode=1, stderr="permission denied"),
        ]
        result = inspect_pr_checks.analyze_check(CI_CHECK, REPO, 160, 30)
        assert result["status"] == "log_unavailable"
        assert "permission denied" in result["error"]


class TestRenderText:
    def test_renders_failing_checks(self, capsys):
        inspect_pr_checks.render_text("42", [{
            "name": "CI", "status": "ok",
            "detailsUrl": "https://github.com/o/r/actions/runs/1",
            "logSnippet": "ERROR: test failed", "tier": "test",
        }])
        out = capsys.readouterr().out
        assert "PR #42" in out and "CI" in out
        assert "ERROR: test failed" in out and "test" in out

    def test_renders_external_check(self, capsys):
        inspect_pr_checks.render_text("10", [{
            "name": "Codecov", "status": "external", "note": "No run ID.",
        }])
        out = capsys.readouterr().out
        assert "Codecov" in out and "external" in out

    def test_renders_error_check(self, capsys):
        inspect_pr_checks.render_text(
            "5", [{"name": "CI", "status": "log_unavailable", "error": "denied"}],
        )
        assert "denied" in capsys.readouterr().out


class TestMainSetup:
    @patch("subprocess.run")
    def test_no_git_root_returns_1(self, mock_run):
        mock_run.return_value = make_cp(returncode=128, stderr="not a git repo")
        with patch("sys.argv", ["prog", "--repo", "/tmp/nope"]):
            assert inspect_pr_checks.main() == 1

    @patch("shutil.which", return_value=None)
    @patch("subprocess.run")
    def test_no_gh_returns_1(self, mock_run, _mock_which):
        mock_run.return_value = make_cp(stdout="/fake/repo\n")
        with patch("sys.argv", ["prog", "--repo", "."]):
            assert inspect_pr_checks.main() == 1

    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_no_pr_returns_1(self, mock_run, _mock_which):
        mock_run.side_effect = [
            make_cp(stdout="/fake/repo\n"),
            make_cp(returncode=0),
            make_cp(returncode=1, stderr="no PR"),
        ]
        with patch("sys.argv", ["prog"]):
            assert inspect_pr_checks.main() == 1

    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_checks_fetch_none_returns_1(self, mock_run, _mock_which):
        mock_run.side_effect = [
            make_cp(stdout="/fake/repo\n"),
            make_cp(returncode=0),
            make_cp(stdout=json.dumps({"number": 42})),
            make_cp(returncode=1, stderr="api error"),
        ]
        with patch("sys.argv", ["prog"]):
            assert inspect_pr_checks.main() == 1

    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_no_failing_returns_0(self, mock_run, _mock_which):
        checks = [{"name": "CI", "conclusion": "success"}]
        mock_run.side_effect = [
            make_cp(stdout="/fake/repo\n"),
            make_cp(returncode=0),
            make_cp(stdout=json.dumps({"number": 42})),
            make_cp(stdout=json.dumps(checks)),
        ]
        with patch("sys.argv", ["prog"]):
            assert inspect_pr_checks.main() == 0


def _failing_main_effects(log):
    checks = [{"name": "CI", "conclusion": "failure",
               "detailsUrl": "https://github.com/o/r/actions/runs/1"}]
    return [
        make_cp(stdout="/fake/repo\n"),
        make_cp(returncode=0),
        make_cp(stdout=json.dumps({"number": 42})),
        make_cp(stdout=json.dumps(checks)),
        make_cp(stdout=json.dumps({"conclusion": "failure"})),
        make_cp(stdout=log),
    ]


class TestMainOutput:
    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_failing_checks_json(self, mock_run, _mock_which, capsys):
        mock_run.side_effect = _failing_main_effects("ERROR: something broke")
        with patch("sys.argv", ["prog", "--json"]):
            assert inspect_pr_checks.main() == 1
        output = json.loads(capsys.readouterr().out)
        assert output["pr"] == "42"
        assert len(output["results"]) == 1
        assert output["results"][0]["status"] == "ok"

    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_failing_checks_text(self, mock_run, _mock_which, capsys):
        mock_run.side_effect = _failing_main_effects("FAIL: test_something")
        with patch("sys.argv", ["prog"]):
            assert inspect_pr_checks.main() == 1
        out = capsys.readouterr().out
        assert "CI" in out and "FAIL: test_something" in out
