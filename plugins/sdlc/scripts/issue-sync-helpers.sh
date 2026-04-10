#!/usr/bin/env bash
# Helpers for issue-sync.sh — guards, parsing, canonicalization, validation.
# Sourced by issue-sync.sh; not meant to be executed directly.
# shellcheck disable=SC2034  # vars defined here are consumed by sourcing script

# ─── Temp file registry ─────────────────────────────────────────

_SDLC_TMPFILES=()
_sdlc_cleanup() {
  local f
  for f in "${_SDLC_TMPFILES[@]}"; do
    rm -f "$f"
  done
}

# Compose with any existing EXIT trap — preserve caller's cleanup.
#
# Trust assumption: the prior EXIT trap is captured from whatever code
# sourced this helper. In normal use that is trusted SDLC plumbing setting
# a simple cleanup function name. We do NOT want to blindly eval an
# arbitrary trap body — if untrusted code ran before this helper was
# sourced, its trap string would otherwise be re-executed verbatim on
# every chained EXIT. _sdlc_eval_prior_trap below allowlists the shape
# of trap bodies we are willing to re-run (defense-in-depth).
_SDLC_PRIOR_EXIT_TRAP=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- '(.*)' EXIT$/\\1/")

# _sdlc_eval_prior_trap: re-runs a previously-captured EXIT trap body iff
# it matches a known-safe shape. Known-safe = empty, or a sequence of
# function-name-like tokens (alphanumeric, underscore, colon) optionally
# separated by `;`. Anything containing shell metacharacters that could
# expand subshells, command substitutions, redirections, or pipelines is
# refused with a stderr warning. Returns 0 on safe-eval-or-empty, 1 on
# refusal so callers can detect tampering if they care.
_sdlc_eval_prior_trap() {
  local prior="$1"
  if [ -z "$prior" ]; then
    return 0
  fi
  case "$prior" in
    *[\$\`\(\)\<\>\&\|]*)
      echo "issue-sync-helpers: refusing to eval prior trap with shell metacharacters: $prior" >&2
      return 1
      ;;
  esac
  # shellcheck disable=SC2294  # intentional eval of allowlisted trap body
  eval "$prior"
}

_sdlc_cleanup_chained() {
  _sdlc_cleanup
  _sdlc_eval_prior_trap "$_SDLC_PRIOR_EXIT_TRAP" || true
  return 0
}
trap _sdlc_cleanup_chained EXIT

_sdlc_mktemp() {
  local f
  f=$(mktemp)
  _SDLC_TMPFILES+=("$f")
  echo "$f"
}

# ─── Canonicalization (symlink TOCTOU mitigation) ───────────────

_canonicalize_plan_file() {
  local p="$1"
  [ -z "$p" ] && return 1
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null || echo "$p"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
      "$p" 2>/dev/null || echo "$p"
  fi
}

# ─── Validation ─────────────────────────────────────────────────

_is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_is_owner_repo() {
  local val="${1:-}"
  [[ "$val" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  local owner="${val%%/*}" repo="${val#*/}"
  case "$owner" in . | ..) return 1 ;; esac
  case "$repo" in . | ..) return 1 ;; esac
  return 0
}

# ─── Guards ─────────────────────────────────────────────────────

check_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "WARNING: gh not authenticated — skipping issue sync" >&2
    exit 0
  fi
}

check_config_opt_out() {
  local git_root config_file
  git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  config_file="$git_root/sdlc.config.json"
  if [ -f "$config_file" ]; then
    local val
    val=$(jq -r 'if .github_issues == false then "false" else "true" end' \
      "$config_file" 2>/dev/null || echo "true")
    if [ "$val" = "false" ]; then
      exit 0
    fi
  fi
}

# ─── Plan parsing helpers ───────────────────────────────────────

read_issue_ref() {
  local plan_file="$1"
  grep -m1 '^Issue:' "$plan_file" 2>/dev/null |
    sed 's|^Issue:[[:space:]]*||' || true
}

extract_title() {
  local plan_file="$1"
  grep -m1 '^# ' "$plan_file" | sed 's|^#[[:space:]]*||'
}

extract_goal() {
  local plan_file="$1"
  grep -m1 '^\*\*Goal:\*\*' "$plan_file" |
    sed 's|^\*\*Goal:\*\*[[:space:]]*||' || true
}

extract_checkboxes() {
  local plan_file="$1"
  grep -E '^\s*-\s*\[[ xX]\]' "$plan_file" || true
}

# ─── Issue body builder ─────────────────────────────────────────

build_issue_body() {
  local plan_file="$1"
  local goal branch checkboxes
  goal=$(extract_goal "$plan_file")
  branch=$(git branch --show-current 2>/dev/null || echo "unknown")
  checkboxes=$(extract_checkboxes "$plan_file")

  local body=""
  body+="<!-- sdlc-issue-body -->"$'\n'
  [ -n "$goal" ] && body+="**Goal:** $goal"$'\n\n'
  body+="**Branch:** \`$branch\`"$'\n\n'
  if [ -n "$checkboxes" ]; then
    body+="## Progress"$'\n\n'
    body+="$checkboxes"$'\n\n'
  fi
  body+="<details><summary>Full plan</summary>"$'\n\n'
  body+="$(cat "$plan_file")"$'\n\n'
  body+="</details>"
  echo "$body"
}

# Inject a header field into the plan file. If an `Updated:` anchor line
# is present, insert after it. Otherwise, append at EOF so the field is
# never silently dropped (F2).
inject_header_field() {
  local plan_file="$1" field="$2" value="$3"
  local tmpf
  tmpf=$(_sdlc_mktemp)
  local injected=0
  while IFS= read -r line; do
    echo "$line" >>"$tmpf"
    if [ "$injected" -eq 0 ] && echo "$line" | grep -qE '^Updated:'; then
      echo "$field: $value" >>"$tmpf"
      injected=1
    fi
  done <"$plan_file"
  if [ "$injected" -eq 0 ]; then
    echo "$field: $value" >>"$tmpf"
  fi
  cat "$tmpf" >"$plan_file"
}
