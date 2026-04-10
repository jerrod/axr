"""Tests for the inline JSON Schema validator in load-config.sh."""
import json
import os
import subprocess
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def run_validator(config_dict):
    """Write config to temp file, invoke validator, return (exit_code, stderr)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(config_dict, f)
        config_path = f.name
    try:
        # Pass paths via env rather than interpolating into the shell command.
        env = {**os.environ, "SDLC_CONFIG_FILE": config_path, "LOAD_CONFIG": f"{SCRIPT_DIR}/load-config.sh"}
        result = subprocess.run(
            ["bash", "-c", 'source "$LOAD_CONFIG" && validate_rq_config'],
            capture_output=True, text=True, env=env,
        )
        return result.returncode, result.stderr
    finally:
        os.unlink(config_path)


class TestValidConfig:
    def test_minimal_config_valid(self):
        code, _ = run_validator({"thresholds": {"max_file_lines": 300}})
        assert code == 0

    def test_full_allow_list_valid(self):
        cfg = {
            "allow": {
                "filesize": [{"file": "CHANGELOG.md", "reason": "grows over time — historical"}],
                "test-quality": [{"file": "test.py", "pattern": "@patch", "reason": "tests the scanner itself, not real mocks"}]
            }
        }
        code, _ = run_validator(cfg)
        assert code == 0

    def test_plan_required_top_level_valid(self):
        cfg = {"thresholds": {"max_file_lines": 300}, "plan_required": True}
        code, err = run_validator(cfg)
        assert code == 0, f"validator rejected plan_required: {err}"

    def test_allow_plan_branch_entry_valid(self):
        cfg = {"allow": {"plan": [{"branch": "feat/example", "reason": "tracked separately in jira ABC-123"}]}}
        code, err = run_validator(cfg)
        assert code == 0, f"validator rejected plan branch entry: {err}"

    def test_allow_review_branch_glob_valid(self):
        cfg = {"allow": {"review": [{"branch": "hotfix/*", "reason": "emergency hotfix branches skip review"}]}}
        code, err = run_validator(cfg)
        assert code == 0, f"validator rejected review branch entry: {err}"

    def test_allow_plan_short_branch_name_valid(self):
        # Short branch names like 'v1' or 'ci' are legitimate git refs and must be accepted
        cfg = {"allow": {"plan": [{"branch": "v1", "reason": "version branch skipped separately"}]}}
        code, err = run_validator(cfg)
        assert code == 0, f"validator rejected short branch name: {err}"

    def test_allow_plan_branch_with_plus_and_tilde_valid(self):
        # Git allows + and ~ in branch names — monorepo tools produce these
        cfg = {"allow": {"plan": [{"branch": "feat/v1.2+hotfix~1", "reason": "monorepo tool branch shape"}]}}
        code, err = run_validator(cfg)
        assert code == 0, f"validator rejected branch with + and ~: {err}"


class TestInvalidConfig:
    def test_unknown_gate_rejected(self):
        cfg = {"allow": {"nonexistent-gate": []}}
        code, err = run_validator(cfg)
        assert code != 0
        assert "nonexistent-gate" in err or "additionalProperties" in err or "unknown" in err.lower()

    def test_missing_reason_rejected(self):
        cfg = {"allow": {"filesize": [{"file": "a.txt"}]}}
        code, err = run_validator(cfg)
        assert code != 0
        assert "reason" in err

    def test_short_reason_rejected(self):
        cfg = {"allow": {"filesize": [{"file": "a.txt", "reason": "short"}]}}
        code, err = run_validator(cfg)
        assert code != 0
        assert "reason" in err.lower() or "minLength" in err or "15" in err

    def test_unknown_field_rejected(self):
        cfg = {"allow": {"filesize": [{"file": "a.txt", "reason": "long enough reason text", "bogus": True}]}}
        code, err = run_validator(cfg)
        assert code != 0

    def test_allow_plan_branch_entry_missing_reason_rejected(self):
        cfg = {"allow": {"plan": [{"branch": "feat/example"}]}}
        code, err = run_validator(cfg)
        assert code != 0
        assert "reason" in err.lower() or "required" in err.lower()

    def test_allow_plan_branch_entry_extra_field_rejected(self):
        cfg = {"allow": {"plan": [{"branch": "feat/example", "reason": "long enough reason text", "bogus": True}]}}
        code, err = run_validator(cfg)
        assert code != 0

    def test_allow_plan_branch_empty_rejected(self):
        # branch minLength is 1 — empty string is always invalid
        cfg = {"allow": {"plan": [{"branch": "", "reason": "long enough reason text"}]}}
        code, _ = run_validator(cfg)
        assert code != 0

    def test_allow_plan_branch_bad_chars_rejected(self):
        # branch pattern rejects whitespace and shell metacharacters
        cfg = {"allow": {"plan": [{"branch": "bad branch name", "reason": "long enough reason text"}]}}
        code, _ = run_validator(cfg)
        assert code != 0


class TestDeadCodeVariants:
    def test_dead_code_oneOf_first_variant_valid(self):
        cfg = {"allow": {"dead-code": [{
            "file": "src/a.py", "name": "unused", "type": "unused_import",
            "reason": "suppression via framework requirement"
        }]}}
        code, _ = run_validator(cfg)
        assert code == 0

    def test_dead_code_oneOf_second_variant_valid(self):
        cfg = {"allow": {"dead-code": [{
            "type": "commented_code", "reason": "blanket allow — documented in style guide"
        }]}}
        code, _ = run_validator(cfg)
        assert code == 0

    def test_dead_code_invalid_type_enum(self):
        cfg = {"allow": {"dead-code": [{
            "file": "a.py", "name": "x", "type": "invalid_type",
            "reason": "long enough reason text here"
        }]}}
        code, err = run_validator(cfg)
        assert code != 0


def _find_repo_root(start):
    """Walk upward from start until a directory containing sdlc.config.json is found."""
    cur = os.path.abspath(start)
    while cur != "/":
        if os.path.isfile(os.path.join(cur, "sdlc.config.json")):
            return cur
        cur = os.path.dirname(cur)
    raise FileNotFoundError("sdlc.config.json not found in any parent of " + start)


class TestCurrentConfigPasses:
    def test_repo_rq_config_json_validates(self):
        """The actual sdlc.config.json in this repo must pass validation."""
        repo_root = _find_repo_root(SCRIPT_DIR)
        with open(os.path.join(repo_root, "sdlc.config.json")) as f:
            cfg = json.load(f)
        code, err = run_validator(cfg)
        assert code == 0, f"current sdlc.config.json fails validation: {err}"
