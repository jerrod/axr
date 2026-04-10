#!/usr/bin/env bash
# check-mock-patterns.sh — scan staged files for banned mock/lint-suppression patterns.
# Codex equivalent of the sdlc PreToolUse(Write|Edit) prompt hook.
# Exit 0 = clean, exit 1 = violations found.
set -uo pipefail

BANNED_PATTERNS=(
    'jest\.mock\('
    'vi\.mock\('
    'spyOn\(.*\)\.mockImplementation\('
    'spyOn\(.*\)\.mockReturnValue\('
    'spyOn\(.*\)\.mockResolvedValue\('
    '@patch\('
    'unittest\.mock\.patch\('
    'jest\.fn\(\)\.mockReturnValue\('
    '# noqa'
    '# type: ignore'
    '// eslint-disable'
    '// eslint-disable-next-line'
    '@ts-ignore'
    '@ts-expect-error'
)

# Build combined regex
regex=$(IFS='|'; echo "${BANNED_PATTERNS[*]}")

# Check staged files only (null-delimited for filename safety)
violations=$(git diff --cached --name-only -z --diff-filter=ACM 2>/dev/null \
    | xargs -0 grep -nE "$regex" -- 2>/dev/null || true)

if [ -n "$violations" ]; then
    printf 'BLOCKED: Mock/lint-suppression patterns found in staged files:\n%s\n' "$violations"
    exit 1
fi

exit 0
