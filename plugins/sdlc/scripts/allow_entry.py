"""Shared helpers for allow-list entry introspection.

Used by is_allowed_check.py and report_unused_entries.py to extract
the "display pattern" from an entry — the identifying field that
gets written into tracking records and stale-entry warnings.

Keeping this in one place avoids the DRY violation where the same
four-level fallback chain has to be updated in two files whenever a
new entry-type field is added to the schema.
"""

from __future__ import annotations

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
