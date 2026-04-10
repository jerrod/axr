#!/usr/bin/env python3
"""Render the 'what's new' section for sdlc-update.sh Phase 4.

Reads the just-upgraded-from file (one 'plugin|old_version' per line)
and emits a formatted changelog block for each plugin to stdout.

Usage:
    python3 render_changelog.py <plugins_dir> <marketplaces_json> <upgraded_file>

Consolidates Phase 4 into a single python3 invocation so the sdlc-update
caller does not spawn two subprocesses per plugin (the prior
implementation).
"""

import glob
import json
import os
import re
import sys

# Defense-in-depth: reject plugin names containing path-traversal or
# shell-metacharacter sequences before using them as filesystem path
# components. Mirrors the allowlist in sdlc-update.sh Phase 3 so the
# script is safe to invoke standalone even if the upgraded-from file
# has been tampered with.
_VALID_PLUGIN_NAME = re.compile(r"^[A-Za-z0-9_.@/-]+$")


def _is_valid_plugin_name(name):
    # The shell-side regex in sdlc-update.sh Phase 3 already rejects
    # non-ASCII and URL-encoded characters before the name reaches
    # the upgraded-from file — no URL-decode needed here.
    # Regex allows '.' and '/' individually; the split-check blocks
    # path-traversal sequences like `../` that the regex alone misses.
    return bool(_VALID_PLUGIN_NAME.match(name)) and ".." not in name.split("/")


def find_changelog(plugins_dir, plugin_name, mf_locations):
    """Locate CHANGELOG.md for a plugin across every known source.

    Prefers the marketplace cache glob, then falls back to the
    installLocation entries from known_marketplaces.json.
    """
    for d in glob.glob(
        os.path.join(plugins_dir, "marketplaces", "*", "plugins", plugin_name, "CHANGELOG.md")
    ):
        return d
    for loc in mf_locations:
        if not loc:
            continue
        path = os.path.join(loc, "plugins", plugin_name, "CHANGELOG.md")
        if os.path.isfile(path):
            return path
    return None


def parse_since(changelog_path, old_version):
    """Return the list of bullet items added since old_version.

    Uses exact version equality — the earlier `startswith` branch
    produced false positives (e.g. `old='1.1'` would wrongly match
    `## v1.10.0` before reaching `## v1.1.0`, truncating the changelog).
    """
    with open(changelog_path) as f:
        cl = f.read()
    versions = list(re.finditer(r"^## v(\S+)", cl, re.MULTILINE))
    old_pos = len(cl)
    for v in versions:
        if v.group(1) == old_version:
            old_pos = v.start()
            break
    return re.findall(r"^[-*] (.+)$", cl[:old_pos], re.MULTILINE)


def render_one(plugin_name, old_version, plugins_dir, mf_locations):
    """Emit the 'what's new' block for a single plugin to stdout."""
    if not _is_valid_plugin_name(plugin_name):
        print(f"  skipping plugin with invalid name: {plugin_name}", file=sys.stderr)
        return
    changelog = find_changelog(plugins_dir, plugin_name, mf_locations)
    if not changelog:
        print(f"  {plugin_name}: updated (no changelog found)")
        return
    print(f"  {plugin_name} (from v{old_version}):")
    try:
        items = parse_since(changelog, old_version)
    except Exception as exc:
        # Include the exception detail so a future debugger has
        # something to go on instead of a bare "parse error" line.
        print(f"    (changelog parse error: {exc})")
        print("")
        return
    for item in items[:10]:
        print(f"    - {item}")
    if len(items) > 10:
        print(f"    ...and {len(items) - 10} more")
    if not items:
        print("    (no changelog entries found)")
    print("")


def main(argv):
    if len(argv) != 4:
        print(
            "Usage: render_changelog.py <plugins_dir> <marketplaces_json> <upgraded_file>",
            file=sys.stderr,
        )
        return 2
    plugins_dir, marketplaces_json, upgraded_file = argv[1], argv[2], argv[3]
    with open(marketplaces_json) as f:
        mf_data = json.load(f)
    mf_locations = [info.get("installLocation", "") for info in mf_data.values()]
    with open(upgraded_file) as f:
        for line in f:
            line = line.strip()
            if not line or "|" not in line:
                continue
            plugin_name, old_version = line.split("|", 1)
            render_one(plugin_name, old_version, plugins_dir, mf_locations)
    return 0


if __name__ == "__main__":  # pragma: no cover — exercised via subprocess
    sys.exit(main(sys.argv))
