#!/usr/bin/env bash
# Plan Check: Verify all checked plan items have valid proof anchors
#
# This is the enforcement mechanism. A checked item without a proof anchor
# is an unverified claim. A checked item with a stale anchor means code
# changed after the proof was recorded.
#
# Usage: plan-check.sh <plan-file>
# Exit: 0 if all checked items have valid proof, 1 if violations found
set -euo pipefail

CHECKPOINT_DIR="${CHECKPOINT_DIR:-.quality/checkpoints}"

plan_file="${1:-}"
[ -z "$plan_file" ] && {
  echo "Usage: plan-check.sh <plan-file>"
  exit 1
}
[ ! -f "$plan_file" ] && {
  echo "Plan file not found: $plan_file"
  exit 1
}

total_items=0
checked_items=0
unchecked_items=0
proven_items=0
unproven_items=0
stale_items=0
violations=()

current_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Verify a single proof anchor reference
verify_proof_anchor() {
  local proof_ref="$1"
  local item_text="$2"

  local checkpoint_file="$CHECKPOINT_DIR/${proof_ref}.json"
  if [ ! -f "$checkpoint_file" ]; then
    checkpoint_file=$(find "$CHECKPOINT_DIR" -name "*${proof_ref}*" -type f 2>/dev/null | head -1)
  fi

  if [ -z "$checkpoint_file" ] || [ ! -f "$checkpoint_file" ]; then
    unproven_items=$((unproven_items + 1))
    violations+=("MISSING PROOF: \"$item_text\" — checkpoint $proof_ref not found")
    return
  fi

  local cp_status
  cp_status=$(CP_FILE="$checkpoint_file" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
failed = d.get('failed', 0)
for p in d.get('proof_snapshot', []):
    if p.get('status') == 'fail':
        failed += 1
print('pass' if failed == 0 else 'fail')
" 2>/dev/null || echo "unknown")

  if [ "$cp_status" != "pass" ]; then
    unproven_items=$((unproven_items + 1))
    violations+=("FAILED PROOF: \"$item_text\" — checkpoint $proof_ref has failing gates")
    return
  fi

  local cp_sha
  cp_sha=$(CP_FILE="$checkpoint_file" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha','?'))" 2>/dev/null)
  if [ "$cp_sha" = "$current_sha" ]; then
    proven_items=$((proven_items + 1))
  else
    stale_items=$((stale_items + 1))
    violations+=("STALE: \"$item_text\" — proven at $cp_sha but HEAD is now $current_sha")
  fi
}

# Parse plan and verify each checked item
while IFS= read -r line; do
  if echo "$line" | grep -qE '^\s*-\s*\[[ xX]\]'; then
    total_items=$((total_items + 1))

    if echo "$line" | grep -qE '^\s*-\s*\[[xX]\]'; then
      checked_items=$((checked_items + 1))

      if echo "$line" | grep -qE '<!--[[:space:]]*proof:[[:space:]]*[^[:space:]]+'; then
        local_proof_ref=$(echo "$line" | sed -n 's|.*<!--[[:space:]]*proof:[[:space:]]*\([^[:space:]]*\).*|\1|p')
        local_item_text="${line%%<!--*}"
        local_item_text="${local_item_text#*] }"
        verify_proof_anchor "$local_proof_ref" "$local_item_text"
      else
        unproven_items=$((unproven_items + 1))
        local_item_text="${line#*] }"
        violations+=("NO ANCHOR: \"$local_item_text\" — checked with no proof reference")
      fi
    else
      unchecked_items=$((unchecked_items + 1))
    fi
  fi
done <"$plan_file"

# Output
echo "Plan Progress: $(basename "$plan_file")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Total items:    $total_items"
echo "  Checked:        $checked_items"
echo "  Unchecked:      $unchecked_items"
echo "  Proven:         $proven_items"
echo "  Unproven:       $unproven_items"
echo "  Stale:          $stale_items"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#violations[@]} -gt 0 ]; then
  echo ""
  echo "VIOLATIONS:"
  for v in "${violations[@]}"; do
    echo "  ✗ $v"
  done
  echo ""
  echo "PLAN INTEGRITY CHECK FAILED"
  exit 1
fi

if [ "$total_items" -eq 0 ]; then
  echo ""
  echo "No checkbox items found in plan"
  exit 0
fi

echo ""
echo "✓ All checked items have valid proof"
exit 0
