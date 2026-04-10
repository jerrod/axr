#!/usr/bin/env bash
# Validator must reject a plugin with NO commands/, skills/, or agents/.
# This proves the entry-point requirement is not a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/validator/_lib_setup.sh
. "$SCRIPT_DIR/_lib_setup.sh"

WORK="$(setup_validator_workspace no-entry-point)"
trap 'rm -rf "$WORK"' EXIT

rc="$(run_validator_in "$WORK" "$WORK/out.log")"

# Expect non-zero exit AND the specific error message.
if [ "$rc" -eq 0 ]; then
    echo "FAIL: validator accepted a plugin with no entry point (should have failed)"
    cat "$WORK/out.log"
    exit 1
fi

# Anchor tightly so a future reword of the error message forces a conscious
# test update rather than silently making this assertion vacuous.
if ! grep -q 'no entry point — need at least one of commands/, skills/, agents/' "$WORK/out.log"; then
    echo "FAIL: validator rejected the plugin but not for the expected reason"
    cat "$WORK/out.log"
    exit 1
fi

echo "PASS: validator rejected no-entry-point plugin with the expected message"
