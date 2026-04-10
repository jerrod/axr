#!/usr/bin/env bash
# Link a plan from ~/.claude/plans/<repo>/<slug>.md into .quality/plans/<slug>.md
# for workspace access. Idempotent — safe to call repeatedly.
#
# Usage:
#   link-plan.sh                    # link plan for current branch
#   link-plan.sh <branch-slug>      # link specific plan (slug, not branch name)
#
# Exit codes:
#   0 — symlink exists (created or already present)
#   0 — plan does not exist (silent skip — not an error)
#   1 — not in a git repo or other fatal error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$SCRIPT_DIR/git-helpers.sh"

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "link-plan: not in a git repository" >&2
  exit 1
}

# Determine slug: arg 1 or derive from current branch
if [ $# -ge 1 ] && [ -n "$1" ]; then
  plan_slug="$1"
else
  branch=$(git branch --show-current)
  plan_slug="${branch//\//-}"
fi

repo_name=$(get_repo_name)
canonical="$HOME/.claude/plans/$repo_name/$plan_slug.md"
workspace_dir="$repo_root/.quality/plans"
workspace_link="$workspace_dir/$plan_slug.md"

# No plan → silent skip
[ -f "$canonical" ] || exit 0

mkdir -p "$workspace_dir"

# If symlink already points at the canonical path, nothing to do
if [ -L "$workspace_link" ] && [ "$(readlink "$workspace_link")" = "$canonical" ]; then
  exit 0
fi

# If a regular file or broken symlink exists, back it up
if [ -e "$workspace_link" ] || [ -L "$workspace_link" ]; then
  mv "$workspace_link" "$workspace_link.bak.$$"
fi

ln -s "$canonical" "$workspace_link"
