#!/usr/bin/env bash
# Gate: Coverage — read existing coverage data, check per-file thresholds
# Produces: .quality/proof/coverage.json
# IMPORTANT: This script NEVER runs tests. It reads data produced by gate-tests.sh.
# run-gates.sh must run gate-tests.sh before this script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"
# shellcheck source=plugins/sdlc/scripts/commands-config.sh
source "$SCRIPT_DIR/commands-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-coverage.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/coverage.json" <<CRASHJSON
{
  "gate": "coverage",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "coverage_tool": "unknown",
  "files_checked": 0,
  "files_matched": 0,
  "reason": "",
  "below_threshold": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/coverage.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

MIN_COVERAGE="$SDLC_MIN_COVERAGE"

# Find changed source files on this branch
CHANGED_SRC=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' 2>/dev/null || true)

SRC_FILES=""
if [ -n "$CHANGED_SRC" ]; then
  SRC_FILES=$(echo "$CHANGED_SRC" | grep -vE '(\.test\.|\.spec\.|_test\.|test_|\.config\.|\.d\.ts$|__tests__|__mocks__|/tests/|/test/)' || true)
fi

# Check for explicit commands config first
COVERAGE_JSON=""
COVERAGE_FILE=""
COVERAGE_FORMAT=""
CMD_CONFIG=$(get_command "coverage")
if [ -n "$CMD_CONFIG" ]; then
  if echo "$CMD_CONFIG" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    parse_command_config "$CMD_CONFIG"
  else
    _CMD_RUN="$CMD_CONFIG"
    _CMD_FORMAT=""
    _CMD_REPORT=""
  fi

  # Execute run command if present (array-split, no eval)
  if [ -n "$_CMD_RUN" ]; then
    read -ra _cmd_array <<<"$_CMD_RUN"
    "${_cmd_array[@]}" >/dev/null 2>&1 || true
  fi

  # Parse report based on format
  if [ -n "$_CMD_FORMAT" ] && [ -n "$_CMD_REPORT" ]; then
    case "$_CMD_FORMAT" in
      jacoco)
        COVERAGE_JSON=$(python3 "$SCRIPT_DIR/parse_jacoco.py" "$_CMD_REPORT" 2>/dev/null || echo "{}")
        COVERAGE_FORMAT="jacoco"
        ;;
      cobertura)
        COVERAGE_JSON=$(python3 "$SCRIPT_DIR/parse_cobertura.py" "$_CMD_REPORT" 2>/dev/null || echo "{}")
        COVERAGE_FORMAT="cobertura"
        ;;
      istanbul)
        for f in $(python3 -c "import glob, sys; [print(p) for p in glob.glob(sys.argv[1], recursive=True)]" "$_CMD_REPORT" 2>/dev/null); do
          COVERAGE_FILE="$f"
          COVERAGE_FORMAT="js"
          break
        done
        ;;
      coverage-py)
        for f in $(python3 -c "import glob, sys; [print(p) for p in glob.glob(sys.argv[1], recursive=True)]" "$_CMD_REPORT" 2>/dev/null); do
          COVERAGE_FILE="$f"
          COVERAGE_FORMAT="py"
          break
        done
        ;;
    esac
  fi
fi

if [ -z "$CMD_CONFIG" ]; then
  # Find existing coverage data — never run tests to produce it
  for candidate in coverage.json coverage/coverage-summary.json coverage-summary.json; do
    if [ -f "$candidate" ]; then
      COVERAGE_FILE="$candidate"
      case "$candidate" in
        *summary*) COVERAGE_FORMAT="js" ;;
        *) COVERAGE_FORMAT="py" ;;
      esac
      break
    fi
  done

  # Auto-detect SimpleCov (Ruby) — coverage/.resultset.json
  if [ -z "$COVERAGE_FILE" ] && [ -z "$COVERAGE_JSON" ] && [ -f "coverage/.resultset.json" ]; then
    COVERAGE_JSON=$(python3 "$SCRIPT_DIR/parse_simplecov.py" "coverage/.resultset.json" 2>/dev/null || echo "{}")
    if [ "$COVERAGE_JSON" != "{}" ]; then
      COVERAGE_FORMAT="simplecov"
    fi
  fi

  # Auto-detect JaCoCo XML for JVM projects. Pass the RESOLVED path to
  # parse_jacoco.py, not the glob pattern — the latter is re-globbed in a
  # separate Python process whose cwd may differ in monorepos.
  if [ -z "$COVERAGE_FILE" ] && [ -z "$COVERAGE_JSON" ]; then
    JACOCO_XML=$(python3 -c "import glob; files=glob.glob('**/build/reports/jacoco/**/*.xml', recursive=True); print(files[0] if files else '')" 2>/dev/null || echo "")
    if [ -n "$JACOCO_XML" ]; then
      COVERAGE_JSON=$(python3 "$SCRIPT_DIR/parse_jacoco.py" "$JACOCO_XML" 2>/dev/null || echo "{}")
      COVERAGE_FORMAT="jacoco"
    fi
  fi
fi

trap - ERR
BELOW_THRESHOLD=()
GATE_STATUS="pass"
SKIP_REASON=""
# COV_EXTS gates per-file checks on language match (mixed-lang repo guard)
case "$COVERAGE_FORMAT" in
  py) COV_EXTS="py" ;; js) COV_EXTS="ts tsx js jsx mjs cjs" ;;
  jacoco) COV_EXTS="kt java" ;; simplecov) COV_EXTS="rb" ;; *) COV_EXTS="" ;;
esac
if [ -z "$SRC_FILES" ]; then
  GATE_STATUS="skip"
  SKIP_REASON="no source files changed on branch"
elif [ -n "${COVERAGE_JSON:-}" ] && [ "$COVERAGE_JSON" != "{}" ]; then
  FILES_CHECKED=0
  FILES_MATCHED=0
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    if [ -n "$COV_EXTS" ]; then
      _ext="${file##*.}"
      _match=false
      for _e in $COV_EXTS; do [ "$_ext" = "$_e" ] && _match=true && break; done
      [ "$_match" = "true" ] || continue
    fi
    FILES_CHECKED=$((FILES_CHECKED + 1))
    pct=$(python3 -c "
import json,sys,os
cov=json.loads(sys.argv[1]); fp=sys.argv[2]; bn=os.path.basename(fp)
for k in cov:
    if fp.endswith(k) or k.endswith(bn): print(cov[k]['lines']['pct']); sys.exit(0)
    p=k.split('/')
    if len(p)>=2 and fp.endswith('/'.join(p[-2:])): print(cov[k]['lines']['pct']); sys.exit(0)
print('N/A')
" "$COVERAGE_JSON" "$file" 2>/dev/null || echo "N/A")

    if [ "$pct" != "N/A" ]; then
      FILES_MATCHED=$((FILES_MATCHED + 1))
      if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$pct" "$MIN_COVERAGE" 2>/dev/null; then
        if ! is_allowed "coverage" "file=$file"; then
          GATE_STATUS="fail"
          BELOW_THRESHOLD+=("{\"file\":$(FP="$file" python3 -c "import json,os;print(json.dumps(os.environ['FP']))"),\"coverage\":$pct,\"min\":$MIN_COVERAGE}")
        fi
      fi
    fi
  done <<<"$SRC_FILES"
  # Vacuous-pass guard: coverage data exists but none of the changed files matched
  if [ "$FILES_CHECKED" -gt 0 ] && [ "$FILES_MATCHED" -eq 0 ]; then
    GATE_STATUS="fail"
    BELOW_THRESHOLD+=("{\"file\":\"(none matched in coverage data)\",\"coverage\":0,\"min\":$MIN_COVERAGE,\"vacuous\":true}")
  fi
elif [ -z "$COVERAGE_FILE" ] && [ -z "${COVERAGE_JSON:-}" ]; then
  GATE_STATUS="fail"
  # JVM diagnostics when Java/Kotlin changed but no JaCoCo data
  if echo "$SRC_FILES" | grep -qE '\.(kt|java)$'; then
    if find . -path "*/build/jacoco/*.exec" 2>/dev/null | grep -q .; then
      echo "JaCoCo data collected but report not generated. Run: ./gradlew jacocoTestReport" >&2
    else
      echo "No JaCoCo data collected — configure commands.coverage in sdlc.config.json to point at the JacocoTaskExtension tier." >&2
    fi
  fi
else
  # Empty coverage file → fall through to no-data fail; clear COV_EXTS so the
  # later skip-when-no-matches guard cannot absorb this as a "nothing to check"
  HAS_FILES=$(python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except: print('0'); sys.exit(0)
fmt=sys.argv[2]
if fmt=='py': print(len(d.get('files',{})))
elif fmt in ('js','simplecov'): print(sum(1 for k in d if k!='total'))
else: print(len(d))
" "$COVERAGE_FILE" "$COVERAGE_FORMAT" 2>/dev/null || echo "0")
  if [ "$HAS_FILES" = "0" ]; then COVERAGE_FILE="" COVERAGE_JSON="" COV_EXTS=""; fi
fi
if [ -n "$COVERAGE_FILE" ] && [ -n "$COV_EXTS" ]; then
  FILES_CHECKED=0
  FILES_MATCHED=0
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    _ext="${file##*.}"
    _match=false
    for _e in $COV_EXTS; do [ "$_ext" = "$_e" ] && _match=true && break; done
    [ "$_match" = "true" ] || continue
    FILES_CHECKED=$((FILES_CHECKED + 1))
    pct=$(python3 -c "
import json,sys
fp=sys.argv[2]; fmt=sys.argv[3]
d=json.load(open(sys.argv[1]))
# Path-segment match only — basename fallback would alias sibling files
# with identical names (e.g. auth/utils.py vs api/utils.py).
def m(k):
    return fp==k or fp.endswith('/'+k) or k.endswith('/'+fp)
if fmt=='py':
    for k,v in d.get('files',{}).items():
        if m(k): s=v.get('summary',{}); print(s.get('percent_covered_display',s.get('percent_covered','N/A'))); sys.exit(0)
elif fmt=='js':
    for k,v in d.items():
        if k!='total' and m(k): print(v['lines']['pct']); sys.exit(0)
print('N/A')
" "$COVERAGE_FILE" "$file" "$COVERAGE_FORMAT" 2>/dev/null || echo "N/A")

    if [ "$pct" != "N/A" ]; then
      FILES_MATCHED=$((FILES_MATCHED + 1))
      if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$pct" "$MIN_COVERAGE" 2>/dev/null; then
        if ! is_allowed "coverage" "file=$file"; then
          GATE_STATUS="fail"
          BELOW_THRESHOLD+=("{\"file\":$(FP="$file" python3 -c "import json,os;print(json.dumps(os.environ['FP']))"),\"coverage\":$pct,\"min\":$MIN_COVERAGE}")
        fi
      fi
    fi
  done <<<"$SRC_FILES"
  # Vacuous-pass guard: coverage file exists but none of the changed files matched
  if [ "$FILES_CHECKED" -gt 0 ] && [ "$FILES_MATCHED" -eq 0 ]; then
    GATE_STATUS="fail"
    BELOW_THRESHOLD+=("{\"file\":\"(none matched in coverage data)\",\"coverage\":0,\"min\":$MIN_COVERAGE,\"vacuous\":true}")
  fi
fi

: "${FILES_CHECKED:=0}"
: "${FILES_MATCHED:=0}"
# Skip when no changed files match the coverage tool's language
if [ -n "$SRC_FILES" ] && [ -n "$COV_EXTS" ] && [ "$FILES_CHECKED" -eq 0 ] && [ "$GATE_STATUS" != "skip" ] && [ "$GATE_STATUS" != "fail" ]; then
  GATE_STATUS="skip"
  SKIP_REASON="no changed files match coverage format '$COVERAGE_FORMAT'"
fi

BELOW_JSON=""
if [ ${#BELOW_THRESHOLD[@]} -gt 0 ]; then
  BELOW_JSON=$(printf '%s,' "${BELOW_THRESHOLD[@]}" | sed 's/,$//')
fi

cat >"$PROOF_DIR/coverage.json" <<ENDJSON
{
  "gate": "coverage",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "coverage_tool": "${COVERAGE_FORMAT:-none}",
  "files_checked": $FILES_CHECKED,
  "files_matched": $FILES_MATCHED,
  "reason": "$SKIP_REASON",
  "below_threshold": [${BELOW_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/coverage.json"

report_unused_allow_entries coverage

if [ "$GATE_STATUS" = "skip" ]; then
  echo "Coverage gate skipped: $SKIP_REASON" >&2
  exit 0
fi

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint coverage
  if [ -z "$COVERAGE_FILE" ] && [ -z "${COVERAGE_JSON:-}" ]; then
    echo "GATE FAILED: No coverage data — ensure gate-tests.sh runs first and produces coverage" >&2
  else
    if [ ${#BELOW_THRESHOLD[@]} -eq 1 ] && echo "${BELOW_THRESHOLD[0]}" | grep -q '"vacuous":true'; then
      echo "GATE FAILED: coverage data present but no source files matched — check that coverage report paths match diff file names" >&2
    else
      echo "GATE FAILED: ${#BELOW_THRESHOLD[@]} file(s) below ${MIN_COVERAGE}% coverage:" >&2
      for entry in "${BELOW_THRESHOLD[@]}"; do
        echo "$entry" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(f\"  {d['file']} ({d['coverage']}%)\")" >&2
      done
    fi
  fi
  exit 1
fi
