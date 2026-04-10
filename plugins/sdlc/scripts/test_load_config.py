"""Tests for load-config.sh — path overrides, extension defaults, threshold resolution."""

import json
import os
import subprocess
import tempfile


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOAD_CONFIG = os.path.join(SCRIPT_DIR, "load-config.sh")


def _run_bash(script_body, cwd=None, env_extra=None):
    """Run a bash snippet that sources load-config.sh and capture stdout."""
    env = dict(os.environ)
    # Sentinel path bypasses load-config.sh's auto-discovery (which would
    # otherwise pick up this repo's own sdlc.config.json). Tests that need a
    # real config override via env_extra.
    env["SDLC_CONFIG_FILE"] = "/nonexistent/sdlc.config.json"
    # Ensure we're in a git repo for load-config.sh
    if cwd is None:
        cwd = SCRIPT_DIR
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        ["bash", "-c", script_body],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
    )
    return result


def _get_threshold(filepath, key, cwd=None, config_file="", path_overrides=None):
    """Call get_threshold via bash and return the result."""
    tmp_config = None
    if path_overrides is not None and not config_file:
        fd, tmp_config = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump({"path_overrides": path_overrides}, f)
        config_file = tmp_config
    env_extra = {}
    if config_file:
        env_extra["SDLC_CONFIG_FILE"] = config_file
    export_line = f'export SDLC_CONFIG_FILE="{config_file}"' if config_file else ""
    script = f"""
        {export_line}
        source "{LOAD_CONFIG}"
        get_threshold "{filepath}" "{key}"
    """
    try:
        result = _run_bash(script, cwd=cwd, env_extra=env_extra)
        return result.stdout.strip()
    finally:
        if tmp_config:
            os.unlink(tmp_config)


def _resolve_all_thresholds(file_list, key, cwd=None, config_file=""):
    """Call resolve_all_thresholds via bash and return path->value dict."""
    fd, list_file = tempfile.mkstemp(suffix=".txt")
    try:
        with os.fdopen(fd, "w") as f:
            for filepath in file_list:
                f.write(filepath + "\n")
        env_extra = {}
        if config_file:
            env_extra["SDLC_CONFIG_FILE"] = config_file
        export_line = f'export SDLC_CONFIG_FILE="{config_file}"' if config_file else ""
        script = f"""
            {export_line}
            source "{LOAD_CONFIG}"
            resolve_all_thresholds "{list_file}" "{key}"
        """
        result = _run_bash(script, cwd=cwd, env_extra=env_extra)
        pairs = {}
        for line in result.stdout.strip().splitlines():
            if "\t" in line:
                path, val = line.split("\t", 1)
                pairs[path] = val
        return pairs
    finally:
        os.unlink(list_file)


# --- Path overrides ---


def test_md_file_has_no_file_size_limit():
    """Markdown files are excluded from file size limits via extension default."""
    val = _get_threshold("docs/specs/2026-03-18-my-spec.md", "max_file_lines")
    assert val == "null"


def test_nested_md_file_has_no_file_size_limit():
    """Markdown files in nested paths are also excluded."""
    val = _get_threshold("project/docs/architecture/design.md", "max_file_lines")
    assert val == "null"


def test_md_readme_has_no_file_size_limit():
    """All .md files have no limit, including READMEs."""
    val = _get_threshold("docs/README.md", "max_file_lines")
    assert val == "null"


def test_regular_ts_file_uses_global_default():
    val = _get_threshold("src/app.ts", "max_file_lines")
    assert val == "300"


def test_json_file_has_no_limit():
    val = _get_threshold("package.json", "max_file_lines")
    assert val == "null"


def test_css_file_has_no_function_limit():
    val = _get_threshold("styles/main.css", "max_function_lines")
    assert val == "null"


# --- resolve_all_thresholds batch ---


def test_resolve_batch_with_spec_and_regular():
    files = [
        "docs/specs/my-spec.md",
        "docs/README.md",
        "src/app.ts",
    ]
    pairs = _resolve_all_thresholds(files, "max_file_lines")
    assert pairs["docs/specs/my-spec.md"] == "null"
    assert pairs["docs/README.md"] == "null"
    assert pairs["src/app.ts"] == "300"


def test_resolve_batch_skips_empty_lines():
    files = ["src/app.ts", "", "src/util.ts"]
    pairs = _resolve_all_thresholds(files, "max_file_lines")
    assert len(pairs) == 2
    assert "src/app.ts" in pairs
    assert "src/util.ts" in pairs


# --- User config overrides ---


def test_user_config_path_overrides_take_priority():
    """User path_overrides in sdlc.config.json override baked-in path overrides."""
    fd, config_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(
                {
                    "path_overrides": {
                        "**/specs/**": {"max_file_lines": 1000},
                    }
                },
                f,
            )
        val = _get_threshold(
            "docs/specs/my-spec.md", "max_file_lines", config_file=config_path
        )
        assert val == "1000"
    finally:
        os.unlink(config_path)


def test_user_config_extension_overrides():
    """User extension overrides in sdlc.config.json override baked-in extension defaults."""
    fd, config_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"extensions": {"md": {"max_file_lines": 800}}}, f)
        val = _get_threshold("docs/README.md", "max_file_lines", config_file=config_path)
        assert val == "800"
    finally:
        os.unlink(config_path)


def test_user_config_threshold_overrides_global():
    """User thresholds in sdlc.config.json override global defaults."""
    fd, config_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"thresholds": {"max_file_lines": 200}}, f)
        val = _get_threshold("src/app.ts", "max_file_lines", config_file=config_path)
        assert val == "200"
    finally:
        os.unlink(config_path)


# --- Priority order tests ---


def test_path_override_beats_extension_default():
    """User path_overrides override extension defaults for matching paths."""
    fd, config_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(
                {"path_overrides": {"**/special/**": {"max_file_lines": 999}}},
                f,
            )
        val = _get_threshold(
            "src/special/big.ts", "max_file_lines", config_file=config_path
        )
        assert val == "999"
    finally:
        os.unlink(config_path)


def test_extension_default_beats_global():
    """Extension defaults (e.g., .md=None) override global default (300)."""
    val = _get_threshold("docs/guide.md", "max_file_lines")
    assert val == "null"


# --- Edge cases ---


def test_threshold_for_unknown_extension_uses_global():
    val = _get_threshold("src/main.xyz", "max_file_lines")
    assert val == "300"


def test_threshold_for_key_not_in_extension():
    """Requesting max_complexity for .md should fall through to global default."""
    val = _get_threshold("docs/guide.md", "max_complexity")
    assert val == "8"


# --- New path_match semantics ---


def test_path_based_overrides_use_new_matcher_semantics():
    """docs/specs/*.md matches direct children, NOT nested files."""
    # path override should match docs/specs/foo.md
    val = _get_threshold("docs/specs/foo.md", "max_file_lines",
                         path_overrides={"docs/specs/*.md": {"max_file_lines": 1000}})
    assert val == "1000"
    # but NOT docs/specs/nested/foo.md
    val = _get_threshold("docs/specs/nested/foo.md", "max_file_lines",
                         path_overrides={"docs/specs/*.md": {"max_file_lines": 1000}})
    assert val != "1000"


def test_bare_pattern_matches_basename_at_any_depth():
    """*.rb matches invoice.rb AND app/models/invoice.rb."""
    val = _get_threshold("invoice.rb", "max_file_lines",
                         path_overrides={"*.rb": {"max_file_lines": 500}})
    assert val == "500"
    val = _get_threshold("app/models/invoice.rb", "max_file_lines",
                         path_overrides={"*.rb": {"max_file_lines": 500}})
    assert val == "500"
