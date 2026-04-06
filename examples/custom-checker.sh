#!/usr/bin/env bash
# examples/custom-checker.sh — template for a new dimension checker.
#
# To add a new dimension:
# 1. Copy this file to plugins/axr/scripts/check-<dim-name>.sh
# 2. Replace <dimension_id> with the rubric dimension id
# 3. Implement score_* functions for each criterion
# 4. The /axr orchestrator auto-discovers check-*.sh scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In a real checker, source from the lib directory:
# source "$SCRIPT_DIR/lib/common.sh"

# Example: score a criterion
# axr_init_output <dimension_id> "script:check-<dim-name>.sh"
#
# score_example_1() {
#     local name
#     name="$(axr_criterion_name <dimension_id>.1)"
#     local score=0 evidence=()
#
#     # Check for evidence
#     if [ -f "some-config.json" ]; then
#         score=2
#         evidence+=("some-config.json present")
#     fi
#
#     axr_emit_criterion "<dimension_id>.1" "$name" script "$score" \
#         "evaluation summary" "${evidence[@]}"
# }
#
# score_example_1
# axr_finalize_output

echo "This is an example template — see plugins/axr/scripts/check-*.sh for real implementations."
