#!/usr/bin/env bash
# Post the associated implementation plan as a top-level PR comment.
#
# Inputs:
#   $PR_NUMBER — the PR number to comment on (required, from environment)
#
# Output: one summary line on stdout — one of:
#   "Plan comment: posted"
#   "Plan comment: already present (skipped)"
#   "Plan comment: no plan file found"
#   "Plan comment: post failed (non-fatal)"
#   "Plan comment: PR_NUMBER not set"
#
# Plan discovery: ~/.claude/plans/<repo>/<branch-slug>.md (physical location,
# survives repo deletion) with a symlink at .quality/plans/<slug>.md for
# workspace-proximity. Plans are private workflow artifacts — never committed.
# Slug format: branch name with / replaced by -.
#
# Dedup guard: skips if a comment starting with <!-- sdlc-plan --> already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$SCRIPT_DIR/git-helpers.sh"

if [ -z "${PR_NUMBER:-}" ]; then
  echo "Plan comment: PR_NUMBER not set"
  exit 0
fi

# Per-invocation temp files (avoid /tmp race + symlink attacks)
sdlc_plan_body_md=$(mktemp)
sdlc_plan_body_json=$(mktemp)
trap 'rm -f "$sdlc_plan_body_md" "$sdlc_plan_body_json"' EXIT

# 1. Plan discovery: ~/.claude/plans/<repo>/<slug>.md is the physical location.
#    .quality/plans/<slug>.md is a symlink — both resolve to the same file.
repo_name=$(get_repo_name)
branch=$(git branch --show-current)
plan_slug="${branch//\//-}"
plan_file="$HOME/.claude/plans/$repo_name/$plan_slug.md"

if [ ! -f "$plan_file" ]; then
  echo "Plan comment: no plan file found"
  exit 0
fi

# Ensure the workspace symlink exists (idempotent)
bash "$SCRIPT_DIR/link-plan.sh" "$plan_slug" 2>/dev/null || true

# 2. Dedup guard — skip if sdlc-plan comment already exists on this PR
existing=$(gh api "repos/{owner}/{repo}/issues/$PR_NUMBER/comments" --paginate |
  jq -r '.[] | select(.body | startswith("<!-- sdlc-plan -->")) | .id' | head -1)
if [ -n "$existing" ]; then
  echo "Plan comment: already present (skipped)"
  exit 0
fi

# 3. Extract goal (prefer **Goal:** line, fall back to first # heading)
goal=$(grep -m1 '^\*\*Goal:\*\*' "$plan_file" | sed 's/^\*\*Goal:\*\* *//')
if [ -z "$goal" ]; then
  goal=$(grep -m1 '^# ' "$plan_file" | sed 's/^# *//')
fi

# 4. Compute per-task completion status
# A task (### Task N: ...) is complete when every - [ ]/- [x] under it is checked,
# OR when it has no checkboxes (narrative-only task).
task_lines=$(awk '
  /^### Task / {
    if (task != "") {
      complete = (boxes == 0 || done_boxes == boxes) ? "x" : " "
      printf "- [%s] %s\n", complete, task
    }
    task = $0
    sub(/^### /, "", task)
    boxes = 0; done_boxes = 0
    next
  }
  /^## / {
    if (task != "") {
      complete = (boxes == 0 || done_boxes == boxes) ? "x" : " "
      printf "- [%s] %s\n", complete, task
      task = ""
    }
    next
  }
  /^[[:space:]]*- \[[x ]\]/ {
    if (task != "") {
      boxes++
      if (/\[x\]/) done_boxes++
    }
  }
  END {
    if (task != "") {
      complete = (boxes == 0 || done_boxes == boxes) ? "x" : " "
      printf "- [%s] %s\n", complete, task
    }
  }
' "$plan_file")
total=$(echo "$task_lines" | grep -c '^- \[' || true)
done_tasks=$(echo "$task_lines" | grep -c '^- \[x\]' || true)

# 5. Build status badge
if [ "$total" -eq 0 ]; then
  badge="📋 plan present"
elif [ "$done_tasks" -eq "$total" ]; then
  badge="✅ $done_tasks/$total tasks complete"
else
  badge="⚠ $done_tasks/$total tasks complete"
fi

# 6. Strip front matter (Branch/Created/Updated/Adopted-From lines before first # heading)
stripped=$(awk '
  !seen_heading && /^#/ { seen_heading = 1 }
  seen_heading { print; next }
  /^(Branch|Created|Updated|Adopted-From|Issue|Parent-Issue):/ { next }
  { print }
' "$plan_file" | sed '/./,$!d')

# 7. Truncate to 60k chars at a safe boundary if needed.
# Uses line-based cuts (head -n) to stay UTF-8 safe — byte offsets from
# grep -b can split multibyte characters and corrupt the output.
if [ "${#stripped}" -gt 60000 ]; then
  cut="${stripped:0:60000}"
  last_heading=$(printf '%s' "$cut" | grep -n '^## ' | tail -1 | cut -d: -f1)
  if [ -n "$last_heading" ] && [ "$last_heading" -gt 1 ]; then
    cut=$(printf '%s' "$cut" | head -n $((last_heading - 1)))
  else
    last_para=$(printf '%s' "$cut" | grep -n '^$' | tail -1 | cut -d: -f1)
    if [ -n "$last_para" ] && [ "$last_para" -gt 1 ]; then
      cut=$(printf '%s' "$cut" | head -n $((last_para - 1)))
    fi
  fi
  stripped="$cut"$'\n\n'"> [Plan truncated at 60k chars. Full plan is larger than GitHub's comment limit.]"
fi

# 8. Assemble the comment body
{
  echo "<!-- sdlc-plan -->"
  echo "## Implementation Plan"
  echo
  echo "**Goal:** ${goal:-<no goal found>}"
  echo "**Status:** $badge"
  echo
  echo "$task_lines"
  echo
  echo "<details><summary>Full plan</summary>"
  echo
  echo "$stripped"
  echo
  echo "</details>"
} >"$sdlc_plan_body_md"

# 9. Post via JSON input (sidesteps shell quoting for arbitrary content)
jq -Rs '{body: .}' <"$sdlc_plan_body_md" >"$sdlc_plan_body_json"
if gh api "repos/{owner}/{repo}/issues/$PR_NUMBER/comments" \
  -X POST --input "$sdlc_plan_body_json" >/dev/null; then
  echo "Plan comment: posted"
else
  echo "Plan comment: post failed (non-fatal)"
fi
