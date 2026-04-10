"""Tests for issue-sync.sh — link-pr and link-parent subcommands."""

import os
import tempfile

from test_issue_sync_helpers import (
    init_git_repo,
    make_mock_gh,
    make_plan,
    run_sync,
)


# ─── link-pr subcommand ─────────────────────────────────────────


def test_link_pr_skips_when_no_issue():
    """link-pr exits silently when plan has no Issue: field."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = run_sync("link-pr", [plan, "99"], mock_dir, cwd=tmpdir)
        assert result.returncode == 0


def test_link_pr_exits_zero_with_issue():
    """link-pr succeeds and invokes gh pr edit when plan has Issue: field."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "logging")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "Issue: test-org/test-repo#42\n"
            "\n# Test\n"
        )
        plan = make_plan(tmpdir, content)
        log_path = os.path.join(tmpdir, "gh.log")
        env_extra = {"GH_MOCK_LOG": log_path}
        result = run_sync(
            "link-pr", [plan, "99"], mock_dir, cwd=tmpdir, env_extra=env_extra
        )
        assert result.returncode == 0
        with open(log_path) as f:
            log = f.read()
        assert "pr edit 99" in log or "pr edit" in log


# ─── link-parent subcommand ─────────────────────────────────────


def test_link_parent_injects_header():
    """link-parent adds Parent-Issue: header to plan."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "Issue: test-org/test-repo#42\n"
            "\n# Test\n"
        )
        plan = make_plan(tmpdir, content)
        result = run_sync(
            "link-parent",
            [plan, "org/issues#15"],
            mock_dir,
            cwd=tmpdir,
        )
        assert result.returncode == 0
        with open(plan) as f:
            updated = f.read()
        assert "Parent-Issue: org/issues#15" in updated


def test_link_parent_skips_when_no_child_issue():
    """link-parent exits cleanly and does not inject header without Issue: ref.

    F8: header injection is gated on successful sub_issues API call, which
    requires a child issue. Without one, the plan must not be mutated.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        plan = make_plan(tmpdir)
        result = run_sync(
            "link-parent",
            [plan, "org/issues#15"],
            mock_dir,
            cwd=tmpdir,
        )
        assert result.returncode == 0
        with open(plan) as f:
            updated = f.read()
        assert "Parent-Issue:" not in updated


def test_link_parent_missing_args_exits_zero():
    """link-parent exits 0 when missing arguments."""
    with tempfile.TemporaryDirectory() as tmpdir:
        mock_dir = make_mock_gh(tmpdir, "success")
        result = run_sync(
            "link-parent", [], mock_dir, cwd=tmpdir
        )
        assert result.returncode == 0


def test_link_parent_idempotent_when_header_exists():
    """link-parent does not duplicate Parent-Issue header on retry."""
    with tempfile.TemporaryDirectory() as tmpdir:
        init_git_repo(tmpdir)
        mock_dir = make_mock_gh(tmpdir, "success")
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "Issue: test-org/test-repo#42\n"
            "Parent-Issue: org/issues#15\n"
            "\n# Test\n"
        )
        plan = make_plan(tmpdir, content)
        result = run_sync(
            "link-parent",
            [plan, "org/issues#15"],
            mock_dir,
            cwd=tmpdir,
        )
        assert result.returncode == 0
        with open(plan) as f:
            updated = f.read()
        # Header should appear exactly once
        assert updated.count("Parent-Issue:") == 1
