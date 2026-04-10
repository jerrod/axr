"""Tests for render_exceptions.py.

Tests invoke the script via subprocess using tempfile-based PROOF_DIR and
config fixtures. No mocking of internal module state.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).parent / "render_exceptions.py"


def _run(proof_dir: str, config_file: str = "") -> str:
    """Run the script and return stdout."""
    env = os.environ.copy()
    env["PROOF_DIR"] = proof_dir
    env["SDLC_CONFIG_FILE"] = config_file
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=True,
        cwd=tempfile.gettempdir(),
    )
    return result.stdout


def _entry_key(**fields) -> str:
    """Produce the canonical entry_key the same way is_allowed_check.py does."""
    return json.dumps(fields, sort_keys=True)


def _write_jsonl(path: str, records: list[dict]) -> None:
    with open(path, "w") as f:
        for rec in records:
            # Auto-populate entry_key from the record if not provided,
            # so test fixtures don't have to repeat canonical JSON by hand.
            if "entry_key" not in rec:
                rec = {
                    **rec,
                    "entry_key": _entry_key(
                        file=rec.get("pattern", "")
                    ),
                }
            f.write(json.dumps(rec) + "\n")


def _write_config(path: str, allow: dict) -> None:
    with open(path, "w") as f:
        json.dump({"allow": allow}, f)


def test_jsonl_dedup_within_gate(tmp_path):
    """Same pattern appearing twice in a gate file should appear once in active."""
    pd = tmp_path / "proof"
    pd.mkdir()
    _write_jsonl(
        str(pd / "allow-tracking-filesize.jsonl"),
        [
            {"gate": "filesize", "pattern": "foo.py", "reason": "legacy"},
            {"gate": "filesize", "pattern": "foo.py", "reason": "legacy"},
            {"gate": "filesize", "pattern": "bar.py", "reason": "other"},
        ],
    )
    out = _run(str(pd))
    assert out.count("foo.py") == 1
    assert "bar.py" in out
    assert "Active Exceptions (2)" in out


def test_stale_detection(tmp_path):
    """Entry in config but not matched should appear as stale."""
    pd = tmp_path / "proof"
    pd.mkdir()
    _write_jsonl(
        str(pd / "allow-tracking-filesize.jsonl"),
        [{"gate": "filesize", "pattern": "used.py", "reason": "ok"}],
    )
    cfg = tmp_path / "sdlc.config.json"
    _write_config(
        str(cfg),
        {
            "filesize": [
                {"file": "used.py", "reason": "ok"},
                {"file": "unused.py", "reason": "obsolete"},
            ]
        },
    )
    out = _run(str(pd), str(cfg))
    assert "Stale Exceptions (1)" in out
    assert "unused.py" in out
    assert "obsolete" in out


def test_pipe_escaping(tmp_path):
    """Pipes in pattern and reason must be escaped for markdown tables."""
    pd = tmp_path / "proof"
    pd.mkdir()
    _write_jsonl(
        str(pd / "allow-tracking-lint.jsonl"),
        [{"gate": "lint", "pattern": "a|b.py", "reason": "x|y"}],
    )
    out = _run(str(pd))
    assert "a\\|b.py" in out
    assert "x\\|y" in out


def test_missing_proof_dir(tmp_path):
    """Nonexistent PROOF_DIR produces empty output (no sections)."""
    missing = tmp_path / "does-not-exist"
    out = _run(str(missing))
    assert "Active Exceptions" not in out
    assert "Stale Exceptions" not in out


def test_missing_config_file(tmp_path):
    """No config file means no stale section, but active still prints."""
    pd = tmp_path / "proof"
    pd.mkdir()
    _write_jsonl(
        str(pd / "allow-tracking-filesize.jsonl"),
        [{"gate": "filesize", "pattern": "foo.py", "reason": "r"}],
    )
    out = _run(str(pd), str(tmp_path / "nonexistent.json"))
    assert "Active Exceptions (1)" in out
    assert "Stale Exceptions" not in out


def test_invalid_json_lines_skipped(tmp_path):
    """Bad JSON lines are skipped; valid lines still render."""
    pd = tmp_path / "proof"
    pd.mkdir()
    with open(pd / "allow-tracking-lint.jsonl", "w") as f:
        f.write("not json\n")
        rec = {
            "gate": "lint",
            "pattern": "ok.py",
            "reason": "r",
            "entry_key": _entry_key(file="ok.py"),
        }
        f.write(json.dumps(rec) + "\n")
        f.write("{broken\n")
    out = _run(str(pd))
    assert "Active Exceptions (1)" in out
    assert "ok.py" in out


def test_gates_not_in_matched_excluded_from_stale(tmp_path):
    """Config gate with no tracking file should not produce stale entries."""
    pd = tmp_path / "proof"
    pd.mkdir()
    # No tracking file written → matched_patterns_per_gate is empty.
    cfg = tmp_path / "sdlc.config.json"
    _write_config(
        str(cfg),
        {"filesize": [{"file": "x.py", "reason": "r"}]},
    )
    out = _run(str(pd), str(cfg))
    assert "Stale Exceptions" not in out


def test_entry_shape_fallback(tmp_path):
    """Stale detection honors file → pattern → type priority."""
    pd = tmp_path / "proof"
    pd.mkdir()
    # Register the gate so it's in matched_patterns_per_gate.
    _write_jsonl(
        str(pd / "allow-tracking-complexity.jsonl"),
        [{"gate": "complexity", "pattern": "matched.py", "reason": "r"}],
    )
    cfg = tmp_path / "sdlc.config.json"
    _write_config(
        str(cfg),
        {
            "complexity": [
                {"file": "f.py", "reason": "via-file"},
                {"pattern": "p.py", "reason": "via-pattern"},
                {"type": "t.py", "reason": "via-type"},
                {"reason": "no-key"},
            ]
        },
    )
    out = _run(str(pd), str(cfg))
    assert "via-file" in out
    assert "via-pattern" in out
    assert "via-type" in out
    # Entry with no identifying key is skipped.
    assert "no-key" not in out


def test_multi_field_entries_distinguished_by_entry_key(tmp_path):
    """Dead-code entries sharing a file but differing by name must be tracked
    independently — one matched, the other stale."""
    pd = tmp_path / "proof"
    pd.mkdir()
    matched_key = _entry_key(file="a.py", name="foo", type="unused_import")
    with open(pd / "allow-tracking-dead-code.jsonl", "w") as f:
        f.write(
            json.dumps(
                {
                    "gate": "dead-code",
                    "pattern": "a.py",
                    "reason": "r1",
                    "entry_key": matched_key,
                }
            )
            + "\n"
        )
    cfg = tmp_path / "sdlc.config.json"
    _write_config(
        str(cfg),
        {
            "dead-code": [
                {
                    "file": "a.py",
                    "name": "foo",
                    "type": "unused_import",
                    "reason": "r1 matched",
                },
                {
                    "file": "a.py",
                    "name": "bar",
                    "type": "unused_import",
                    "reason": "r2 should be stale",
                },
            ]
        },
    )
    out = _run(str(pd), str(cfg))
    assert "Stale Exceptions (1)" in out
    assert "r2 should be stale" in out
    assert "r1 matched" not in out


def test_invalid_config_json(tmp_path):
    """Invalid JSON in config file is tolerated (no stale section)."""
    pd = tmp_path / "proof"
    pd.mkdir()
    _write_jsonl(
        str(pd / "allow-tracking-lint.jsonl"),
        [{"gate": "lint", "pattern": "ok.py", "reason": "r"}],
    )
    cfg = tmp_path / "sdlc.config.json"
    cfg.write_text("{not valid json")
    out = _run(str(pd), str(cfg))
    assert "Active Exceptions (1)" in out
    assert "Stale Exceptions" not in out
