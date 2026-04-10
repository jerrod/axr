#!/usr/bin/env bash
# Sync sdlc plan state to GitHub Issues.
# Subcommands: create, update, link-pr, link-parent
# Non-blocking — all failures warn to stderr and exit 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$SCRIPT_DIR/git-helpers.sh"
# shellcheck source=plugins/sdlc/scripts/issue-sync-helpers.sh
source "$SCRIPT_DIR/issue-sync-helpers.sh"

# ─── Subcommands ────────────────────────────────────────────────

do_create() {
  local plan_file="${1:-}"
  if [ -z "$plan_file" ] || [ ! -f "$plan_file" ]; then
    echo "Usage: issue-sync.sh create <plan-file>" >&2
    exit 0
  fi
  plan_file=$(_canonicalize_plan_file "$plan_file")

  local existing_ref
  existing_ref=$(read_issue_ref "$plan_file")
  if [ -n "$existing_ref" ]; then
    echo "$existing_ref"
    return 0
  fi

  local title body_file safe_title
  title=$(extract_title "$plan_file")
  [ -z "$title" ] && title="Implementation plan"
  # The title is rendered via gh under double-quotes, so $ and backtick
  # would trigger command substitution before gh ever sees the value.
  # Strip every shell-significant character, not just `"`.
  # Shell double-quote expansion processes `$`, backtick, `\`, and `"`, so
  # each of these can produce command substitution inside gh's invocation.
  local _strip=$'"$`\\'
  safe_title=$(printf '%s' "$title" | tr -d "$_strip")

  body_file=$(_sdlc_mktemp)
  build_issue_body "$plan_file" >"$body_file"

  local issue_url
  issue_url=$(gh issue create \
    --title "$safe_title" \
    --body-file "$body_file" \
    --assignee "@me" 2>/dev/null) || {
    echo "WARNING: failed to create issue" >&2
    return 0
  }

  local issue_number repo_name
  issue_number="${issue_url##*/}"
  repo_name=$(gh repo view --json nameWithOwner \
    -q '.nameWithOwner' 2>/dev/null || get_repo_name)
  local ref="$repo_name#$issue_number"

  inject_header_field "$plan_file" "Issue" "$ref"
  echo "$ref"
}

do_update() {
  local plan_file="${1:-}"
  if [ -z "$plan_file" ] || [ ! -f "$plan_file" ]; then
    echo "Usage: issue-sync.sh update <plan-file>" >&2
    exit 0
  fi
  plan_file=$(_canonicalize_plan_file "$plan_file")

  local issue_ref
  issue_ref=$(read_issue_ref "$plan_file")
  [ -z "$issue_ref" ] && return 0

  # Debounce: anchor marker to git root so background jobs spawned from
  # non-root CWDs still share the same throttle state (F4).
  local git_root sync_marker
  git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  sync_marker="$git_root/.quality/.issue-sync-last"
  mkdir -p "$git_root/.quality"
  if [ -f "$sync_marker" ]; then
    local last_sync now elapsed
    # GNU stat (Linux) uses -c %Y; BSD stat (macOS) uses -f %m.
    # Try GNU first, then BSD — opposite order misreads GNU's -f as
    # "filesystem info" and poisons last_sync with File:/ID:/... lines.
    last_sync=$(stat -c %Y "$sync_marker" 2>/dev/null ||
      stat -f %m "$sync_marker" 2>/dev/null || echo "0")
    # Guard against stat returning a non-numeric value (set -u + $((...))).
    case "$last_sync" in
      '' | *[!0-9]*) last_sync=0 ;;
    esac
    now=$(date +%s)
    elapsed=$((now - last_sync))
    if [ "$elapsed" -lt 30 ]; then
      return 0
    fi
  fi

  local owner_repo issue_number
  owner_repo="${issue_ref%#*}"
  issue_number="${issue_ref##*#}"
  if ! _is_integer "$issue_number"; then
    return 0
  fi
  if ! _is_owner_repo "$owner_repo"; then
    return 0
  fi

  local body body_json
  body=$(build_issue_body "$plan_file")
  body_json=$(_sdlc_mktemp)
  echo "$body" | jq -Rs '{body: .}' >"$body_json"

  gh api "repos/$owner_repo/issues/$issue_number" \
    -X PATCH --input "$body_json" >/dev/null 2>&1 || {
    echo "WARNING: failed to update issue $issue_ref" >&2
    return 0
  }

  touch "$sync_marker"
}

do_link_pr() {
  local plan_file="${1:-}" pr_number="${2:-}"
  if [ -z "$plan_file" ] || [ -z "$pr_number" ] || [ ! -f "$plan_file" ]; then
    echo "Usage: issue-sync.sh link-pr <plan-file> <pr-number>" >&2
    exit 0
  fi
  if ! _is_integer "$pr_number"; then
    echo "WARNING: invalid pr_number: $pr_number" >&2
    exit 0
  fi
  plan_file=$(_canonicalize_plan_file "$plan_file")

  local issue_ref
  issue_ref=$(read_issue_ref "$plan_file")
  [ -z "$issue_ref" ] && return 0

  local owner_repo issue_number
  owner_repo="${issue_ref%#*}"
  issue_number="${issue_ref##*#}"
  if ! _is_integer "$issue_number"; then
    return 0
  fi
  if ! _is_owner_repo "$owner_repo"; then
    return 0
  fi

  local pr_url
  pr_url=$(gh pr view "$pr_number" --json url \
    -q '.url' 2>/dev/null || echo "")

  local comment="PR #${pr_number} opened: ${pr_url}"
  echo "$comment" | jq -Rs '{body: .}' |
    gh api "repos/$owner_repo/issues/$issue_number/comments" \
      -X POST --input /dev/stdin >/dev/null 2>&1 || true

  # Cross-repo Closes keyword: GitHub only auto-closes when the Closes
  # keyword carries the owner/repo prefix if the issue lives in a
  # different repo than the PR (F5).
  local current_repo close_ref close_pattern
  current_repo=$(gh repo view --json nameWithOwner \
    -q '.nameWithOwner' 2>/dev/null || echo "")
  if [ "$owner_repo" = "$current_repo" ] || [ -z "$current_repo" ]; then
    close_ref="Closes #${issue_number}"
    close_pattern="Closes (${owner_repo}#|#)${issue_number}\\b"
  else
    close_ref="Closes ${owner_repo}#${issue_number}"
    close_pattern="Closes ${owner_repo}#${issue_number}\\b"
  fi

  local pr_body
  pr_body=$(gh pr view "$pr_number" --json body \
    -q '.body' 2>/dev/null || echo "")
  if ! echo "$pr_body" | grep -qE "$close_pattern"; then
    local close_line
    close_line=$'\n'"$close_ref"
    gh pr edit "$pr_number" \
      --body "${pr_body}${close_line}" 2>/dev/null || true
  fi
}

do_link_parent() {
  local plan_file="${1:-}" parent_ref="${2:-}"
  if [ -z "$plan_file" ] || [ -z "$parent_ref" ] || [ ! -f "$plan_file" ]; then
    echo "Usage: issue-sync.sh link-parent <plan-file> <parent-ref>" >&2
    exit 0
  fi
  plan_file=$(_canonicalize_plan_file "$plan_file")

  local child_ref
  child_ref=$(read_issue_ref "$plan_file")
  [ -z "$child_ref" ] && return 0

  local child_owner_repo child_number
  child_owner_repo="${child_ref%#*}"
  child_number="${child_ref##*#}"
  if ! _is_integer "$child_number"; then
    return 0
  fi
  if ! _is_owner_repo "$child_owner_repo"; then
    return 0
  fi

  local parent_owner_repo parent_number
  parent_owner_repo="${parent_ref%#*}"
  parent_number="${parent_ref##*#}"
  if ! _is_integer "$parent_number"; then
    return 0
  fi
  if ! _is_owner_repo "$parent_owner_repo"; then
    return 0
  fi

  local child_id
  child_id=$(gh api "repos/$child_owner_repo/issues/$child_number" \
    --jq '.id' 2>/dev/null || echo "")
  # Validate child_id is numeric before splicing into JSON (F6).
  if ! _is_integer "$child_id"; then
    echo "WARNING: unexpected child_id format: $child_id" >&2
    return 0
  fi

  local sub_json
  sub_json=$(_sdlc_mktemp)
  jq -n --argjson id "$child_id" '{sub_issue_id: $id}' >"$sub_json"

  if ! gh api "repos/$parent_owner_repo/issues/$parent_number/sub_issues" \
    -X POST \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    --input "$sub_json" >/dev/null 2>&1; then
    echo "WARNING: failed to link sub-issue to $parent_ref" >&2
    return 0
  fi

  # Inject header only after successful API call, and skip if already
  # present so retries don't duplicate the field (F8).
  if ! grep -q '^Parent-Issue:' "$plan_file"; then
    inject_header_field "$plan_file" "Parent-Issue" "$parent_ref"
  fi

  local xref="Parent: ${parent_ref}"
  echo "$xref" | jq -Rs '{body: .}' |
    gh api "repos/$child_owner_repo/issues/$child_number/comments" \
      -X POST --input /dev/stdin >/dev/null 2>&1 || true
}

# ─── Dispatch (guarded for sourcing) ───────────────────────────

# When sourced for testing, skip dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ACTION="${1:-help}"
  shift || true

  check_gh_auth
  check_config_opt_out

  case "$ACTION" in
    create) do_create "$@" ;;
    update) do_update "$@" ;;
    link-pr) do_link_pr "$@" ;;
    link-parent) do_link_parent "$@" ;;
    *)
      echo "Usage: issue-sync.sh <create|update|link-pr|link-parent> [args]"
      exit 1
      ;;
  esac
fi
