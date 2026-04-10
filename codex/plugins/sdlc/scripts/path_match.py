"""Glob pattern matching with gitignore-adjacent semantics.

Used by is_allowed_check.py and by threshold-helpers.sh inline python3 -c
blocks (via sys.path insertion + import). Single source of truth for path_match.

Semantics:
  *            matches within a single path segment (does NOT cross /)
  ?            matches a single character within a segment (not /)
  **/          matches zero or more path segments (including root)
  **           (no trailing /) matches anything including /
  bare pattern without / -> matches basename at any depth
  pattern with /         -> matches full path from root
"""

import re


def _glob_to_regex(pattern):
    parts = []
    i = 0
    while i < len(pattern):
        if pattern[i : i + 3] == "**/":
            # .+ (not .*) so a leading / doesn't match via empty-.* + literal /
            parts.append("(?:.+/)?")
            i += 3
        elif pattern[i : i + 2] == "**":
            parts.append(".*")
            i += 2
        elif pattern[i] == "*":
            parts.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            parts.append("[^/]")
            i += 1
        else:
            parts.append(re.escape(pattern[i]))
            i += 1
    return "^" + "".join(parts) + "$"


def path_match(path, pattern):
    if "/" not in pattern:
        basename = path.rsplit("/", 1)[-1]
        return bool(re.match(_glob_to_regex(pattern), basename))
    return bool(re.match(_glob_to_regex(pattern), path))
