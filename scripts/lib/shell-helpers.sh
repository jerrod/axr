#!/usr/bin/env bash
# scripts/lib/shell-helpers.sh — shared helpers for bin/ scripts.
#
# Sourced by bin/lint and bin/test so ANSI stripping and repo-root resolution
# stay consistent across gate scripts.

# strip_ansi — remove ANSI colour and cursor codes from tool output.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# cd_repo_root — resolve the git repo root (fallback: script's parent) and cd
# into it. Exits non-zero on failure.
cd_repo_root() {
    local root
    if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        cd "$root" || exit 1
    elif [ -n "${BASH_SOURCE[1]:-}" ]; then
        cd "$(dirname "${BASH_SOURCE[1]}")/.." || exit 1
    else
        cd "$PWD" || exit 1
    fi
}

# has_closed_frontmatter <file> — returns 0 if the file starts with --- and
# contains a closing --- on some later line; 1 otherwise.
has_closed_frontmatter() {
    local file="$1"
    [ "$(head -n1 "$file")" = "---" ] || return 1
    awk 'FNR>1 && /^---$/ {found=1; exit} END{exit !found}' "$file"
}
