#!/usr/bin/env bash
# Gate: File Size — max lines per source file (per-extension aware)
# Produces: .quality/proof/filesize.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-filesize.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
CHECKED=0
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/filesize.json" <<CRASHJSON
{
  "gate": "filesize",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "files_checked": ${CHECKED:-0},
  "violations": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/filesize.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

# Get changed source files (against default branch)
CHANGED_FILES=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' '*.html' '*.css' '*.sh' '*.md' '*.scss' '*.less' 2>/dev/null || git diff --name-only --cached -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' '*.html' '*.css' '*.sh' '*.md' '*.scss' '*.less' 2>/dev/null || true)

if [ -z "$CHANGED_FILES" ]; then
  echo '{"gate":"filesize","sha":"'"$(git rev-parse HEAD)"'","status":"pass","error":null,"files_checked":0,"violations":[],"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' | tee "$PROOF_DIR/filesize.json"
  exit 0
fi

# Batch-resolve thresholds for all files
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$TMPFILE.thresholds"' EXIT INT TERM
echo "$CHANGED_FILES" >"$TMPFILE"
resolve_all_thresholds "$TMPFILE" "max_file_lines" >"$TMPFILE.thresholds"

VIOLATIONS=()

while IFS=$'\t' read -r file limit; do
  [ -f "$file" ] || continue
  # Skip files with no line limit
  [ "$limit" = "null" ] && continue

  CHECKED=$((CHECKED + 1))
  LINES=$(wc -l <"$file" | tr -d ' ')
  if [ "$LINES" -gt "$limit" ]; then
    is_allowed "filesize" "file=$file" && continue
    VIOLATIONS+=("{\"file\":\"$file\",\"lines\":$LINES,\"max\":$limit}")
  fi
done <"$TMPFILE.thresholds"

# Clear crash trap — we made it past analysis, write proof normally
trap - ERR

GATE_STATUS="pass"
if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  GATE_STATUS="fail"
fi

# Build JSON — only include failure details
VIO_JSON=""
if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  VIO_JSON=$(printf '%s,' "${VIOLATIONS[@]}" | sed 's/,$//')
fi

cat >"$PROOF_DIR/filesize.json" <<ENDJSON
{
  "gate": "filesize",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "files_checked": $CHECKED,
  "violations": [${VIO_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/filesize.json"

report_unused_allow_entries filesize

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint filesize
  echo "GATE FAILED: ${#VIOLATIONS[@]} file(s) exceed line limit" >&2
  exit 1
fi
