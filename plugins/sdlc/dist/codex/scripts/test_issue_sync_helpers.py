"""Shared test helpers for issue-sync.sh tests."""

import os
import stat
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ISSUE_SYNC = os.path.join(SCRIPT_DIR, "issue-sync.sh")


_MOCK_GH_SUCCESS = """#!/usr/bin/env bash
case "$1" in
  auth)
    exit 0 ;;
  issue)
    if [ "$2" = "create" ]; then
      echo "https://github.com/test-org/test-repo/issues/42"
    fi ;;
  repo)
    echo 'test-org/test-repo' ;;
  api)
    # Emulate gh's --jq handling: if --jq is requested, return just
    # the integer id; otherwise echo the full JSON.
    if echo "$@" | grep -q -- '--jq'; then
      echo '12345'
    else
      echo '{"id": 12345}'
    fi ;;
  pr)
    if [ "$2" = "view" ]; then
      if echo "$@" | grep -q 'url'; then
        echo 'https://github.com/o/r/pull/99'
      elif echo "$@" | grep -q 'body'; then
        echo 'Summary'
      fi
    fi ;;
esac
exit 0
"""

_MOCK_GH_NO_AUTH = """#!/usr/bin/env bash
if [ "$1" = "auth" ]; then exit 1; fi
exit 0
"""

_MOCK_GH_CREATE_FAIL = """#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  issue) exit 1 ;;
esac
exit 0
"""

_MOCK_GH_API_FAIL = """#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api) echo "ERROR: api called" >&2; exit 1 ;;
esac
exit 0
"""

_MOCK_GH_LOGGING = """#!/usr/bin/env bash
# Logs all invocations to $GH_MOCK_LOG then behaves like success mock
echo "$*" >> "${GH_MOCK_LOG:-/dev/null}"
case "$1" in
  auth) exit 0 ;;
  issue)
    if [ "$2" = "create" ]; then
      echo 'https://github.com/test-org/test-repo/issues/42'
    fi ;;
  repo) echo 'test-org/test-repo' ;;
  api)
    if echo "$@" | grep -q -- '--jq'; then
      echo '12345'
    fi ;;
  pr)
    if [ "$2" = "view" ]; then
      if echo "$@" | grep -q url; then
        echo 'https://github.com/o/r/pull/99'
      elif echo "$@" | grep -q body; then
        echo 'Summary'
      fi
    fi ;;
esac
exit 0
"""

_MOCK_GH_SCRIPTS = {
    "success": _MOCK_GH_SUCCESS,
    "no_auth": _MOCK_GH_NO_AUTH,
    "create_fail": _MOCK_GH_CREATE_FAIL,
    "api_fail": _MOCK_GH_API_FAIL,
    "logging": _MOCK_GH_LOGGING,
}


def make_mock_gh(tmpdir, behavior="success"):
    """Create a mock gh script that simulates GitHub CLI."""
    mock_path = os.path.join(tmpdir, "gh")
    script = _MOCK_GH_SCRIPTS.get(
        behavior, "#!/usr/bin/env bash\nexit 0\n"
    )
    with open(mock_path, "w") as f:
        f.write(script)
    os.chmod(mock_path, stat.S_IRWXU)
    return tmpdir


def make_plan(tmpdir, content=None):
    """Create a plan file with standard headers."""
    if content is None:
        content = (
            "Branch: feat/test\n"
            "Created: 2026-04-09\n"
            "Updated: 2026-04-09\n"
            "\n"
            "# Test Plan\n"
            "\n"
            "**Goal:** Test the issue sync\n"
            "\n"
            "- [ ] Step one\n"
            "- [x] Step two\n"
            "- [ ] Step three\n"
        )
    plan_path = os.path.join(tmpdir, "plan.md")
    with open(plan_path, "w") as f:
        f.write(content)
    return plan_path


def init_git_repo(tmpdir):
    """Initialize a git repo in tmpdir so git commands work.

    Sets local user.email and user.name so `git commit` works on CI
    runners that have no global git identity configured.
    """
    subprocess.run(
        ["git", "init"], cwd=tmpdir, capture_output=True, check=True
    )
    subprocess.run(
        ["git", "config", "user.email", "test@example.com"],
        cwd=tmpdir, capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Test"],
        cwd=tmpdir, capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "checkout", "-b", "feat/test"],
        cwd=tmpdir, capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"],
        cwd=tmpdir, capture_output=True, check=True,
    )


def run_sync(subcommand, args, mock_dir, cwd=None, env_extra=None):
    """Run issue-sync.sh with mocked gh."""
    env = dict(os.environ)
    env["PATH"] = mock_dir + ":" + env.get("PATH", "")
    if env_extra:
        env.update(env_extra)
    if cwd is None:
        cwd = SCRIPT_DIR
    cmd = ["bash", ISSUE_SYNC, subcommand] + args
    return subprocess.run(
        cmd, capture_output=True, text=True, cwd=cwd, env=env
    )
