#!/usr/bin/env bash
# Gate: Dead Code — no unused imports, variables, functions, or commented-out code
# Produces: .quality/proof/dead-code.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"
# shellcheck source=plugins/sdlc/scripts/commands-config.sh
source "$SCRIPT_DIR/commands-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-dead-code.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/dead-code.json" <<CRASHJSON
{
  "gate": "dead-code",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/dead-code.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

# Check for explicit SARIF config
CMD_CONFIG=$(get_command "dead-code")
if [ -n "$CMD_CONFIG" ]; then
  parse_command_config "$CMD_CONFIG"

  if [ "$_CMD_FORMAT" = "sarif" ] && [ -n "$_CMD_REPORT" ]; then
    # Run command if specified (array-split, no eval)
    if [ -n "$_CMD_RUN" ]; then
      read -ra _cmd_array <<<"$_CMD_RUN"
      "${_cmd_array[@]}" >/dev/null 2>&1 || true
    fi

    # Parse SARIF for unused-code findings (multiple rule prefixes)
    read -r VIOLATION_COUNT VIO_JSON < <(python3 -c "
import json, sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
from parse_sarif import parse_sarif
prefixes = ['style/Unused', 'UnusedImport', 'UnusedPrivate']
findings = []
for p in prefixes:
    findings.extend(parse_sarif(sys.argv[2], rule_prefix=p))
seen = set()
deduped = []
for f in findings:
    key = (f['file'], f['line'], f['rule_id'])
    if key not in seen:
        seen.add(key)
        deduped.append({'type':'sarif_dead_code','file':f['file'],'line':f['line'],'rule':f['rule_id'],'message':f['message']})
print(len(deduped), json.dumps(deduped))
" "$SCRIPT_DIR/parse_sarif.py" "$_CMD_REPORT" 2>/dev/null || echo "0 []")

    GATE_STATUS="pass"
    if [ "$VIOLATION_COUNT" -gt 0 ] 2>/dev/null; then
      GATE_STATUS="fail"
    fi

    trap - ERR
    cat >"$PROOF_DIR/dead-code.json" <<ENDJSON
{
  "gate": "dead-code",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "source": "sarif",
  "violations": $VIO_JSON,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
    cat "$PROOF_DIR/dead-code.json"
    report_unused_allow_entries dead-code
    if [ "$GATE_STATUS" = "fail" ]; then
      print_allow_hint dead-code
      echo "GATE FAILED: $VIOLATION_COUNT dead code finding(s) from SARIF" >&2
      exit 1
    fi
    exit 0
  fi
fi

DIFF=$(git diff "$SDLC_DEFAULT_BRANCH"...HEAD 2>/dev/null || git diff --cached 2>/dev/null || true)

VIOLATIONS=()

# Check for commented-out code blocks (3+ consecutive commented lines that look like code)
COMMENTED_CODE=$(echo "$DIFF" | grep -n '^+' | grep -vE '^\+\+\+' | grep -E '^\+\s*(//|#|/\*|\*|<!--)\s*(import |export |function |const |let |var |class |def |return |if |for |while |fun |val |package )' | head -20 || true)
if [ -n "$COMMENTED_CODE" ]; then
  ESCAPED=$(echo "$COMMENTED_CODE" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  is_allowed "dead-code" "type=commented_code" ||
    VIOLATIONS+=("{\"type\":\"commented_code\",\"details\":$ESCAPED}")
fi

# Check for unused imports in changed files
CHANGED_CODE=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.java' '*.kt' '*.go' 2>/dev/null || true)
if [ -n "$CHANGED_CODE" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Extract imported names and check if they're used beyond the import line
    UNUSED=$(python3 -c "
import re, sys, os

filepath = sys.argv[1]
ext = os.path.splitext(filepath)[1]
with open(filepath) as f:
    content = f.read()
    lines = content.split('\n')

# Detect Python TYPE_CHECKING imports and __all__ re-exports
type_checking_names = set()
all_names = set()
if ext == '.py':
    # Names in __all__ are re-exported, not dead
    all_match = re.search(r'__all__\s*=\s*\[([^\]]+)\]', content)
    if all_match:
        for name in re.findall(r'[\"\\'](\w+)[\"\\']', all_match.group(1)):
            all_names.add(name)

    # Track imports inside TYPE_CHECKING blocks
    in_type_checking = False
    for line in lines:
        stripped = line.strip()
        if re.match(r'if\s+TYPE_CHECKING', stripped):
            in_type_checking = True
            continue
        if in_type_checking:
            if stripped and not stripped.startswith(('#', 'from', 'import')) and not line[0].isspace():
                in_type_checking = False
            elif re.match(r'\s+from\s+\S+\s+import\s+(.+)', line):
                m = re.match(r'\s+from\s+\S+\s+import\s+(.+)', line)
                for name in m.group(1).split(','):
                    name = name.strip().split(' as ')[-1].strip()
                    if name and not name.startswith('#'):
                        type_checking_names.add(name)

imports = []
for i, line in enumerate(lines):
    if ext in ('.ts', '.tsx', '.js', '.jsx'):
        m = re.findall(r'import\s*\{([^}]+)\}', line)
        for group in m:
            for name in group.split(','):
                name = name.strip().split(' as ')[-1].strip()
                if name:
                    imports.append((name, i+1))
        # import type { X } — TS type-only imports are used in annotations
        m = re.findall(r'import\s+type\s*\{([^}]+)\}', line)
        for group in m:
            for name in group.split(','):
                name = name.strip().split(' as ')[-1].strip()
                if name:
                    imports.append((name, i+1))
        m = re.match(r'import\s+(\w+)\s+from', line)
        if m:
            imports.append((m.group(1), i+1))
    elif ext == '.py':
        m = re.match(r'\s*from\s+(\S+)\s+import\s+(.+)', line)
        if m and m.group(1) != '__future__':
            for name in m.group(2).split(','):
                name = name.strip().split(' as ')[-1].strip()
                if name and not name.startswith('#'):
                    imports.append((name, i+1))
        m = re.match(r'\s*import\s+(\w+)(?:\s+as\s+(\w+))?', line)
        if m and 'from' not in line:
            imports.append((m.group(2) or m.group(1), i+1))
    elif ext in ('.java', '.kt'):
        m = re.match(r'import\s+(?:static\s+)?[\w.]+\.(\w+)', line)
        if m:
            imports.append((m.group(1), i+1))
    elif ext == '.go':
        m = re.match(r'\s*\"([^\"]+)\"', line)
        if m:
            pkg = m.group(1).split('/')[-1]
            imports.append((pkg, i+1))

unused = []
for name, line_num in imports:
    # Skip names re-exported via __all__
    if name in all_names:
        continue
    pattern = re.compile(r'\b' + re.escape(name) + r'\b')
    non_import_uses = 0
    for i, line in enumerate(lines):
        # Skip import lines (but not lines that happen to start with from/import as identifiers)
        if re.match(r'\s*(import\s|from\s|require)', line):
            continue
        if pattern.search(line):
            non_import_uses += 1
    # TYPE_CHECKING imports are used in string annotations — check for quoted usage
    if non_import_uses == 0 and name in type_checking_names:
        quoted_pattern = re.compile(r'[\"\\']' + re.escape(name) + r'[\"\\']')
        if quoted_pattern.search(content):
            non_import_uses += 1
    if non_import_uses == 0:
        unused.append(f'{name}:{line_num}')

if unused:
    print('|'.join(unused))
" "$file" 2>/dev/null || true)

    if [ -n "$UNUSED" ]; then
      IFS='|' read -ra ITEMS <<<"$UNUSED"
      for item in "${ITEMS[@]}"; do
        local_name="${item%%:*}"
        local_line="${item##*:}"
        is_allowed "dead-code" "file=$file" "name=$local_name" "type=unused_import" && continue
        VIOLATIONS+=("{\"type\":\"unused_import\",\"file\":\"$file\",\"name\":\"$local_name\",\"line\":$local_line}")
      done
    fi
  done <<<"$CHANGED_CODE"
fi

# Check Ruby files with rubocop (require loads files — only a Ruby-aware tool detects unused requires)
CHANGED_RUBY=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.rb' 2>/dev/null || true)
if [ -n "$CHANGED_RUBY" ]; then
  RUBOCOP=""
  if [ -f Gemfile ] && bundle exec rubocop --version &>/dev/null 2>&1; then
    RUBOCOP="bundle exec rubocop"
  elif command -v rubocop &>/dev/null; then
    RUBOCOP="rubocop"
  fi

  if [ -n "$RUBOCOP" ]; then
    RUBY_FILES=()
    while IFS= read -r file; do
      [ -f "$file" ] && RUBY_FILES+=("$file")
    done <<<"$CHANGED_RUBY"

    if [ ${#RUBY_FILES[@]} -gt 0 ]; then
      COPS="Lint/UselessAssignment,Lint/UnusedMethodArgument,Lint/UnusedBlockArgument"
      COPS="$COPS,Lint/RedundantRequireStatement,Lint/UnreachableCode,Lint/UselessMethodDefinition"
      RC_JSON=$($RUBOCOP --only "$COPS" --format json --force-exclusion "${RUBY_FILES[@]}" 2>/dev/null || true)

      if [ -n "$RC_JSON" ]; then
        while IFS= read -r vline; do
          [ -z "$vline" ] && continue
          rc_file=$(echo "$vline" | python3 -c "import json,sys; print(json.load(sys.stdin)['file'])" 2>/dev/null || true)
          rc_cop=$(echo "$vline" | python3 -c "import json,sys; print(json.load(sys.stdin)['cop'])" 2>/dev/null || true)
          is_allowed "dead-code" "file=$rc_file" "name=$rc_cop" "type=rubocop" && continue
          VIOLATIONS+=("$vline")
        done < <(echo "$RC_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for f in data.get('files', []):
    for o in f.get('offenses', []):
        print(json.dumps({
            'type': 'rubocop_dead_code',
            'file': f['path'],
            'cop': o['cop_name'],
            'line': o['location']['start_line'],
            'message': o['message']
        }))
" 2>/dev/null || true)
      fi
    fi
  fi
fi

# Clear crash trap — we made it past analysis, write proof normally
trap - ERR

GATE_STATUS="pass"
if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  GATE_STATUS="fail"
fi

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  VIO_JSON=$(printf '%s,' "${VIOLATIONS[@]}" | sed 's/,$//')
else
  VIO_JSON=""
fi

cat >"$PROOF_DIR/dead-code.json" <<ENDJSON
{
  "gate": "dead-code",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "violations": [${VIO_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON
cat "$PROOF_DIR/dead-code.json"
report_unused_allow_entries dead-code

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint dead-code
  echo "GATE FAILED: Dead code detected" >&2
  exit 1
fi
