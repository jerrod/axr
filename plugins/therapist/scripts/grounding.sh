#!/usr/bin/env bash
# grounding.sh — Standalone reality-check script
#
# Runs actual measurements on the current project and presents facts.
# Not a hook — run manually during therapy sessions.
#
# Usage: bash grounding.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/_lib.sh"

echo "=== GROUNDING EXERCISE ==="
echo ""

# --- Recently modified files ---

show_recent_files() {
  echo "--- Recently Modified Files ---"
  local files
  files=$(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only HEAD 2>/dev/null || git diff --name-only 2>/dev/null || true)

  if [[ -z "$files" ]]; then
    echo "  No recently modified files detected."
    return
  fi

  local over_limit=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "$f" ]]; then
      local lines
      lines=$(wc -l <"$f" | tr -d ' ')
      local marker=""
      if [[ "$lines" -gt 300 ]]; then
        marker=" ** OVER 300 LIMIT **"
        over_limit=$((over_limit + 1))
      fi
      printf '  %4d lines  %s%s\n' "$lines" "$f" "$marker"
    fi
  done <<<"$files"

  if [[ "$over_limit" -gt 0 ]]; then
    echo ""
    echo "  Files over 300 lines: ${over_limit} (standard: 0)"
  fi
}

# --- TODO/FIXME/HACK count ---

show_debt_markers() {
  echo ""
  echo "--- Technical Debt Markers ---"
  local count
  count=$(grep -rn 'TODO\|FIXME\|HACK\|XXX' --include='*.sh' --include='*.py' \
    --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
    --exclude-dir=node_modules --exclude-dir=.git \
    . 2>/dev/null | grep -c '' || true)
  echo "  TODO/FIXME/HACK count: ${count}"
}

# --- Available tooling ---

show_tooling() {
  echo ""
  echo "--- Available Quality Tools ---"

  local tools_found=0
  for tool in bin/test bin/lint bin/typecheck bin/format bin/check; do
    if [[ -x "$tool" ]]; then
      echo "  [x] ${tool}"
      tools_found=$((tools_found + 1))
    fi
  done

  for config in package.json pyproject.toml Cargo.toml go.mod; do
    if [[ -f "$config" ]]; then
      echo "  [x] ${config} detected"
    fi
  done

  if [[ "$tools_found" -eq 0 ]]; then
    echo "  No bin/ quality tools found."
  fi
}

# --- Lint errors (if available) ---

show_lint_errors() {
  if [[ ! -x "bin/lint" ]]; then
    return
  fi

  echo ""
  echo "--- Lint Check ---"
  local lint_output
  lint_output=$(bin/lint 2>&1 || true)
  local error_count
  error_count=$(echo "$lint_output" | grep -ciE '(error|warning)' || true)
  if [[ "$error_count" -eq 0 ]]; then
    echo "  Lint: clean"
  else
    echo "  Lint issues detected: ~${error_count} line(s) with errors/warnings"
  fi
}

show_recent_files
show_debt_markers
show_tooling
show_lint_errors

echo ""
echo "The numbers do not care about feelings. Fix the gaps."
echo "=== END GROUNDING EXERCISE ==="
