"""Tests for gh_client module."""

import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import gh_client


REPO_ROOT = Path("/fake/repo")


class TestRunGh:
    @patch("subprocess.run")
    def test_passes_args_to_subprocess(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["gh", "pr", "list"], returncode=0, stdout="ok", stderr=""
        )
        result = gh_client.run_gh(["pr", "list"], cwd=REPO_ROOT)
        mock_run.assert_called_once_with(
            ["gh", "pr", "list"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0
        assert result.stdout == "ok"

    @patch("subprocess.run")
    def test_returns_completed_process(self, mock_run):
        cp = subprocess.CompletedProcess(
            args=["gh", "version"], returncode=0, stdout="2.0", stderr=""
        )
        mock_run.return_value = cp
        result = gh_client.run_gh(["version"], cwd=REPO_ROOT)
        assert result is cp


class TestRunGhRaw:
    @patch("subprocess.run")
    def test_no_text_mode(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["gh", "api", "/endpoint"],
            returncode=0,
            stdout=b"binary",
            stderr=b"",
        )
        result = gh_client.run_gh_raw(["api", "/endpoint"], cwd=REPO_ROOT)
        mock_run.assert_called_once_with(
            ["gh", "api", "/endpoint"],
            cwd=REPO_ROOT,
            capture_output=True,
        )
        assert result.stdout == b"binary"


class TestFindGitRoot:
    @patch("subprocess.run")
    def test_returns_path_on_success(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="/home/user/repo\n", stderr=""
        )
        result = gh_client.find_git_root(Path("/home/user/repo/sub"))
        assert result == Path("/home/user/repo")

    @patch("subprocess.run")
    def test_returns_none_on_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=128, stdout="", stderr="not a git repo"
        )
        result = gh_client.find_git_root(Path("/tmp/nope"))
        assert result is None


class TestEnsureGhAvailable:
    @patch("shutil.which", return_value=None)
    def test_false_when_gh_missing(self, mock_which):
        assert gh_client.ensure_gh_available(REPO_ROOT) is False

    @patch("subprocess.run")
    @patch("shutil.which", return_value="/usr/bin/gh")
    def test_false_when_not_authenticated(self, mock_which, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="not logged in"
        )
        assert gh_client.ensure_gh_available(REPO_ROOT) is False

    @patch("subprocess.run")
    @patch("shutil.which", return_value="/usr/bin/gh")
    def test_true_when_authenticated(self, mock_which, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="Logged in", stderr=""
        )
        assert gh_client.ensure_gh_available(REPO_ROOT) is True


class TestResolvePr:
    def test_returns_provided_value(self):
        assert gh_client.resolve_pr("42", REPO_ROOT) == "42"

    @patch("subprocess.run")
    def test_auto_detects_from_branch(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"number": 99}),
            stderr="",
        )
        assert gh_client.resolve_pr(None, REPO_ROOT) == "99"

    @patch("subprocess.run")
    def test_none_on_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="no PR"
        )
        assert gh_client.resolve_pr(None, REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_on_bad_json(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="not json", stderr=""
        )
        assert gh_client.resolve_pr(None, REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_when_number_missing(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({}), stderr=""
        )
        assert gh_client.resolve_pr(None, REPO_ROOT) is None


class TestFetchRunMetadata:
    @patch("subprocess.run")
    def test_returns_dict(self, mock_run):
        data = {"conclusion": "success", "status": "completed"}
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(data), stderr=""
        )
        result = gh_client.fetch_run_metadata("123", REPO_ROOT)
        assert result == data

    @patch("subprocess.run")
    def test_none_on_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="not found"
        )
        assert gh_client.fetch_run_metadata("123", REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_on_bad_json(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="broken", stderr=""
        )
        assert gh_client.fetch_run_metadata("123", REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_when_payload_not_dict(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps([1, 2, 3]), stderr=""
        )
        assert gh_client.fetch_run_metadata("123", REPO_ROOT) is None


class TestFetchRunLog:
    @patch("subprocess.run")
    def test_returns_text_on_success(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="log output here", stderr=""
        )
        text, error = gh_client.fetch_run_log("456", REPO_ROOT)
        assert text == "log output here"
        assert error == ""

    @patch("subprocess.run")
    def test_returns_error_on_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="run not found"
        )
        text, error = gh_client.fetch_run_log("456", REPO_ROOT)
        assert text == ""
        assert "run not found" in error


def _job_log_side_effect(api_returncode=0, api_stdout=b"", api_stderr=b""):
    def side_effect(args, **kwargs):
        if "repo" in args and "view" in args:
            return subprocess.CompletedProcess(
                args=args,
                returncode=0,
                stdout=json.dumps({"nameWithOwner": "org/repo"}),
                stderr="",
            )
        return subprocess.CompletedProcess(
            args=args,
            returncode=api_returncode,
            stdout=api_stdout,
            stderr=api_stderr,
        )

    return side_effect


class TestFetchJobLog:
    @patch("subprocess.run")
    def test_returns_decoded_text(self, mock_run):
        mock_run.side_effect = _job_log_side_effect(api_stdout=b"job log content")
        text, error = gh_client.fetch_job_log("789", REPO_ROOT)
        assert text == "job log content"
        assert error == ""

    @patch("subprocess.run")
    def test_error_on_zip_payload(self, mock_run):
        mock_run.side_effect = _job_log_side_effect(api_stdout=b"PK\x03\x04zipdata")
        text, error = gh_client.fetch_job_log("789", REPO_ROOT)
        assert text == ""
        assert "zip" in error.lower()

    @patch("subprocess.run")
    def test_error_when_no_slug(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="no repo"
        )
        text, error = gh_client.fetch_job_log("789", REPO_ROOT)
        assert text == ""
        assert error != ""

    @patch("subprocess.run")
    def test_error_decodes_stderr_bytes(self, mock_run):
        mock_run.side_effect = _job_log_side_effect(
            api_returncode=1, api_stderr=b"HTTP 403: rate limit exceeded"
        )
        text, error = gh_client.fetch_job_log("789", REPO_ROOT)
        assert text == ""
        assert "rate limit" in error

    @patch("subprocess.run")
    def test_error_fallback_message_when_empty_stderr(self, mock_run):
        mock_run.side_effect = _job_log_side_effect(api_returncode=1)
        text, error = gh_client.fetch_job_log("789", REPO_ROOT)
        assert text == ""
        assert "gh api job logs failed" in error


class TestFetchRepoSlug:
    @patch("subprocess.run")
    def test_returns_name_with_owner(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"nameWithOwner": "org/repo"}),
            stderr="",
        )
        assert gh_client.fetch_repo_slug(REPO_ROOT) == "org/repo"

    @patch("subprocess.run")
    def test_none_on_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="error"
        )
        assert gh_client.fetch_repo_slug(REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_on_bad_json(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="not json at all", stderr=""
        )
        assert gh_client.fetch_repo_slug(REPO_ROOT) is None

    @patch("subprocess.run")
    def test_none_when_name_with_owner_missing(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({}), stderr=""
        )
        assert gh_client.fetch_repo_slug(REPO_ROOT) is None
