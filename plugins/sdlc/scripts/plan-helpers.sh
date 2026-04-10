#!/usr/bin/env bash
# Helpers for plan-progress.sh — plan-file path resolution and boundary
# enforcement. Sourced, not executed.
#
# These live in their own file so plan-progress.sh stays under the
# 300-line per-file gate. They are deliberately small and focused on
# path resolution — no git/checkpoint/filesystem mutation.

# Fully resolve $1 to an absolute, symlink-free, `..`-free path.
# Uses Python's os.path.realpath so the resolver handles multi-hop
# symlink chains AND normalizes `..` segments — both are required to
# prevent bypasses of the boundary check in _plan_target_allowed.
#
# Returns empty string on failure (file does not exist or python3 is
# unavailable). Callers treat empty as "reject".
_resolve_plan_target() {
  local path="$1"
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || echo ""
}

# Return 0 if $canonical is inside $repo_root OR $plans_root, 1 otherwise.
# Both roots may be empty; empty roots match nothing. $canonical MUST be
# the output of _resolve_plan_target (i.e., already normalized — no `..`,
# no symlink hops). The case-glob containment check is only reliable on
# normalized paths; unnormalized `/a/../b` would incorrectly match `/a/*`
# because bash `case` `*` matches `/` and `.` segments.
_plan_target_allowed() {
  local canonical="$1" repo_root="$2" plans_root="$3"
  [ -z "$canonical" ] && return 1
  if [ -n "$repo_root" ]; then
    case "$canonical" in "$repo_root"/*) return 0 ;; esac
  fi
  if [ -n "$plans_root" ]; then
    case "$canonical" in "$plans_root"/*) return 0 ;; esac
  fi
  return 1
}

# Write sdlc-format plan file from a source plan.
# Extracted from plan-progress.sh to keep that file under 300 lines.
# Args: $1=source $2=target $3=branch
# Stdout: number of checkboxes found in source (0 = no checkboxes).
write_adopted_plan() {
  local source="$1" target="$2" branch="$3"
  local today source_basename has_checkboxes
  today=$(date +%Y-%m-%d)
  source_basename=$(basename "$source")
  has_checkboxes=$(grep -cE '^\s*-\s*\[[ xX]\]' "$source" 2>/dev/null || echo "0")

  {
    echo "Branch: $branch"
    echo "Created: $today"
    echo "Updated: $today"
    echo "Adopted-From: $source_basename"
    echo ""
    cat "$source"

    if [ "$has_checkboxes" -eq 0 ]; then
      echo ""
      echo "## Implementation Plan"
      echo ""
      echo "<!-- Convert the phases/steps above into checkboxes. Example:"
      echo "- [ ] Step 1 description"
      echo "- [ ] Step 2 description"
      echo "-->"
    fi

    if ! grep -q '^## Progress' "$source"; then
      echo ""
      echo "## Progress"
      echo ""
      echo "Adopted from \`$source_basename\` on $today."
    fi
  } >"$target"

  echo "$has_checkboxes"
}
