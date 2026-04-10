#!/usr/bin/env bash
# Plan Progress: Track plan checkboxes with proof anchors.
# Every checked item in a plan MUST reference a checkpoint that proves
# the work was done. Subcommands: check, mark, status, adopt, find.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-.quality/checkpoints}"

ACTION="${1:-help}"
shift || true

# ─── Helpers ─────────────────────────────────────────────────────

# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-helpers.sh"
# shellcheck source=plugins/sdlc/scripts/plan-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan-helpers.sh"

get_branch() {
  git branch --show-current 2>/dev/null || echo "unknown"
}

latest_checkpoint_file() {
  # Find most recently modified checkpoint, not alphabetically first
  find "$CHECKPOINT_DIR" -name "*-latest.json" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1
}

# ─── mark: Check off an item with proof anchor ──────────────────

# Validate that the latest checkpoint is current and passing
validate_checkpoint() {
  local latest_cp
  latest_cp=$(latest_checkpoint_file)
  if [ -z "$latest_cp" ] || [ ! -f "$latest_cp" ]; then
    echo "ERROR: No checkpoint found. Run gates first:"
    echo "  bash plugins/sdlc/scripts/run-gates.sh build"
    echo "  bash plugins/sdlc/scripts/checkpoint.sh save build \"description\""
    exit 1
  fi

  local cp_sha
  cp_sha=$(CP_FILE="$latest_cp" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha','?'))" 2>/dev/null)
  local current_sha
  current_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  if [ "$cp_sha" != "$current_sha" ]; then
    echo "ERROR: Latest checkpoint is at SHA $cp_sha but HEAD is $current_sha"
    echo "Code has changed since last checkpoint. Re-run gates first."
    exit 1
  fi

  local cp_failed
  cp_failed=$(CP_FILE="$latest_cp" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
failed = d.get('failed', 0)
for p in d.get('proof_snapshot', []):
    if p.get('status') == 'fail':
        failed += 1
print(failed)
" 2>/dev/null || echo "1")

  if [ "$cp_failed" != "0" ]; then
    echo "ERROR: Latest checkpoint has failing gates. Fix and re-run before marking items done."
    exit 1
  fi

  echo "$latest_cp"
}

do_mark() {
  local plan_file="${1:-}"
  local item_search="${2:-}"
  [ -z "$plan_file" ] || [ -z "$item_search" ] && {
    echo "Usage: plan-progress.sh mark <plan-file> <search-text>"
    exit 1
  }
  [ ! -f "$plan_file" ] && {
    echo "Plan file not found: $plan_file"
    exit 1
  }

  # Fully resolve the plan file (symlinks + `..`) to get the canonical
  # absolute path, then verify it is inside the repo root or
  # ~/.claude/plans/. This prevents a malicious or accidental symlink
  # from redirecting writes outside expected boundaries, including
  # multi-hop chains and `..` traversal. See plan-helpers.sh.
  local canonical_plan repo_root plans_root
  canonical_plan=$(_resolve_plan_target "$plan_file")
  if [ -z "$canonical_plan" ]; then
    echo "ERROR: could not resolve canonical path for '$plan_file' (python3 required)"
    exit 1
  fi
  # Normalize roots via realpath so prefix comparison is consistent on
  # macOS (where /tmp → /private/tmp). Pipe through python3 stdin to
  # avoid xargs word-splitting on paths with embedded newlines.
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null |
    python3 -c 'import os,sys; p=sys.stdin.read().rstrip("\n"); print(os.path.realpath(p)) if p else print("")' \
      2>/dev/null || echo "")
  plans_root=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOME/.claude/plans" 2>/dev/null || echo "")
  if ! _plan_target_allowed "$canonical_plan" "$repo_root" "$plans_root"; then
    echo "ERROR: plan file resolves outside allowed roots: $canonical_plan"
    exit 1
  fi

  local latest_cp
  latest_cp=$(validate_checkpoint)
  local cp_basename cp_sha
  cp_basename=$(basename "$latest_cp" .json)
  cp_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  local matched=0
  local tmpfile
  tmpfile=$(mktemp)
  # EXIT trap cleans up tmpfile on any exit path (normal return, exit 1,
  # set -e trigger). RETURN would not fire on `exit 1` from a function.
  # shellcheck disable=SC2064 # intentional early expansion of $tmpfile
  trap "rm -f '$tmpfile'" EXIT

  while IFS= read -r line; do
    if [ "$matched" -eq 0 ] && echo "$line" | grep -qE '^\s*-\s*\[ \]' && echo "$line" | grep -qiF "$item_search"; then
      local updated
      updated="${line/\[ \]/[x]}"
      echo "${updated} <!-- proof: ${cp_basename} -->" >>"$tmpfile"
      matched=1
    else
      echo "$line" >>"$tmpfile"
    fi
  done <"$canonical_plan"

  if [ "$matched" -eq 0 ]; then
    echo "ERROR: No unchecked item matching \"$item_search\" found in plan"
    exit 1
  fi

  # Write directly to the canonical path — NOT to $plan_file. The canonical
  # was fully resolved and validated above; writing to it bypasses symlink
  # re-resolution by the kernel at open time, closing the TOCTOU window.
  cat "$tmpfile" >"$canonical_plan"
  echo "✓ Marked done: \"$item_search\" (proof: $cp_basename @ $cp_sha)"

  # Sync updated plan state to GitHub issue (non-blocking background)
  if [ -x "$SCRIPT_DIR/issue-sync.sh" ]; then
    "$SCRIPT_DIR/issue-sync.sh" update "$canonical_plan" 2>/dev/null &
  fi
}

# ─── status: Show plan progress summary ─────────────────────────

do_status() {
  local plan_file="${1:-}"
  [ -z "$plan_file" ] && {
    echo "Usage: plan-progress.sh status <plan-file>"
    exit 1
  }
  [ ! -f "$plan_file" ] && {
    echo "Plan file not found: $plan_file"
    exit 1
  }

  local total=0
  local done_count=0

  while IFS= read -r line; do
    if echo "$line" | grep -qE '^\s*-\s*\[[ xX]\]'; then
      total=$((total + 1))
      if echo "$line" | grep -qE '^\s*-\s*\[[xX]\]'; then
        done_count=$((done_count + 1))
      fi
    fi
  done <"$plan_file"

  if [ "$total" -eq 0 ]; then
    echo "No checkbox items in plan"
    exit 0
  fi

  local pct=$((done_count * 100 / total))
  local bar_width=30
  local filled=$((pct * bar_width / 100))
  local empty=$((bar_width - filled))
  local bar=""
  local _n
  for _n in $(seq 1 $filled 2>/dev/null); do bar="${bar}█"; done
  for _n in $(seq 1 $empty 2>/dev/null); do bar="${bar}░"; done

  echo "Plan: $(basename "$plan_file")"
  echo "[$bar] ${done_count}/${total} (${pct}%)"
  echo ""

  if [ "$done_count" -lt "$total" ]; then
    echo "Remaining:"
    grep -E '^\s*-\s*\[ \]' "$plan_file" | sed 's|^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*|  → |'
  fi
}

# ─── adopt: Convert a Claude-native plan to sdlc format ────────────
# write_adopted_plan lives in plan-helpers.sh (sourced above).

do_adopt() {
  local source="${1:-}"
  local target="${2:-}"
  [ -z "$source" ] && {
    echo "Usage: plan-progress.sh adopt <source-plan> [target-path]"
    exit 1
  }
  [ ! -f "$source" ] && {
    echo "Source plan not found: $source"
    exit 1
  }

  local repo_name branch
  repo_name=$(get_repo_name)
  branch=$(get_branch)

  if [ -z "$target" ]; then
    mkdir -p "$HOME/.claude/plans/$repo_name"
    target="$HOME/.claude/plans/$repo_name/$branch.md"
  fi

  if head -10 "$source" | grep -qE '^Branch:'; then
    echo "Source plan already has sdlc format."
    [ "$source" != "$target" ] && cp "$source" "$target" && echo "Copied to: $target"
    exit 0
  fi

  local title has_checkboxes source_basename
  title=$(head -5 "$source" | grep -m1 '^#' | sed 's|^#\{1,\}[[:space:]]*||')
  source_basename=$(basename "$source")
  has_checkboxes=$(write_adopted_plan "$source" "$target" "$branch")

  echo "✓ Plan adopted: $source → $target"
  echo "  Title: $title"
  echo "  Branch: $branch"
  echo "  Checkboxes found: $has_checkboxes"

  if [ "$has_checkboxes" -eq 0 ]; then
    echo ""
    echo "NOTE: Source plan has no checkboxes. Add an Implementation Plan section"
    echo "with checkboxes so sdlc:build can track progress with proof anchors."
  fi

  if [ "$source" != "$target" ] && echo "$source_basename" | grep -qE '^[a-z]+-[a-z]+-[a-z]+\.md$'; then
    echo ""
    echo "Original Claude-native plan preserved at: $source"
  fi

  # Create a tracking GitHub issue for this plan (non-blocking)
  if [ -x "$SCRIPT_DIR/issue-sync.sh" ]; then
    "$SCRIPT_DIR/issue-sync.sh" create "$target" 2>/dev/null || true
  fi
}

# ─── Dispatch ────────────────────────────────────────────────────

case "$ACTION" in
  check) bash "$SCRIPT_DIR/plan-check.sh" "$@" ;;
  mark) do_mark "$@" ;;
  status) do_status "$@" ;;
  adopt) do_adopt "$@" ;;
  find) bash "$SCRIPT_DIR/plan-find.sh" "$@" ;;
  *)
    echo "Usage: plan-progress.sh <check|mark|status|adopt|find> [args]"
    echo ""
    echo "Commands:"
    echo "  check <plan-file>            Verify all checked items have valid proof"
    echo "  mark <plan-file> <text>      Mark an item done with current checkpoint"
    echo "  status <plan-file>           Show plan progress summary"
    echo "  adopt <source> [target]      Adopt a Claude-native plan into sdlc format"
    echo "  find [search-term]           Find plans for current repo/branch"
    exit 1
    ;;
esac
