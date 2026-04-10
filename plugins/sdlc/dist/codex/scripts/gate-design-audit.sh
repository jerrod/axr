#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

PROOF_FILE="$PROOF_DIR/design-audit.json"
SCREENSHOTS_DIR="$PROOF_DIR/screenshots"

trap '_write_proof "fail" "Gate script crashed"' ERR

_write_proof() {
  local status="$1" message="${2:-}"
  mkdir -p "$PROOF_DIR" "$SCREENSHOTS_DIR"
  cat >"$PROOF_FILE" <<PROOF
{
  "gate": "design-audit",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "$status",
  "error": null,
  "message": "$message",
  "categories": {},
  "overall_grade": "",
  "screenshots": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
PROOF
}

# Check if design audit is enabled
da_enabled=$(get_design_audit_config "enabled")
if [[ "$da_enabled" == "False" || "$da_enabled" == "false" ]]; then
  _write_proof "pass" "Design audit disabled in config — gate not applicable"
  exit 0
fi

# Use shared dev-server detection from load-config.sh
if ! detect_dev_server; then
  _write_proof "pass" "No dev server detected — gate not applicable"
  exit 0
fi

# Check if agent already wrote results
if [[ -f "$PROOF_FILE" ]]; then
  existing_status=$(PF="$PROOF_FILE" python3 -c "import json, os; print(json.load(open(os.environ['PF'])).get('status',''))" 2>/dev/null || echo "")
  if [[ "$existing_status" == "pass" || "$existing_status" == "fail" ]]; then
    # Check min_grade threshold
    min_grade=$(get_design_audit_config "min_grade")
    if [[ -n "$min_grade" ]]; then
      below_min=$(PF="$PROOF_FILE" DA_MIN_GRADE="$min_grade" python3 -c "
import json, sys, os
data = json.load(open(os.environ['PF']))
grades = 'ABCDF'
min_g = os.environ.get('DA_MIN_GRADE', '')
if not min_g or min_g not in grades:
    sys.exit(0)
min_idx = grades.index(min_g)
cats = data.get('categories', {})
failed = [c for c, v in cats.items() if grades.index(v.get('grade','F')) > min_idx]
print(','.join(failed) if failed else '')
" 2>/dev/null || echo "")
      if [[ -n "$below_min" ]]; then
        echo "Design audit FAIL: categories below minimum grade $min_grade: $below_min"
        exit 1
      fi
    fi
    exit 0
  fi
fi

_write_proof "pass" "Design audit not yet performed — run /sdlc:design-audit for UI audit"
exit 0
