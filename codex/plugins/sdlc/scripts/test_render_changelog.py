"""Tests for render_changelog.py — single-pass Phase 4 rendering."""

import json
import os
import subprocess
import sys
import tempfile


SCRIPT = os.path.join(os.path.dirname(__file__), "render_changelog.py")


def _setup(tmp, plugin_name, changelog_body, upgraded_line, use_marketplace_loc=False):
    """Scaffold a fake plugins dir + marketplaces json + upgraded file.

    When use_marketplace_loc is True, the changelog is placed where
    find_changelog's fallback path (via installLocation in the
    marketplaces json) will discover it, not the marketplace glob.
    """
    mf_path = os.path.join(tmp, "known_marketplaces.json")
    up_path = os.path.join(tmp, "upgraded.txt")

    if use_marketplace_loc:
        loc = os.path.join(tmp, "custom-marketplace")
        cl_dir = os.path.join(loc, "plugins", plugin_name)
        os.makedirs(cl_dir, exist_ok=True)
        with open(os.path.join(cl_dir, "CHANGELOG.md"), "w") as f:
            f.write(changelog_body)
        mf_data = {"custom": {"installLocation": loc}}
    else:
        mp_dir = os.path.join(tmp, "marketplaces", "arqu-plugins", "plugins", plugin_name)
        os.makedirs(mp_dir, exist_ok=True)
        with open(os.path.join(mp_dir, "CHANGELOG.md"), "w") as f:
            f.write(changelog_body)
        mf_data = {"arqu-plugins": {"installLocation": "/nonexistent"}}

    with open(mf_path, "w") as f:
        json.dump(mf_data, f)
    with open(up_path, "w") as f:
        f.write(upgraded_line + "\n")

    return mf_path, up_path


def _run(plugins_dir, mf_path, up_path):
    result = subprocess.run(
        [sys.executable, SCRIPT, plugins_dir, mf_path, up_path],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"stdout: {result.stdout}\nstderr: {result.stderr}"
    return result.stdout


def test_renders_items_since_old_version():
    with tempfile.TemporaryDirectory() as tmp:
        cl = """# Changelog

## v1.2.0
- added feature A
- added feature B

## v1.1.0
- older thing
"""
        mf_path, up_path = _setup(tmp, "sdlc", cl, "sdlc|1.1.0")
        out = _run(tmp, mf_path, up_path)
    assert "sdlc (from v1.1.0):" in out
    assert "- added feature A" in out
    assert "- added feature B" in out
    assert "older thing" not in out  # below the old version cutoff


def test_marketplace_loc_fallback():
    """When the marketplace glob does not match, find_changelog falls
    back to the installLocation path in known_marketplaces.json."""
    with tempfile.TemporaryDirectory() as tmp:
        cl = "# Changelog\n\n## v2.0.0\n- custom loc feature\n"
        mf_path, up_path = _setup(
            tmp, "custom-plugin", cl, "custom-plugin|1.9.0", use_marketplace_loc=True
        )
        out = _run(tmp, mf_path, up_path)
    assert "custom-plugin (from v1.9.0):" in out
    assert "- custom loc feature" in out


def test_no_changelog_found():
    with tempfile.TemporaryDirectory() as tmp:
        mf_path = os.path.join(tmp, "known_marketplaces.json")
        up_path = os.path.join(tmp, "upgraded.txt")
        with open(mf_path, "w") as f:
            json.dump({}, f)
        with open(up_path, "w") as f:
            f.write("nonexistent-plugin|1.0.0\n")
        out = _run(tmp, mf_path, up_path)
    assert "nonexistent-plugin: updated (no changelog found)" in out


def test_truncates_at_10_items():
    with tempfile.TemporaryDirectory() as tmp:
        items = "\n".join(f"- item {i}" for i in range(15))
        cl = f"# Changelog\n\n## v3.0.0\n{items}\n"
        mf_path, up_path = _setup(tmp, "big", cl, "big|2.9.0")
        out = _run(tmp, mf_path, up_path)
    assert "- item 0" in out
    assert "- item 9" in out
    assert "- item 14" not in out  # cut off at 10
    assert "...and 5 more" in out


def test_empty_items_section():
    with tempfile.TemporaryDirectory() as tmp:
        cl = "# Changelog\n\n## v1.0.1\n\nNo bullet points here.\n\n## v1.0.0\n- ancient\n"
        mf_path, up_path = _setup(tmp, "plain", cl, "plain|1.0.0")
        out = _run(tmp, mf_path, up_path)
    assert "plain (from v1.0.0):" in out
    assert "(no changelog entries found)" in out


def test_malformed_upgraded_line_skipped():
    """Lines without a pipe separator must be ignored, not crash."""
    with tempfile.TemporaryDirectory() as tmp:
        cl = "# Changelog\n\n## v1.0.0\n- real\n"
        mf_path, _ = _setup(tmp, "real", cl, "real|0.9.0")
        up_path = os.path.join(tmp, "upgraded.txt")
        with open(up_path, "w") as f:
            f.write("\n")
            f.write("no_pipe_separator\n")
            f.write("real|0.9.0\n")
        out = _run(tmp, mf_path, up_path)
    assert "real (from v0.9.0):" in out
    assert "- real" in out


def test_empty_marketplace_location_skipped():
    """Marketplace entries with empty installLocation must not crash.
    Exercises the `if not loc: continue` guard in find_changelog's
    fallback loop by NOT placing the changelog in the marketplace glob
    path — find_changelog must fall through to the mf_locations loop,
    hit the empty entry, skip it, then find the real one."""
    with tempfile.TemporaryDirectory() as tmp:
        cl = "# Changelog\n\n## v2.0.0\n- item\n\n## v1.0.0\n- old\n"
        # Place changelog via a real installLocation (not the glob path)
        real_loc = os.path.join(tmp, "real-marketplace")
        cl_dir = os.path.join(real_loc, "plugins", "pkg")
        os.makedirs(cl_dir, exist_ok=True)
        with open(os.path.join(cl_dir, "CHANGELOG.md"), "w") as f:
            f.write(cl)
        mf_path = os.path.join(tmp, "known_marketplaces.json")
        # First entry: empty installLocation → exercises the `continue`
        # Second entry: real path → finds the changelog
        with open(mf_path, "w") as f:
            json.dump({
                "empty-loc": {"installLocation": ""},
                "real-loc": {"installLocation": real_loc},
            }, f)
        up_path = os.path.join(tmp, "upgraded.txt")
        with open(up_path, "w") as f:
            f.write("pkg|1.0.0\n")
        out = _run(tmp, mf_path, up_path)
    assert "- item" in out


def test_parse_error_shows_detail():
    """A changelog that causes a parse exception should surface the
    exception message, not a bare 'parse error' string."""
    with tempfile.TemporaryDirectory() as tmp:
        # Write a changelog containing binary data that trips
        # a UnicodeDecodeError when opened as text.
        mp_dir = os.path.join(tmp, "marketplaces", "arqu-plugins", "plugins", "broken")
        os.makedirs(mp_dir, exist_ok=True)
        cl_path = os.path.join(mp_dir, "CHANGELOG.md")
        with open(cl_path, "wb") as f:
            f.write(b"## v2.0.0\n- ok\n\xff\xfe\n## v1.0.0\n- old\n")
        mf_path = os.path.join(tmp, "known_marketplaces.json")
        with open(mf_path, "w") as f:
            json.dump({}, f)
        up_path = os.path.join(tmp, "upgraded.txt")
        with open(up_path, "w") as f:
            f.write("broken|1.0.0\n")
        result = subprocess.run(
            [sys.executable, SCRIPT, tmp, mf_path, up_path],
            capture_output=True,
            text=True,
        )
    assert result.returncode == 0
    assert "changelog parse error:" in result.stdout


def test_usage_exit_code_on_wrong_arg_count():
    result = subprocess.run(
        [sys.executable, SCRIPT, "only-one-arg"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2
    assert "Usage:" in result.stderr


def test_exact_version_match_not_prefix():
    """Regression: `startswith` used to let old='1.1' match
    `## v1.10.0` before `## v1.1.0`, truncating the changelog."""
    with tempfile.TemporaryDirectory() as tmp:
        cl = """# Changelog

## v1.11.0
- newest entry

## v1.10.0
- tenth release

## v1.1.0
- old release
"""
        mf_path, up_path = _setup(tmp, "pkg", cl, "pkg|1.1.0")
        out = _run(tmp, mf_path, up_path)
    # old_version='1.1.0' must cut at ## v1.1.0 exactly, so items
    # from v1.11.0 AND v1.10.0 must appear, "old release" must not
    assert "- newest entry" in out
    assert "- tenth release" in out
    assert "- old release" not in out


def test_invalid_plugin_name_rejected():
    """Path-traversal style names must be rejected before any
    filesystem path is constructed. Legit names in the same file
    must still process through render_one and produce real output."""
    with tempfile.TemporaryDirectory() as tmp:
        # Scaffold a real changelog for the legit plugin so the
        # assertion proves render_one actually ran (not just the
        # no-changelog fallback).
        cl = "# Changelog\n\n## v2.0.0\n- safe feature\n\n## v1.0.0\n- initial\n"
        mf_path, _ = _setup(tmp, "legit", cl, "legit|1.0.0")
        up_path = os.path.join(tmp, "upgraded.txt")
        with open(up_path, "w") as f:
            f.write("../../etc/passwd|1.0.0\n")
            f.write("legit|1.0.0\n")
        result = subprocess.run(
            [sys.executable, SCRIPT, tmp, mf_path, up_path],
            capture_output=True,
            text=True,
        )
    assert result.returncode == 0
    # Traversal name rejected on stderr
    assert "skipping plugin with invalid name" in result.stderr
    assert "../../etc/passwd" in result.stderr
    # Legit name rendered a real changelog entry (not just "no changelog found")
    assert "legit (from v1.0.0):" in result.stdout
    assert "- safe feature" in result.stdout
