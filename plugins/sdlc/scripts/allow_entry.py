"""Shared helpers for allow-list entry introspection.

Used by is_allowed_check.py, render_exceptions.py, and
report_unused_entries.py to extract the "display pattern" from an
entry and to compute its canonical identity key.

Keeping this in one place avoids DRY violations where the same logic
has to be updated in multiple files whenever a new entry-type field
is added to the schema.
"""

from __future__ import annotations

import json

# Order matters: first non-reason, non-empty key from this list wins.
# Matches the sdlc-config.json schema's allow.* entry shapes.
_PATTERN_KEYS = ("file", "pattern", "branch", "type")


def entry_pattern(entry):
    """Return the identifying pattern of an allow entry.

    Walks the canonical key chain (file → pattern → branch → type) and
    returns the first non-empty value found. Returns "" if the entry
    has none of these fields (a reason-only entry).
    """
    for key in _PATTERN_KEYS:
        value = entry.get(key, "")
        if value:
            return value
    return ""


def entry_key(entry):
    """Return the canonical identity key for an allow-list entry.

    All non-reason fields, JSON-serialized with sorted keys. Mirrors
    is_allowed_check.py's key generation so multi-field entries (e.g.,
    dead-code {file, name, type}) that share the same `file` but differ
    on `name` are still distinguished.
    """
    return json.dumps(
        {k: v for k, v in entry.items() if k != "reason"}, sort_keys=True
    )
