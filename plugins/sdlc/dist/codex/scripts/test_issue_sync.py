"""Tests for issue-sync.sh — guards, create, and update subcommands."""

import json
import os
import subprocess
import tempfile

from test_issue_sync_helpers import (
    ISSUE_SYNC,
    init_git_repo,
    make_mock_gh,
    make_plan,
    run_sync,
)


# ─── gh auth guard ──────────────────────────────────────────────


def test_create_exits_gracefully_when_gh_not_authed():
    """create exits 0 with warning when gh auth fails."""
    with tempfile.TemporaryDirectory() as tmpdir:
        mock_dir = make_mock_gh(tmpdir, "no_auth")
        plan = make_plan(tmpdir)
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "not authenticated" in result.stderr


def test_update_exits_gracefully_when_gh_not_authed():
    """update exits 0 with warning when gh auth fails."""
    with tempfile.TemporaryDirectory() as tmpdir:
        mock_dir = make_mock_gh(tmpdir, "no_auth")
        plan = make_plan(tmpdir)
        result = run_sync("update", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "not authenticated" in result.stderr


# ─── Config opt-out ─────────────────────────────────────────────


def test_create_skips_when_config_opts_out():
    """create exits 0 silently when github_issues is false."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        make_plan(tmpdir)
        config = os.path.join(tmpdir, "sdlc.config.json")
        with open(config, "w") as f:
            json.dump({"github_issues": False}, f)
        plan = os.path.join(tmpdir, "plan.md")
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert result.stdout.strip() == ""


# ─── create subcommand ──────────────────────────────────────────


def test_create_makes_issue_and_injects_header():
    """create calls gh issue create and injects Issue: header."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "42" in result.stdout
        with open(plan) as f:
            content = f.read()
        assert "Issue: test-org/test-repo#42" in content


def test_create_skips_when_issue_already_exists():
    """create returns existing ref when Issue: header present."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "Issue: org/repo#99\n"
            "\n# Test\n"
        )
        plan = make_plan(tmpdir, content)
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "org/repo#99" in result.stdout


def test_create_handles_failure_gracefully():
    """create warns but exits 0 when gh issue create fails."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "create_fail")
        plan = make_plan(tmpdir)
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "failed to create issue" in result.stderr


def test_create_injects_header_without_updated_line():
    """create appends Issue: field at EOF when no Updated: anchor exists."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "\n# Test Plan\n"
            "\n**Goal:** no Updated field\n"
            "\n- [ ] Step one\n"
        )
        plan = make_plan(tmpdir, content)
        result = run_sync("create", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        with open(plan) as f:
            updated = f.read()
        assert "Issue: test-org/test-repo#42" in updated


# ─── update subcommand ──────────────────────────────────────────


def test_update_skips_when_no_issue_ref():
    """update exits silently when plan has no Issue: field."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = run_sync("update", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert result.stdout.strip() == ""


def test_update_debounce_skips_recent_sync():
    """update skips when last sync was <30s ago — verified via api_fail mock."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        # api_fail: any `gh api` invocation errors out and prints a
        # sentinel to stderr. If debounce works, no api call is made and
        # the sentinel must NOT appear.
        mock_dir = make_mock_gh(tmpdir, "api_fail")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "Issue: test-org/test-repo#42\n"
            "\n# Test\n"
            "- [ ] Step one\n"
        )
        plan = make_plan(tmpdir, content)
        # Resolve tmpdir to its realpath — macOS tmp dirs are symlinks
        # under /var, while `git rev-parse --show-toplevel` returns the
        # canonical /private/var path, and that's where the debounce
        # marker will be read from.
        git_root = os.path.realpath(tmpdir)
        quality_dir = os.path.join(git_root, ".quality")
        os.makedirs(quality_dir, exist_ok=True)
        marker = os.path.join(quality_dir, ".issue-sync-last")
        with open(marker, "w") as f:
            f.write("")
        result = run_sync("update", [plan], mock_dir, cwd=tmpdir)
        assert result.returncode == 0
        assert "ERROR: api called" not in result.stderr


# ─── Helpers ────────────────────────────────────────────────────


def _source_and_call(func_call, tmpdir, mock_dir=None):
    """Source issue-sync.sh then call a function."""
    env = dict(os.environ)
    if mock_dir:
        env["PATH"] = mock_dir + ":" + env.get("PATH", "")
    return subprocess.run(
        ["bash", "-c", f'source "{ISSUE_SYNC}"; {func_call}'],
        capture_output=True, text=True, cwd=tmpdir, env=env,
    )


def test_build_issue_body_includes_checkboxes():
    """build_issue_body includes checkbox state from plan."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = _source_and_call(
            f'build_issue_body "{plan}"', tmpdir, mock_dir
        )
        assert "sdlc-issue-body" in result.stdout
        assert "Step one" in result.stdout


def test_extract_title_gets_first_heading():
    """extract_title returns the first markdown heading."""
    with tempfile.TemporaryDirectory() as tmpdir:
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = _source_and_call(
            f'extract_title "{plan}"', tmpdir, mock_dir
        )
        assert result.stdout.strip() == "Test Plan"
