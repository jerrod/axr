#!/usr/bin/env bash
# Plan Find: Locate plans for the current repo and branch
#
# Searches ~/.claude/plans/ using multiple strategies:
# 1. Exact path match: plans/$repo/$branch.md
# 2. Branch field match: any plan with "Branch: $branch"
# 3. Repo directory listing: all plans under plans/$repo/
# 4. Search term match: grep across all plans
# 5. Claude-native plans: random-word filenames at plans root
#
# Usage: plan-find.sh [search-term]
set -euo pipefail

search="${1:-}"
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-helpers.sh"
repo_name=$(get_repo_name)
branch=$(git branch --show-current 2>/dev/null || echo "unknown")
plans_dir="$HOME/.claude/plans"

echo "Searching for plans..."
echo "  Repo: $repo_name"
echo "  Branch: $branch"
echo ""

found=0

# 1. Exact match: plans/$repo/$branch.md
exact="$plans_dir/$repo_name/$branch.md"
if [ -f "$exact" ]; then
  echo "EXACT MATCH:"
  echo "  $exact"
  found=$((found + 1))
  echo ""
fi

# 2. Branch field match
branch_matches=$(grep -rl "Branch: $branch" "$plans_dir" 2>/dev/null || true)
if [ -n "$branch_matches" ]; then
  echo "BRANCH FIELD MATCH:"
  while IFS= read -r match; do
    [ "$match" = "$exact" ] && continue
    echo "  $match"
    found=$((found + 1))
  done <<<"$branch_matches"
  echo ""
fi

# 3. Repo directory plans
if [ -d "$plans_dir/$repo_name" ]; then
  echo "PLANS FOR $repo_name:"
  find "$plans_dir/$repo_name" -name "*.md" -type f 2>/dev/null | while read -r plan; do
    [ "$plan" = "$exact" ] && continue
    plan_title=$(head -5 "$plan" | grep -m1 '^#' | sed 's/^#\+\s*//')
    echo "  $plan — $plan_title"
  done
  echo ""
fi

# 4. Search term match (if provided)
if [ -n "$search" ]; then
  echo "SEARCH \"$search\":"
  grep -rl "$search" "$plans_dir" 2>/dev/null | while read -r match; do
    match_title=$(head -5 "$match" | grep -m1 '^#' | sed 's/^#\+\s*//')
    echo "  $match — $match_title"
  done
  echo ""
fi

# 5. Recent Claude-native plans (random-word filenames at root level)
native_plans=$(find "$plans_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | head -10)
if [ -n "$native_plans" ]; then
  echo "RECENT CLAUDE-NATIVE PLANS:"
  while IFS= read -r plan; do
    plan_title=$(head -5 "$plan" | grep -m1 '^#' | sed 's/^#\+\s*//')
    plan_date=$(stat -f "%Sm" -t "%Y-%m-%d" "$plan" 2>/dev/null || stat -c "%y" "$plan" 2>/dev/null | cut -d' ' -f1)
    echo "  $plan — $plan_title ($plan_date)"
  done <<<"$native_plans"
  echo ""
fi

[ "$found" -eq 0 ] && [ -z "$native_plans" ] && echo "No plans found."
