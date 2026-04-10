"""CLI entry point for inspecting PR check failures."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import gh_client
import log_analysis

DEFAULT_MAX_LINES = 160
DEFAULT_CONTEXT = 30


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Inspect failing GitHub PR checks.",
    )
    parser.add_argument("--repo", default=".")
    parser.add_argument("--pr", default=None)
    parser.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES)
    parser.add_argument("--context", type=int, default=DEFAULT_CONTEXT)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def fetch_checks(
    pr_value: str, repo_root: Path,
) -> list[dict] | None:
    """Fetch PR checks with field fallback on error."""
    fields = ",".join(log_analysis.PRIMARY_CHECK_FIELDS)
    result = gh_client.run_gh(
        ["pr", "checks", pr_value, "--json", fields], cwd=repo_root,
    )
    if result.returncode == 0:
        return _parse_checks_json(result.stdout)
    message = "\n".join(filter(None, [result.stderr, result.stdout])).strip()
    fallback = log_analysis.select_fallback_fields(message)
    if not fallback:
        print(message or "Error: gh pr checks failed.", file=sys.stderr)
        return None
    retry = gh_client.run_gh(
        ["pr", "checks", pr_value, "--json", ",".join(fallback)],
        cwd=repo_root,
    )
    if retry.returncode != 0:
        err = (retry.stderr or retry.stdout or "").strip()
        print(err or "Error: gh pr checks failed.", file=sys.stderr)
        return None
    return _parse_checks_json(retry.stdout)


def _parse_checks_json(stdout: str) -> list[dict] | None:
    """Parse and validate checks JSON output."""
    try:
        data = json.loads(stdout or "[]")
    except json.JSONDecodeError:
        print("Error: unable to parse checks JSON.", file=sys.stderr)
        return None
    if not isinstance(data, list):
        print("Error: unexpected checks JSON shape.", file=sys.stderr)
        return None
    return data


def _build_check_base(check: dict) -> dict:
    """Extract check name, URL, run ID, and job ID."""
    url = check.get("detailsUrl") or check.get("link") or ""
    run_id = _extract_id(url, r"/actions/runs/(\d+)", r"/runs/(\d+)")
    job_id = _extract_id(url, r"/actions/runs/\d+/job/(\d+)", r"/job/(\d+)")
    return {
        "name": check.get("name", ""),
        "detailsUrl": url,
        "runId": run_id,
        "jobId": job_id,
    }


def _extract_id(url: str, *patterns: str) -> str | None:
    """Return first regex group match from URL, or None."""
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return None


def _fetch_log(
    run_id: str, job_id: str | None, repo_root: Path,
) -> tuple[str, str, str]:
    """Fetch log with job fallback. Returns (text, error, status)."""
    log_text, log_error = gh_client.fetch_run_log(run_id, repo_root)
    if not log_error:
        return log_text, "", "ok"
    if log_analysis.is_log_pending(log_error) and job_id:
        job_text, job_error = gh_client.fetch_job_log(job_id, repo_root)
        if job_text:
            return job_text, "", "ok"
        pending = job_error and log_analysis.is_log_pending(job_error)
        return "", job_error if pending else log_error, "pending"
    if log_analysis.is_log_pending(log_error):
        return "", log_error, "pending"
    return "", log_error, "error"


def analyze_check(
    check: dict, repo_root: Path, max_lines: int, context: int,
) -> dict:
    """Analyze a single failing check."""
    base = _build_check_base(check)
    if base["runId"] is None:
        base["status"] = "external"
        base["note"] = "No GitHub Actions run ID in URL."
        return base
    metadata = gh_client.fetch_run_metadata(base["runId"], repo_root)
    log_text, log_error, log_status = _fetch_log(
        base["runId"], base["jobId"], repo_root,
    )
    return _assemble_result(
        base, metadata, log_text, log_error, log_status, max_lines, context,
    )


def _assemble_result(
    base: dict, metadata: dict | None,
    log_text: str, log_error: str, log_status: str,
    max_lines: int, context: int,
) -> dict:
    """Build result dict from log fetch outcome."""
    if log_status == "pending":
        base["status"] = "log_pending"
        base["note"] = log_error or "Logs not available yet."
        if metadata:
            base["run"] = metadata
        return base
    if log_error:
        base["status"] = "log_unavailable"
        base["error"] = log_error
        if metadata:
            base["run"] = metadata
        return base
    snippet = log_analysis.extract_failure_snippet(
        log_text, max_lines=max_lines, context=context,
    )
    tier = log_analysis.classify_tier(snippet)
    base["status"] = "ok"
    base["run"] = metadata or {}
    base["logSnippet"] = snippet
    base["tier"] = tier
    base["tierContext"] = log_analysis.extract_tier_context(snippet, tier)
    return base


def render_text(pr_number: str, results: list[dict]) -> None:
    """Print human-readable output for failing checks."""
    print(f"PR #{pr_number}: {len(results)} failing check(s) analyzed.")
    for r in results:
        print("-" * 60)
        print(f"Check: {r.get('name', '')}")
        if r.get("detailsUrl"):
            print(f"URL: {r['detailsUrl']}")
        print(f"Status: {r.get('status', 'unknown')}")
        if r.get("note"):
            print(f"Note: {r['note']}")
        if r.get("error"):
            print(f"Error: {r['error']}")
        if r.get("logSnippet"):
            print(f"Tier: {r.get('tier', '')}")
            print("Snippet:")
            for line in r["logSnippet"].splitlines():
                print(f"  {line}")
    print("-" * 60)


def _setup(args: argparse.Namespace) -> tuple[Path, str] | None:
    """Validate environment. Returns (repo_root, pr_value) or None."""
    repo_root = gh_client.find_git_root(Path(args.repo))
    if repo_root is None:
        print("Error: not inside a Git repository.", file=sys.stderr)
        return None
    if not gh_client.ensure_gh_available(repo_root):
        print("Error: gh not available or not authenticated.", file=sys.stderr)
        return None
    pr_value = gh_client.resolve_pr(args.pr, repo_root)
    if pr_value is None:
        print("Error: unable to determine PR.", file=sys.stderr)
        return None
    return repo_root, pr_value


def main() -> int:
    """Entry point. Returns 0 if no failures, 1 otherwise."""
    args = parse_args()
    setup = _setup(args)
    if setup is None:
        return 1
    repo_root, pr_value = setup
    checks = fetch_checks(pr_value, repo_root)
    if checks is None:
        return 1
    failing = [c for c in checks if log_analysis.is_failing(c)]
    if not failing:
        print(f"PR #{pr_value}: no failing checks detected.")
        return 0
    results = [
        analyze_check(c, repo_root, max(1, args.max_lines), max(1, args.context))
        for c in failing
    ]
    if args.json:
        print(json.dumps({"pr": pr_value, "results": results}, indent=2))
    else:
        render_text(pr_value, results)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
