#!/usr/bin/env bash
# Validator must accept a plugin that has skills/ but no commands/ or scripts/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/validator/_lib_setup.sh
. "$SCRIPT_DIR/_lib_setup.sh"

WORK="$(setup_validator_workspace skills-only)"
trap 'rm -rf "$WORK"' EXIT

rc="$(run_validator_in "$WORK" "$WORK/out.log")"

if [ "$rc" -ne 0 ]; then
    echo "FAIL: validator rejected skills-only plugin (exit $rc)"
    cat "$WORK/out.log"
    exit 1
fi

# Positive assertion: the validator must have actually run to completion and
# emitted its success summary. Without this, a future bug that exits 0 before
# any check fires would silently pass this test.
if ! grep -q 'all checks passed' "$WORK/out.log"; then
    echo "FAIL: validator exited 0 but did not emit 'all checks passed' summary"
    cat "$WORK/out.log"
    exit 1
fi

echo "PASS: validator accepted skills-only plugin"
