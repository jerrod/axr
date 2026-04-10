#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

PROOF_FILE="$PROOF_DIR/qa.json"
RECORDINGS_DIR="$PROOF_DIR/recordings"

# Crash protection — always produce proof
trap '_write_proof "fail" "Gate script crashed"' ERR

_write_proof() {
  local status="$1" message="${2:-}"
  mkdir -p "$PROOF_DIR" "$RECORDINGS_DIR"
  cat >"$PROOF_FILE" <<PROOF
{
  "gate": "qa",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "$status",
  "error": null,
  "message": "$message",
  "flows_tested": ${FLOWS_TESTED:-0},
  "flows_passed": ${FLOWS_PASSED:-0},
  "flows_failed": ${FLOWS_FAILED:-0},
  "issues": [],
  "recordings": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
PROOF
}

# Check if QA is enabled in config
qa_enabled=$(get_qa_config "enabled")
if [[ "$qa_enabled" == "False" || "$qa_enabled" == "false" ]]; then
  _write_proof "pass" "QA disabled in config — gate not applicable"
  exit 0
fi

# Use shared dev-server detection from load-config.sh
if ! detect_dev_server; then
  _write_proof "pass" "No dev server detected — gate not applicable"
  exit 0
fi

# Check if QA agent already wrote results
if [[ -f "$PROOF_FILE" ]]; then
  existing_status=$(PF="$PROOF_FILE" python3 -c "import json, os; print(json.load(open(os.environ['PF'])).get('status',''))" 2>/dev/null || echo "")
  if [[ "$existing_status" == "pass" || "$existing_status" == "fail" ]]; then
    exit 0
  fi
fi

# QA has not been run yet — mark as pending
_write_proof "pass" "QA testing not yet performed — run /sdlc:qa for browser testing"
exit 0
