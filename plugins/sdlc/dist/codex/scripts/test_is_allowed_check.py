"""Tests for is_allowed_check.py.

Plain top-level `import is_allowed_check` so find_affected_tests.py
picks up the source→test link. conftest.py adds SCRIPTS_DIR to
sys.path before test collection so the import resolves.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import is_allowed_check

SCRIPTS_DIR = Path(__file__).parent


@pytest.fixture
def proof_dir(tmp_path, monkeypatch):
    d = tmp_path / "proof"
    monkeypatch.setenv("PROOF_DIR", str(d))
    return d


def test_no_entries_for_gate_returns_1(proof_dir):
    config = json.dumps({"other": [{"file": "x"}]})
    assert is_allowed_check.main(["prog", config, "filesize", "file=foo.py"]) == 1


def test_matching_file_entry_returns_0_and_writes_tracking(proof_dir):
    config = json.dumps(
        {"filesize": [{"file": "CHANGELOG.md", "reason": "generated file"}]}
    )
    rc = is_allowed_check.main(["prog", config, "filesize", "file=CHANGELOG.md"])
    assert rc == 0
    tracking = proof_dir / "allow-tracking-filesize.jsonl"
    assert tracking.exists()
    record = json.loads(tracking.read_text().strip())
    assert record["gate"] == "filesize"
    assert record["file"] == "CHANGELOG.md"
    assert record["pattern"] == "CHANGELOG.md"
    assert record["reason"] == "generated file"


def test_non_matching_file_returns_1_no_tracking(proof_dir):
    config = json.dumps({"filesize": [{"file": "CHANGELOG.md", "reason": "gen"}]})
    rc = is_allowed_check.main(["prog", config, "filesize", "file=src/app.py"])
    assert rc == 1
    assert not (proof_dir / "allow-tracking-filesize.jsonl").exists()


def test_reason_only_entry_does_not_match(proof_dir):
    # Entry with only "reason" would otherwise exempt every violation.
    config = json.dumps({"filesize": [{"reason": "this has no match fields yet"}]})
    rc = is_allowed_check.main(["prog", config, "filesize", "file=anything.py"])
    assert rc == 1


def test_multi_field_match(proof_dir):
    config = json.dumps(
        {
            "dead-code": [
                {
                    "file": "src/models.py",
                    "name": "annotations",
                    "type": "unused_import",
                    "reason": "needed for forward refs",
                }
            ]
        }
    )
    rc = is_allowed_check.main(
        [
            "prog",
            config,
            "dead-code",
            "file=src/models.py",
            "name=annotations",
            "type=unused_import",
        ]
    )
    assert rc == 0


def test_multi_field_partial_mismatch_returns_1(proof_dir):
    config = json.dumps(
        {
            "dead-code": [
                {
                    "file": "src/models.py",
                    "name": "annotations",
                    "reason": "r",
                }
            ]
        }
    )
    rc = is_allowed_check.main(
        ["prog", config, "dead-code", "file=src/models.py", "name=other_name"]
    )
    assert rc == 1


def test_reason_field_ignored_in_match(proof_dir):
    config = json.dumps({"filesize": [{"file": "a.py", "reason": "x" * 50}]})
    rc = is_allowed_check.main(["prog", config, "filesize", "file=a.py"])
    assert rc == 0


def test_fnmatch_glob_for_non_file_field(proof_dir):
    config = json.dumps(
        {"dead-code": [{"file": "*.py", "name": "_*", "reason": "private"}]}
    )
    rc = is_allowed_check.main(
        ["prog", config, "dead-code", "file=src/x.py", "name=_private_helper"]
    )
    assert rc == 0


def test_tracking_appends_multiple_records(proof_dir):
    config = json.dumps({"filesize": [{"file": "*.md", "reason": "docs"}]})
    is_allowed_check.main(["prog", config, "filesize", "file=README.md"])
    is_allowed_check.main(["prog", config, "filesize", "file=CHANGELOG.md"])
    tracking = proof_dir / "allow-tracking-filesize.jsonl"
    lines = tracking.read_text().strip().split("\n")
    assert len(lines) == 2


def test_write_tracking_rejects_bogus_gate_name(proof_dir):
    # Gate names must match [a-zA-Z0-9-]+ — reject ../.. injection and any
    # other non-identifier characters. No tracking file should be written;
    # the function returns silently (no exception).
    is_allowed_check._write_tracking("../evil", {"file": "a.py", "reason": "x" * 20}, {})
    assert list(proof_dir.glob("*")) == []


def test_write_tracking_swallows_oserror(monkeypatch):
    # When PROOF_DIR's parent is a regular file (not a dir), os.makedirs
    # raises OSError. The function must swallow so a matched-but-untrackable
    # entry still returns exit 0 to the caller.
    monkeypatch.setenv("PROOF_DIR", "/dev/null/nested")
    # Should NOT raise
    is_allowed_check._write_tracking("lint", {"file": "a.py", "reason": "x" * 20}, {"file": "a.py"})


def test_main_oversized_config_rejected(proof_dir):
    # Guard against env-var-injected oversized configs
    huge = "x" * 2_000_000
    rc = is_allowed_check.main(["prog", huge, "lint", "file=a.py"])
    assert rc == 1


def test_main_malformed_json_rejected(proof_dir):
    rc = is_allowed_check.main(["prog", "not-json", "lint", "file=a.py"])
    assert rc == 1


def test_main_non_dict_config_rejected(proof_dir):
    # A JSON array at the top level is valid JSON but not a valid allow config
    rc = is_allowed_check.main(["prog", "[1,2,3]", "lint", "file=a.py"])
    assert rc == 1


def test_main_non_list_entries_rejected(proof_dir):
    # entries must be a list; an object here is malformed
    config = json.dumps({"lint": {"file": "a.py"}})
    rc = is_allowed_check.main(["prog", config, "lint", "file=a.py"])
    assert rc == 1


def test_main_non_dict_entry_skipped(proof_dir):
    # A malformed entry (string instead of dict) should be skipped, not crash
    config = json.dumps({"lint": ["not-an-entry", {"file": "a.py", "reason": "x" * 20}]})
    rc = is_allowed_check.main(["prog", config, "lint", "file=a.py"])
    assert rc == 0


def test_branch_entry_records_branch_as_pattern(proof_dir):
    # branch_reason entries (allow.plan, allow.review) use "branch" as the
    # identifying field. The tracking record must record that branch as the
    # pattern so report_unused_allow_entries can match it back against the
    # live allow-list.
    config = json.dumps(
        {"plan": [{"branch": "feat/*", "reason": "tracked in jira XYZ-123"}]}
    )
    rc = is_allowed_check.main(["prog", config, "plan", "branch=feat/example"])
    assert rc == 0
    tracking = proof_dir / "allow-tracking-plan.jsonl"
    assert tracking.exists()
    record = json.loads(tracking.read_text().strip())
    assert record["pattern"] == "feat/*"
    assert record["gate"] == "plan"
    assert record["reason"].startswith("tracked in jira")
