"""GitHub CLI wrapper for CI inspection scripts."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Any, Sequence


RUN_METADATA_FIELDS = [
    "conclusion",
    "status",
    "workflowName",
    "name",
    "event",
    "headBranch",
    "headSha",
    "url",
]


def run_gh(args: Sequence[str], cwd: Path) -> subprocess.CompletedProcess:
    """Run a gh CLI command with text mode enabled."""
    return subprocess.run(
        ["gh", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
    )


def run_gh_raw(args: Sequence[str], cwd: Path) -> subprocess.CompletedProcess:
    """Run a gh CLI command returning raw bytes."""
    return subprocess.run(
        ["gh", *args],
        cwd=cwd,
        capture_output=True,
    )


def find_git_root(start: Path) -> Path | None:
    """Find the git repository root from a starting path."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=start,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip())


def ensure_gh_available(repo_root: Path) -> bool:
    """Check that gh is installed and authenticated."""
    if shutil.which("gh") is None:
        return False
    result = run_gh(["auth", "status"], cwd=repo_root)
    return result.returncode == 0


def resolve_pr(pr_value: str | None, repo_root: Path) -> str | None:
    """Return the provided PR number or auto-detect from current branch."""
    if pr_value:
        return pr_value
    result = run_gh(["pr", "view", "--json", "number"], cwd=repo_root)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None
    number = data.get("number")
    if not number:
        return None
    return str(number)


def fetch_run_metadata(run_id: str, repo_root: Path) -> dict[str, Any] | None:
    """Fetch metadata for a GitHub Actions run."""
    fields = ",".join(RUN_METADATA_FIELDS)
    result = run_gh(["run", "view", run_id, "--json", fields], cwd=repo_root)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return data


def fetch_run_log(run_id: str, repo_root: Path) -> tuple[str, str]:
    """Fetch the full log for a GitHub Actions run."""
    result = run_gh(["run", "view", run_id, "--log"], cwd=repo_root)
    if result.returncode != 0:
        error = (result.stderr or result.stdout or "").strip()
        return "", error or "gh run view failed"
    return result.stdout, ""


def fetch_job_log(job_id: str, repo_root: Path) -> tuple[str, str]:
    """Fetch the log for a specific job via the GitHub API."""
    repo_slug = fetch_repo_slug(repo_root)
    if not repo_slug:
        return "", "Unable to resolve repository name for job logs."
    endpoint = f"/repos/{repo_slug}/actions/jobs/{job_id}/logs"
    result = run_gh_raw(["api", endpoint], cwd=repo_root)
    if result.returncode != 0:
        stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        message = (stderr or "").strip()
        return "", message or "gh api job logs failed"
    if result.stdout.startswith(b"PK"):
        return "", "Job logs returned a zip archive; unable to parse."
    return result.stdout.decode(errors="replace"), ""


def fetch_repo_slug(repo_root: Path) -> str | None:
    """Fetch the owner/name slug for the repository."""
    result = run_gh(["repo", "view", "--json", "nameWithOwner"], cwd=repo_root)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None
    name_with_owner = data.get("nameWithOwner")
    if not name_with_owner:
        return None
    return str(name_with_owner)
