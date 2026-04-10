#!/usr/bin/env python3
"""Check if a violation matches an allow-list entry.

Invoked from bash is_allowed() in threshold-helpers.sh.

Args:
  sys.argv[1]: JSON allow config (from $_RQ_ALLOW_CONFIG)
  sys.argv[2]: gate name
  sys.argv[3:]: field=value pairs (e.g. file=src/foo.py name=bar type=unused_import)

Env:
  PROOF_DIR: directory for tracking files (default .quality/proof)

Exits 0 if matched (violation is allowed), 1 if not matched.
On match, appends a record to ${PROOF_DIR}/allow-tracking-<gate>.jsonl.
"""

import fnmatch
import json
import os
import re
import sys

from allow_entry import entry_pattern
from path_match import path_match

try:
    import fcntl

    def _lock(fd):
        fcntl.flock(fd, fcntl.LOCK_EX)

    def _unlock(fd):
        fcntl.flock(fd, fcntl.LOCK_UN)
except ImportError:  # pragma: no cover — Windows / non-POSIX only
    def _lock(fd):
        _ = fd  # no-op shim

    def _unlock(fd):
        _ = fd  # no-op shim


def _parse_fields(args):
    fields = {}
    for arg in args:
        if "=" in arg:
            k, v = arg.split("=", 1)
            fields[k] = v
    return fields


def _field_matches(key, field_val, entry_val):
    # Intentionally different matchers: "file" fields are path-like and use
    # path_match (gitignore-adjacent: * does not cross /, ** does). Non-file
    # fields (name, type, pattern, line) are identifier-like — fnmatch is
    # appropriate because * can match arbitrary characters and there are
    # no path segments to preserve.
    if key == "file":
        return path_match(field_val, entry_val)
    return fnmatch.fnmatch(field_val, entry_val) or field_val == entry_val


def _entry_matches(entry, fields):
    match_keys = [k for k in entry if k != "reason"]
    if not match_keys:
        return False  # reason-only entry matches nothing (would otherwise exempt all)
    for k in match_keys:
        if not _field_matches(k, fields.get(k, ""), str(entry[k])):
            return False
    return True


def _write_tracking(gate, entry, fields):
    if not re.fullmatch(r"[a-zA-Z0-9-]+", gate):
        return  # reject bogus gate names silently
    tracking_dir = os.environ.get("PROOF_DIR", ".quality/proof")
    tracking_file = os.path.join(tracking_dir, f"allow-tracking-{gate}.jsonl")
    entry_key = json.dumps(
        {k: v for k, v in entry.items() if k != "reason"}, sort_keys=True
    )
    record = {
        "gate": gate,
        "pattern": entry_pattern(entry),
        "file": fields.get("file", ""),
        "reason": entry.get("reason", ""),
        "entry_key": entry_key,
    }
    # Tracking is advisory; swallow OSError (unwritable dir, disk full) so a
    # matched-but-untrackable entry still returns exit 0 to the caller.
    # Lock (no-op on Windows) serializes concurrent writers.
    try:
        os.makedirs(tracking_dir, exist_ok=True)
        with open(tracking_file, "a") as tf:
            _lock(tf.fileno())
            try:
                tf.write(json.dumps(record) + "\n")
            finally:
                _unlock(tf.fileno())
    except OSError:
        pass


_MAX_CONFIG_BYTES = 1_000_000  # 1 MB cap on serialized allow config


def _load_safe_config(raw):
    """Return a dict from a raw JSON string, or None if malformed/oversized."""
    if len(raw) > _MAX_CONFIG_BYTES:
        return None
    try:
        config = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    return config if isinstance(config, dict) else None


def main(argv):
    allow_config = _load_safe_config(argv[1] if len(argv) > 1 else "")
    if allow_config is None:
        return 1
    gate = argv[2]
    entries = allow_config.get(gate, [])
    if not isinstance(entries, list) or not entries:
        return 1
    fields = _parse_fields(argv[3:])
    for entry in entries:
        if isinstance(entry, dict) and _entry_matches(entry, fields):
            _write_tracking(gate, entry, fields)
            return 0
    return 1


if __name__ == "__main__":  # pragma: no cover — exercised via subprocess
    sys.exit(main(sys.argv))
