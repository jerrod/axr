#!/usr/bin/env bash
# Shared: Discover monorepo project roots from changed files
# Usage: source this file, then call discover_subproject_roots
# Returns project root paths via DISCOVERED_ROOTS array
set -uo pipefail

# Find the nearest project root for a directory by walking up
# Checks for all known package managers and build tools
find_nearest_project_root() {
  local dir="$1"
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  while [ "$dir" != "$git_root" ] && [ "$dir" != "/" ]; do
    # JS/TS: package.json, deno.json
    # Python: pyproject.toml, setup.cfg, setup.py, Pipfile
    # Go: go.mod
    # Rust: Cargo.toml
    # Ruby: Gemfile
    # Java/Kotlin: build.gradle, build.gradle.kts, pom.xml
    # Elixir: mix.exs
    # Also: tsconfig.json (standalone TS project without package.json)
    if [ -f "$dir/package.json" ] || [ -f "$dir/deno.json" ] ||
      [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.cfg" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/Pipfile" ] ||
      [ -f "$dir/go.mod" ] || [ -f "$dir/Cargo.toml" ] || [ -f "$dir/Gemfile" ] ||
      [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ] || [ -f "$dir/pom.xml" ] ||
      [ -f "$dir/mix.exs" ] || [ -f "$dir/tsconfig.json" ]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
}

# Discover all unique subproject roots that contain changed files
# Excludes $PWD (the root project, already handled by the calling gate)
# Sets DISCOVERED_ROOTS array
discover_subproject_roots() {
  local default_branch="${1:-main}"
  DISCOVERED_ROOTS=()
  local checked_roots=("$PWD")

  local changed_dirs
  changed_dirs=$(git diff --name-only --diff-filter=ACMR "$default_branch"...HEAD 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort -u || true)
  [ -z "$changed_dirs" ] && return

  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    local project_root
    project_root=$(find_nearest_project_root "$(cd "$dir" && pwd)")
    [ -z "$project_root" ] && continue

    local already_checked=0
    local checked
    for checked in "${checked_roots[@]}"; do
      [ "$project_root" = "$checked" ] && already_checked=1 && break
    done
    [ $already_checked -eq 1 ] && continue

    checked_roots+=("$project_root")
    DISCOVERED_ROOTS+=("$project_root")
  done <<<"$changed_dirs"
}
