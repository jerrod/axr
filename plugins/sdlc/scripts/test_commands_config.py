"""Tests for commands-config.sh — get_command and parse_command_config helpers."""

import json
import os
import subprocess
import tempfile


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOAD_CONFIG = os.path.join(SCRIPT_DIR, "load-config.sh")
COMMANDS_CONFIG = os.path.join(SCRIPT_DIR, "commands-config.sh")


def _run_bash(script_body, cwd=None, env_extra=None):
    """Run a bash snippet that sources load-config.sh and capture stdout."""
    env = dict(os.environ)
    env.pop("SDLC_CONFIG_FILE", None)
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


def test_get_command_returns_empty_when_no_commands():
    """get_command returns empty string when no commands configured."""
    result = _run_bash(f'''
        source "{LOAD_CONFIG}"
        source "{COMMANDS_CONFIG}"
        get_command "test"
    ''')
    assert result.stdout.strip() == ""


def test_get_command_returns_string_command():
    """get_command returns the string command for a gate."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump({"commands": {"lint": "bin/ktlint"}}, f)
        f.flush()
        try:
            result = _run_bash(f'''
                export SDLC_CONFIG_FILE="{f.name}"
                source "{LOAD_CONFIG}"
                source "{COMMANDS_CONFIG}"
                get_command "lint"
            ''')
            assert result.stdout.strip() == "bin/ktlint"
        finally:
            os.unlink(f.name)


def test_get_command_returns_json_for_object_command():
    """get_command returns JSON string for object-form commands."""
    cmd_config = {
        "commands": {
            "coverage": {
                "run": "./gradlew jacocoTestReport",
                "format": "jacoco",
                "report_path": "**/build/reports/jacoco/**/*.xml"
            }
        }
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(cmd_config, f)
        f.flush()
        try:
            result = _run_bash(f'''
                export SDLC_CONFIG_FILE="{f.name}"
                source "{LOAD_CONFIG}"
                source "{COMMANDS_CONFIG}"
                get_command "coverage"
            ''')
            parsed = json.loads(result.stdout.strip())
            assert parsed["format"] == "jacoco"
            assert parsed["run"] == "./gradlew jacocoTestReport"
        finally:
            os.unlink(f.name)


def test_get_command_returns_empty_for_unconfigured_gate():
    """get_command returns empty string for a gate not in commands."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump({"commands": {"lint": "bin/ktlint"}}, f)
        f.flush()
        try:
            result = _run_bash(f'''
                export SDLC_CONFIG_FILE="{f.name}"
                source "{LOAD_CONFIG}"
                source "{COMMANDS_CONFIG}"
                get_command "coverage"
            ''')
            assert result.stdout.strip() == ""
        finally:
            os.unlink(f.name)


def test_get_command_mixed_string_and_object():
    """String and object commands coexist without interfering."""
    cmd_config = {
        "commands": {
            "lint": "bin/ktlint",
            "coverage": {"run": "./gradlew test", "format": "jacoco", "report_path": "*.xml"}
        }
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(cmd_config, f)
        f.flush()
        try:
            result_str = _run_bash(f'''
                export SDLC_CONFIG_FILE="{f.name}"
                source "{LOAD_CONFIG}"
                source "{COMMANDS_CONFIG}"
                get_command "lint"
            ''')
            result_obj = _run_bash(f'''
                export SDLC_CONFIG_FILE="{f.name}"
                source "{LOAD_CONFIG}"
                source "{COMMANDS_CONFIG}"
                get_command "coverage"
            ''')
            assert result_str.stdout.strip() == "bin/ktlint"
            parsed = json.loads(result_obj.stdout.strip())
            assert parsed["format"] == "jacoco"
        finally:
            os.unlink(f.name)
