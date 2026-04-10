#!/usr/bin/env bash
# Gate: Performance — detects common performance anti-patterns in source code
# Produces: .quality/proof/performance.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-performance.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/performance.json" <<CRASHJSON
{
  "gate": "performance",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "summary": {"critical": 0, "high": 0, "medium": 0, "advisory": 0},
  "findings": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/performance.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

# ─── Language detection ───────────────────────────────────────────
# These LANG_* vars are read by gate-performance-patterns.sh (sourced below)
LANG_JS=false
LANG_TS=false
LANG_PY=false
LANG_RB=false
LANG_GO=false
LANG_JAVA=false

[ -f "package.json" ] && LANG_JS=true
[ -f "tsconfig.json" ] && LANG_TS=true
[ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ] && LANG_PY=true
[ -f "Gemfile" ] && LANG_RB=true
[ -f "go.mod" ] && LANG_GO=true
[ -f "pom.xml" ] || [ -f "build.gradle" ] && LANG_JAVA=true

# Also detect from file extensions in changed files
_ext_check=$(git diff --name-only "$SDLC_DEFAULT_BRANCH"...HEAD 2>/dev/null || git diff --cached --name-only 2>/dev/null || true)
echo "$_ext_check" | grep -qE '\.(js|jsx)$' && LANG_JS=true
echo "$_ext_check" | grep -qE '\.(ts|tsx)$' && LANG_TS=true
echo "$_ext_check" | grep -qE '\.py$' && LANG_PY=true
echo "$_ext_check" | grep -qE '\.rb$' && LANG_RB=true
echo "$_ext_check" | grep -qE '\.go$' && LANG_GO=true
echo "$_ext_check" | grep -qE '\.(java|kt)$' && LANG_JAVA=true

export LANG_JS LANG_TS LANG_PY LANG_RB LANG_GO LANG_JAVA

# ─── Source file collection ───────────────────────────────────────
# Get changed source files excluding tests, vendor, node_modules
CHANGED_FILES=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD \
  -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' \
  2>/dev/null ||
  git diff --cached --name-only --diff-filter=ACMR \
    -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' \
    2>/dev/null || true)

# Filter out test/vendor/node_modules paths
CHANGED_FILES=$(echo "$CHANGED_FILES" | grep -vE '(test|spec|__tests__|vendor|node_modules|\.min\.)' || true)

# ─── Finding helpers ──────────────────────────────────────────────
FINDINGS=()

add_finding() {
  local severity="$1"
  local file="$2"
  local line="$3"
  local pattern_type="$4"
  local message="$5"
  FINDINGS+=("{\"severity\":\"$severity\",\"file\":\"$file\",\"line\":$line,\"type\":\"$pattern_type\",\"message\":\"$message\"}")
}

# ─── Universal pattern checks ─────────────────────────────────────

if [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Sleep in production code (hardcoded delays are almost always wrong)
    SLEEP_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
pattern = re.compile(r'\b(time\.sleep|sleep\(|Thread\.sleep|await asyncio\.sleep|setTimeout|setInterval)\s*\(')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if stripped.startswith(('#', '//', '*')):
        continue
    if pattern.search(line):
        print(i)
" "$file" 2>/dev/null || true)

    if [ -n "$SLEEP_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "line=$lineno" "type=sleep_in_production" && continue
        add_finding "medium" "$file" "$lineno" "sleep_in_production" "Hardcoded sleep/delay — prefer event-driven or retry logic"
      done <<<"$SLEEP_LINES"
    fi

    # String concatenation in loops (+=  with strings inside for/while)
    CONCAT_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
loop_depth = 0
loop_keywords = re.compile(r'^\s*(for |foreach |while |do\s*\{)')
concat_pattern = re.compile(r'\+=\s*[\"\\']|\bstr\s*\+=|\bresult\s*\+=\s*[\"\\']|\bhtml\s*\+=|\bsql\s*\+=|\boutput\s*\+=\s*[\"\\']')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if loop_keywords.match(line):
        loop_depth += 1
    if loop_depth > 0 and ('{' in line or ':' == stripped[-1:] or 'do' in stripped):
        pass
    if loop_depth > 0 and concat_pattern.search(line):
        print(i)
    if '}' in line or (stripped == 'end' or stripped.startswith('end ')):
        if loop_depth > 0:
            loop_depth -= 1
" "$file" 2>/dev/null || true)

    if [ -n "$CONCAT_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "line=$lineno" "type=string_concat_in_loop" && continue
        add_finding "high" "$file" "$lineno" "string_concat_in_loop" "String concatenation in loop — use array join or string builder"
      done <<<"$CONCAT_LINES"
    fi

    # Unbounded collection building in loops (appending to array/list without size limit)
    UNBOUNDED_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
loop_depth = 0
loop_start_lines = []
loop_keywords = re.compile(r'^\s*(for |foreach |while )')
append_pattern = re.compile(r'\.(push|append|add|insert|concat)\s*\(|FINDINGS\s*\+=|\bpush\b\s*\(')
for i, line in enumerate(lines, 1):
    if loop_keywords.match(line):
        loop_depth += 1
        loop_start_lines.append(i)
    if loop_depth > 0 and append_pattern.search(line):
        print(i)
    stripped = line.strip()
    if stripped in ('}', 'end', 'done') or stripped.startswith('end '):
        if loop_depth > 0:
            loop_depth -= 1
            if loop_start_lines:
                loop_start_lines.pop()
" "$file" 2>/dev/null || true)

    if [ -n "$UNBOUNDED_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "line=$lineno" "type=unbounded_collection_in_loop" && continue
        add_finding "advisory" "$file" "$lineno" "unbounded_collection_in_loop" "Unbounded collection growth in loop — verify size is bounded"
      done <<<"$UNBOUNDED_LINES"
    fi

    # Nested loops over same collection (O(n²) patterns)
    NESTED_LOOP_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()

# Track loop variables and detect reuse in nested loops
loop_stack = []
loop_var_pattern = re.compile(r'for\s+(\w+)\s+in\s+(\w+)|for\s*\(\s*\w+\s+(\w+)\s*:\s*(\w+)')
for i, line in enumerate(lines, 1):
    m = loop_var_pattern.search(line)
    if m:
        groups = [g for g in m.groups() if g]
        if len(groups) >= 2:
            var_name, collection = groups[0], groups[1]
        else:
            var_name, collection = groups[0], ''
        # Check if this collection is already being iterated in an outer loop
        outer_collections = [c for _, c in loop_stack]
        if collection and collection in outer_collections:
            print(i)
        loop_stack.append((var_name, collection))
    stripped = line.strip()
    if stripped in ('}', 'end', 'done') or stripped.startswith('end '):
        if loop_stack:
            loop_stack.pop()
" "$file" 2>/dev/null || true)

    if [ -n "$NESTED_LOOP_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "line=$lineno" "type=nested_loop_same_collection" && continue
        add_finding "high" "$file" "$lineno" "nested_loop_same_collection" "Nested loop over same collection — O(n²) complexity, consider a set/map lookup"
      done <<<"$NESTED_LOOP_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi

# ─── Language-specific patterns (sourced helper) ─────────────────
# shellcheck source=plugins/sdlc/scripts/gate-performance-patterns.sh
[ -f "$SCRIPT_DIR/gate-performance-patterns.sh" ] && source "$SCRIPT_DIR/gate-performance-patterns.sh"

# Clear crash trap — we made it past analysis, write proof normally
trap - ERR

# ─── Count findings by severity ──────────────────────────────────
COUNT_CRITICAL=0
COUNT_HIGH=0
COUNT_MEDIUM=0
COUNT_ADVISORY=0

for finding in "${FINDINGS[@]+"${FINDINGS[@]}"}"; do
  case "$finding" in
    *'"severity":"critical"'*) COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
    *'"severity":"high"'*) COUNT_HIGH=$((COUNT_HIGH + 1)) ;;
    *'"severity":"medium"'*) COUNT_MEDIUM=$((COUNT_MEDIUM + 1)) ;;
    *'"severity":"advisory"'*) COUNT_ADVISORY=$((COUNT_ADVISORY + 1)) ;;
  esac
done

# Fail on critical or high; warn on medium/advisory
GATE_STATUS="pass"
if [ $((COUNT_CRITICAL + COUNT_HIGH)) -gt 0 ]; then
  GATE_STATUS="fail"
fi

FINDINGS_JSON=""
if [ "${#FINDINGS[@]}" -gt 0 ]; then
  FINDINGS_JSON=$(printf '%s,' "${FINDINGS[@]}" | sed 's/,$//')
fi

cat >"$PROOF_DIR/performance.json" <<ENDJSON
{
  "gate": "performance",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "$GATE_STATUS",
  "error": null,
  "summary": {
    "critical": $COUNT_CRITICAL,
    "high": $COUNT_HIGH,
    "medium": $COUNT_MEDIUM,
    "advisory": $COUNT_ADVISORY
  },
  "findings": [${FINDINGS_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/performance.json"

report_unused_allow_entries performance

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint performance
  echo "GATE FAILED: Performance anti-patterns detected (critical=$COUNT_CRITICAL high=$COUNT_HIGH)" >&2
  exit 1
fi

if [ $((COUNT_MEDIUM + COUNT_ADVISORY)) -gt 0 ]; then
  echo "GATE PASSED with warnings: medium=$COUNT_MEDIUM advisory=$COUNT_ADVISORY" >&2
fi
