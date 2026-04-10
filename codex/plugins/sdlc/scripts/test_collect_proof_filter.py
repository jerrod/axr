"""Tests for collect-proof.sh branch checkpoint filtering."""

import json
import os
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COLLECT_PROOF = os.path.join(SCRIPT_DIR, "collect-proof.sh")


def _setup_git_repo(tmp_path):
    """Create a minimal git repo with origin/main ref."""
    env = {**os.environ, "HOME": str(tmp_path)}
    run = lambda cmd: subprocess.run(
        cmd, cwd=str(tmp_path), env=env, capture_output=True, check=True
    )
    run(["git", "init", "-q"])
    run(["git", "config", "commit.gpgsign", "false"])
    run(["git", "config", "user.email", "test@test.com"])
    run(["git", "config", "user.name", "Test"])
    run(
        [
            "git",
            "remote",
            "add",
            "origin",
            "https://github.com/test-owner/test-repo.git",
        ]
    )
    run(["git", "commit", "--allow-empty", "-q", "-m", "init"])
    run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"])
    return env


def _make_checkpoint(directory, name, sha, phase):
    """Write a checkpoint JSON file."""
    data = {
        "git_sha": sha,
        "phase": phase,
        "timestamp": "2026-01-01T00:00:00Z",
        "passed": 1,
        "failed": 0,
    }
    path = os.path.join(directory, f"{name}.json")
    with open(path, "w") as f:
        json.dump(data, f)


def _make_latest_checkpoint(directory, name, sha, phase):
    """Write a latest checkpoint JSON file."""
    data = {
        "git_sha": sha,
        "phase": phase,
        "timestamp": "2026-01-01T00:00:00Z",
        "passed": 1,
        "failed": 0,
        "skipped": 0,
    }
    path = os.path.join(directory, f"{name}-latest.json")
    with open(path, "w") as f:
        json.dump(data, f)


def _make_proof_file(directory):
    """Write a minimal proof JSON file."""
    data = {
        "gate": "lint",
        "status": "pass",
        "sha": "abc123",
        "failures": [],
        "timestamp": "2026-01-01T00:00:00Z",
    }
    path = os.path.join(directory, "lint.json")
    with open(path, "w") as f:
        json.dump(data, f)


def _run_collect_proof(cwd, env, proof_dir, checkpoint_dir):
    """Run collect-proof.sh and return the PROOF.md content."""
    result = subprocess.run(
        ["bash", COLLECT_PROOF],
        cwd=str(cwd),
        env={**env, "PROOF_DIR": proof_dir, "CHECKPOINT_DIR": checkpoint_dir},
        capture_output=True,
        text=True,
    )
    proof_md = os.path.join(proof_dir, "PROOF.md")
    assert os.path.exists(proof_md), f"PROOF.md not created: {result.stderr}"
    with open(proof_md) as f:
        return f.read()


def test_filters_checkpoints_to_branch_shas(tmp_path):
    """Checkpoints from other branches are excluded on feature branches."""
    env = _setup_git_repo(tmp_path)
    run = lambda cmd: subprocess.run(
        cmd, cwd=str(tmp_path), env=env, capture_output=True, check=True
    )

    run(["git", "checkout", "-q", "-b", "feat/test-branch"])
    run(["git", "commit", "--allow-empty", "-q", "-m", "feat commit 1"])
    sha1 = (
        subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(tmp_path),
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        .stdout.strip()
    )
    run(["git", "commit", "--allow-empty", "-q", "-m", "feat commit 2"])

    proof_dir = str(tmp_path / "proof")
    cp_dir = str(tmp_path / "checkpoints")
    os.makedirs(proof_dir)
    os.makedirs(cp_dir)

    _make_checkpoint(cp_dir, "build-branch", sha1, "build")
    _make_checkpoint(cp_dir, "build-other", "deadbeef123456", "build")
    _make_proof_file(proof_dir)

    output = _run_collect_proof(tmp_path, env, proof_dir, cp_dir)

    assert sha1 in output, "Branch SHA should appear in output"
    assert "deadbeef123456" not in output, "Stale SHA should be excluded"


def test_on_default_branch_shows_all(tmp_path):
    """On default branch (0 commits ahead), all checkpoints are shown."""
    env = _setup_git_repo(tmp_path)

    proof_dir = str(tmp_path / "proof")
    cp_dir = str(tmp_path / "checkpoints")
    os.makedirs(proof_dir)
    os.makedirs(cp_dir)

    _make_checkpoint(cp_dir, "build-a", "aaa111", "build")
    _make_checkpoint(cp_dir, "build-b", "bbb222", "build")
    _make_proof_file(proof_dir)

    output = _run_collect_proof(tmp_path, env, proof_dir, cp_dir)

    assert "aaa111" in output, "SHA aaa111 should be included on default branch"
    assert "bbb222" in output, "SHA bbb222 should be included on default branch"


def test_pipeline_summary_also_filtered(tmp_path):
    """Latest checkpoints in Pipeline Summary are also filtered."""
    env = _setup_git_repo(tmp_path)
    run = lambda cmd: subprocess.run(
        cmd, cwd=str(tmp_path), env=env, capture_output=True, check=True
    )

    run(["git", "checkout", "-q", "-b", "feat/test-filter"])
    run(["git", "commit", "--allow-empty", "-q", "-m", "branch commit"])
    branch_sha = (
        subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(tmp_path),
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        .stdout.strip()
    )

    proof_dir = str(tmp_path / "proof")
    cp_dir = str(tmp_path / "checkpoints")
    os.makedirs(proof_dir)
    os.makedirs(cp_dir)

    _make_latest_checkpoint(cp_dir, "build", branch_sha, "build")
    _make_latest_checkpoint(cp_dir, "other", "stale999", "other-phase")
    _make_proof_file(proof_dir)

    output = _run_collect_proof(tmp_path, env, proof_dir, cp_dir)

    assert "stale999" not in output, "Stale latest checkpoint should be excluded"


def test_empty_sha_checkpoint_excluded(tmp_path):
    """Checkpoints with missing git_sha are excluded, not wildcard-matched."""
    env = _setup_git_repo(tmp_path)
    run = lambda cmd: subprocess.run(
        cmd, cwd=str(tmp_path), env=env, capture_output=True, check=True
    )

    run(["git", "checkout", "-q", "-b", "feat/empty-sha"])
    run(["git", "commit", "--allow-empty", "-q", "-m", "commit"])

    proof_dir = str(tmp_path / "proof")
    cp_dir = str(tmp_path / "checkpoints")
    os.makedirs(proof_dir)
    os.makedirs(cp_dir)

    # Checkpoint with no git_sha field
    malformed = os.path.join(cp_dir, "bad-checkpoint.json")
    with open(malformed, "w") as f:
        json.dump({"phase": "bad", "timestamp": "2026-01-01T00:00:00Z"}, f)

    _make_proof_file(proof_dir)

    output = _run_collect_proof(tmp_path, env, proof_dir, cp_dir)

    assert "bad" not in output.split("### Gate Details")[0], (
        "Checkpoint with empty SHA should be excluded from history"
    )
