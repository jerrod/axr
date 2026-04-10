#!/usr/bin/env python3
"""Report allow-list entries that never matched during a gate run.

Invoked from bash report_unused_allow_entries() in threshold-helpers.sh.

Args:
  sys.argv[1]: JSON allow config (from $_SDLC_ALLOW_CONFIG)
  sys.argv[2]: gate name
  sys.argv[3]: path to allow-tracking-<gate>.jsonl

Entries are identified by canonical JSON key (all non-reason fields, sorted).
This distinguishes dead-code entries with the same file but different names.
"""

import json
import os
import sys

from allow_entry import entry_key, entry_pattern


def _load_matched(tracking_file):
    matched = set()
    if not os.path.isfile(tracking_file):
        return matched
    with open(tracking_file) as f:
        for line in f:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Name the local deliberately to avoid shadowing the
            # module-level `entry_key` function imported above.
            matched_key = rec.get("entry_key", "")
            if matched_key:
                matched.add(matched_key)
    return matched


def main(argv):
    allow_config = json.loads(argv[1])
    gate = argv[2]
    tracking_file = argv[3]
    all_entries = allow_config.get(gate, [])
    if not all_entries:
        return 0
    matched = _load_matched(tracking_file)
    for entry in all_entries:
        if entry_key(entry) in matched:
            continue
        pattern = entry_pattern(entry)
        if not pattern:
            continue
        sys.stderr.write(
            f"WARNING: allow-list entry never matched during {gate} gate "
            "— may be stale or misconfigured\n"
        )
        sys.stderr.write(f"  pattern: {pattern!r}\n")
        sys.stderr.write(f"  reason: {entry.get('reason', '')!r}\n")
    return 0


if __name__ == "__main__":  # pragma: no cover — exercised via subprocess
    sys.exit(main(sys.argv))
