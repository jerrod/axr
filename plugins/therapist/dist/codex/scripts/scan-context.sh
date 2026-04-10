#!/usr/bin/env bash
set -euo pipefail

# scan-context.sh — Scan all Claude context sources for rules relevant to a behavior
#
# Usage: bash scan-context.sh "keyword or phrase"
# Example: bash scan-context.sh "pre-existing"
#
# Scans: CLAUDE.md files, .claude/rules/, memory files, skill files, hooks

KEYWORD="${1:?Usage: scan-context.sh \"keyword or phrase\"}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

echo "=== Context Scan for: \"${KEYWORD}\" ==="
echo ""

# 1. Global CLAUDE.md
echo "--- Global CLAUDE.md ---"
if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
  grep -n -i -F -- "${KEYWORD}" "${HOME}/.claude/CLAUDE.md" 2>/dev/null || echo "(no matches)"
else
  echo "(not found)"
fi
echo ""

# 2. Project CLAUDE.md files
echo "--- Project CLAUDE.md files ---"
find "${REPO_ROOT}" -name "CLAUDE.md" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | while read -r f; do
  matches=$(grep -n -i -F -- "${KEYWORD}" "${f}" 2>/dev/null || true)
  if [[ -n "${matches}" ]]; then
    echo "${f}:"
    echo "${matches}"
    echo ""
  fi
done
echo "(scan complete)"
echo ""

# 3. Rules directories
echo "--- Rules files ---"
for rules_dir in "${REPO_ROOT}/.claude/rules" "${HOME}/.claude/rules"; do
  if [[ -d "${rules_dir}" ]]; then
    find "${rules_dir}" -name "*.md" 2>/dev/null | while read -r f; do
      matches=$(grep -n -i -F -- "${KEYWORD}" "${f}" 2>/dev/null || true)
      if [[ -n "${matches}" ]]; then
        echo "${f}:"
        echo "${matches}"
        echo ""
      fi
    done
  fi
done
echo "(scan complete)"
echo ""

# 4. Memory files
echo "--- Memory files ---"
find "${HOME}/.claude/projects" -name "*.md" -path "*/memory/*" 2>/dev/null | while read -r f; do
  matches=$(grep -n -i -F -- "${KEYWORD}" "${f}" 2>/dev/null || true)
  if [[ -n "${matches}" ]]; then
    echo "${f}:"
    echo "${matches}"
    echo ""
  fi
done
echo "(scan complete)"
echo ""

# 5. Active skills
echo "--- Skill files ---"
if [[ -d "${HOME}/.claude/skills" ]]; then
  find "${HOME}/.claude/skills" -name "SKILL.md" 2>/dev/null | while read -r f; do
    matches=$(grep -n -i -F -- "${KEYWORD}" "${f}" 2>/dev/null || true)
    if [[ -n "${matches}" ]]; then
      echo "${f}:"
      echo "${matches}"
      echo ""
    fi
  done
fi
echo "(scan complete)"
echo ""

# 6. Hooks and settings
echo "--- Hooks and settings ---"
for settings_file in "${HOME}/.claude/settings.json" "${REPO_ROOT}/.claude/settings.json"; do
  if [[ -f "${settings_file}" ]]; then
    matches=$(grep -n -i -F -- "${KEYWORD}" "${settings_file}" 2>/dev/null || true)
    if [[ -n "${matches}" ]]; then
      echo "${settings_file}:"
      echo "${matches}"
      echo ""
    fi
  fi
done
find "${REPO_ROOT}" -name "hooks.json" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | while read -r f; do
  matches=$(grep -n -i -F -- "${KEYWORD}" "${f}" 2>/dev/null || true)
  if [[ -n "${matches}" ]]; then
    echo "${f}:"
    echo "${matches}"
    echo ""
  fi
done
echo "(scan complete)"
echo ""

echo "=== Scan Complete ==="
