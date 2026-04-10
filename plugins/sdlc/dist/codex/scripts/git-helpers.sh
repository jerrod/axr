#!/usr/bin/env bash
# Lightweight git helpers for sdlc scripts.
# Sourced by scripts that need repo/branch resolution without load-config.sh overhead.

# get_repo_name — resolve the canonical repository name from the git remote URL.
# Directory names are unreliable (clones can use any name, worktrees use random names).
# The remote URL is the single source of truth for the repo identity.
get_repo_name() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || url=""
  if [ -n "$url" ]; then
    # Strip .git suffix, then take the last path component
    # Handles: https://github.com/org/repo.git, git@github.com:org/repo.git, /local/path/repo
    url="${url%.git}"
    basename "$url"
    return 0
  fi
  # No remote — fall back to directory name (local-only repos)
  basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
}
