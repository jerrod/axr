#!/usr/bin/env bash
# bin/lib/common.sh — shared helpers sourced by bin/validate, bin/lint, and the
# bin/lib/ validators. Pure functions only; no global state side effects.

# has_closed_frontmatter — returns 0 if the given markdown file starts with `---`
# and has a matching closing `---` later in the file.
has_closed_frontmatter() {
  local file="$1"
  [ "$(head -n1 "$file")" = "---" ] || return 1
  awk 'FNR>1 && /^---$/ {found=1; exit} END{exit !found}' "$file"
}
