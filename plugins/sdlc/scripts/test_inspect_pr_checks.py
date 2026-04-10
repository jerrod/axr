"""Tests for inspect_pr_checks — mocks only subprocess.run."""
import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import inspect_pr_checks

REPO = Path("/fake/repo")

def make_cp(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)


class TestBuildCheckBase:
    def test_extracts_ids_from_actions_url(self):
        check = {
            "name": "CI",
            "detailsUrl": "https://github.com/o/r/actions/runs/123/job/456",
        }
        base = inspect_pr_checks._build_check_base(check)
        assert base["name"] == "CI"
        assert base["runId"] == "123"
        assert base["jobId"] == "456"
        assert base["detailsUrl"] == check["detailsUrl"]

    def test_extracts_run_id_from_runs_pattern(self):
        check = {"name": "X", "detailsUrl": "https://example.com/runs/789"}
        base = inspect_pr_checks._build_check_base(check)
        assert base["runId"] == "789"
        assert base["jobId"] is None

    def test_handles_missing_url(self):
        check = {"name": "External"}
        base = inspect_pr_checks._build_check_base(check)
        assert base["runId"] is None
        assert base["jobId"] is None

    def test_uses_link_fallback(self):
        check = {
            "name": "CI",
            "link": "https://github.com/o/r/actions/runs/111/job/222",
        }
        base = inspect_pr_checks._build_check_base(check)
        assert base["runId"] == "111"
        assert base["jobId"] == "222"

    def test_no_ids_in_url(self):
        base = inspect_pr_checks._build_check_base(
            {"name": "Ext", "detailsUrl": "https://external.com/check/abc"},
        )
        assert base["runId"] is None and base["jobId"] is None

    def test_job_id_from_short_pattern(self):
        base = inspect_pr_checks._build_check_base(
            {"name": "X", "detailsUrl": "https://example.com/job/999"},
        )
        assert base["jobId"] == "999"


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


class TestAnalyzeCheck:
    @patch("subprocess.run")
    def test_external_check(self, mock_run):
        check = {"name": "Codecov", "detailsUrl": "https://codecov.io/check"}
        result = inspect_pr_checks.analyze_check(check, REPO, 160, 30)
        assert result["status"] == "external"
        mock_run.assert_not_called()

    @patch("subprocess.run")
    def test_pending_log(self, mock_run):
        check = {
            "name": "CI",
            "detailsUrl": "https://github.com/o/r/actions/runs/100",
        }
        meta = {"conclusion": None, "status": "in_progress"}
        mock_run.side_effect = [
            make_cp(stdout=json.dumps(meta)),
            make_cp(returncode=1, stderr="Run still in progress"),
        ]
        result = inspect_pr_checks.analyze_check(check, REPO, 160, 30)
        assert result["status"] == "log_pending"

    @patch("subprocess.run")
    def test_ok_with_tier(self, mock_run):
        check = {
            "name": "CI",
            "detailsUrl": "https://github.com/o/r/actions/runs/100",
        }
        meta = {"conclusion": "failure", "status": "completed"}
        log_text = "running tests\nAssertionError: expected 1\ngot 2"
        mock_run.side_effect = [
            make_cp(stdout=json.dumps(meta)),
            make_cp(stdout=log_text),
        ]
        result = inspect_pr_checks.analyze_check(check, REPO, 160, 30)
        assert result["status"] == "ok"
        assert result["tier"] == "test"
        assert "tierContext" in result

    @patch("subprocess.run")
    def test_log_unavailable(self, mock_run):
        check = {
            "name": "CI",
            "detailsUrl": "https://github.com/o/r/actions/runs/100",
        }
        mock_run.side_effect = [
            make_cp(stdout=json.dumps({"conclusion": "failure"})),
            make_cp(returncode=1, stderr="permission denied"),
        ]
        result = inspect_pr_checks.analyze_check(check, REPO, 160, 30)
        assert result["status"] == "log_unavailable"
        assert "permission denied" in result["error"]


class TestRenderText:
    def test_renders_failing_checks(self, capsys):
        results = [{
            "name": "CI", "status": "ok",
            "detailsUrl": "https://github.com/o/r/actions/runs/1",
            "logSnippet": "ERROR: test failed", "tier": "test",
        }]
        inspect_pr_checks.render_text("42", results)
        output = capsys.readouterr().out
        assert "PR #42" in output
        assert "CI" in output
        assert "ERROR: test failed" in output
        assert "test" in output

    def test_renders_external_check(self, capsys):
        results = [{
            "name": "Codecov", "status": "external",
            "note": "No GitHub Actions run ID in URL.",
        }]
        inspect_pr_checks.render_text("10", results)
        output = capsys.readouterr().out
        assert "Codecov" in output
        assert "external" in output

    def test_renders_error_check(self, capsys):
        results = [{"name": "CI", "status": "log_unavailable", "error": "denied"}]
        inspect_pr_checks.render_text("5", results)
        output = capsys.readouterr().out
        assert "denied" in output


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


class TestMainOutput:
    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_failing_checks_json(self, mock_run, _mock_which, capsys):
        checks = [{"name": "CI", "conclusion": "failure",
                    "detailsUrl": "https://github.com/o/r/actions/runs/1"}]
        meta = {"conclusion": "failure", "status": "completed"}
        log = "ERROR: something broke"
        mock_run.side_effect = [
            make_cp(stdout="/fake/repo\n"),
            make_cp(returncode=0),
            make_cp(stdout=json.dumps({"number": 42})),
            make_cp(stdout=json.dumps(checks)),
            make_cp(stdout=json.dumps(meta)),
            make_cp(stdout=log),
        ]
        with patch("sys.argv", ["prog", "--json"]):
            code = inspect_pr_checks.main()
        assert code == 1
        output = json.loads(capsys.readouterr().out)
        assert output["pr"] == "42"
        assert len(output["results"]) == 1
        assert output["results"][0]["status"] == "ok"

    @patch("shutil.which", return_value="/usr/bin/gh")
    @patch("subprocess.run")
    def test_failing_checks_text(self, mock_run, _mock_which, capsys):
        checks = [{"name": "CI", "conclusion": "failure",
                    "detailsUrl": "https://github.com/o/r/actions/runs/1"}]
        meta = {"conclusion": "failure"}
        log = "FAIL: test_something"
        mock_run.side_effect = [
            make_cp(stdout="/fake/repo\n"),
            make_cp(returncode=0),
            make_cp(stdout=json.dumps({"number": 42})),
            make_cp(stdout=json.dumps(checks)),
            make_cp(stdout=json.dumps(meta)),
            make_cp(stdout=log),
        ]
        with patch("sys.argv", ["prog"]):
            code = inspect_pr_checks.main()
        assert code == 1
        output = capsys.readouterr().out
        assert "CI" in output
        assert "FAIL: test_something" in output
