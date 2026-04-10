---
name: qa
description: "Browser-based QA testing with structured inventory and signoff — enumerates all testable claims before testing, walks user flows, captures GIF recordings as proof. Trigger: 'QA this feature', 'test in the browser', 'record a demo', 'does it work'."
---

# QA Testing

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log review sdlc:qa started --context "$ARGUMENTS"`
- **End:** `bash "$AUDIT_SCRIPT" log review sdlc:qa completed --context="<summary>"`

## When to Use

- During review phase, after code gates pass
- Standalone: `/sdlc:qa` to test the current feature interactively
- After fixing review findings that affect UI

## Prerequisites

Requires Claude Preview MCP tools and Claude in Chrome GIF creator. If unavailable, report and skip.

## Phase 1: QA Inventory (Before Browser)

Before opening the browser, enumerate every testable item from three sources:

1. **Spec flows and acceptance criteria** — read `docs/specs/*.md` for the current feature. Extract every `## User Flow:` section and each acceptance criterion. Every "should" or "must" in the spec becomes an inventory item.
2. **User-visible controls** — identify every interactive element in the implementation:
   - Buttons, toggles, checkboxes, radio buttons
   - Text inputs, dropdowns, date pickers, sliders
   - Mode switches, tab navigation, accordions
   - Links, navigation items, breadcrumbs
   - Form submissions, file uploads, drag-and-drop targets
3. **Visual and interaction states** — for each control, identify the states it can be in:
   - Default/initial state
   - Hover, focus, active, disabled states
   - Error states (validation failures, server errors)
   - Empty/zero-data states
   - Loading/pending states
   - Success/confirmation states
   - Mobile breakpoint variations (if applicable)

For each inventory item, note:
- The functional check to perform (what to click/type/verify)
- The expected behavior or visual result
- The evidence to capture (GIF of flow, screenshot of state)

**Complexity gate:** If the spec has 1-2 simple flows with no conditional branches, skip the formal inventory — the flows ARE the inventory. If there are 3+ flows or conditional branches, build the full inventory before proceeding.

## Phase 2: Functional Testing

Launch the application via Preview tools and walk through each inventory item:

1. **Use real user input** — click, type, navigate. Do not use JavaScript evaluation to manipulate state
2. **Test stateful controls through full cycles** — initial state -> changed state -> returned to initial state
3. **Record a GIF for each flow** — with click indicators showing what was interacted with
4. **Capture errors** — check browser console for errors after each flow

After completing scripted checks from the inventory:

5. **Exploratory pass (30-90 seconds)** — go off the happy path. Try unexpected inputs, rapid clicks, browser back/forward, empty submissions, boundary values
6. **Update inventory** — if exploration reveals new states, controls, or behaviors not in the original inventory, add them and test them

## Phase 3: Visual Verification

**SHA dedup check:** Before running visual verification, check if the design reviewer already covered this commit:

```bash
if [ -f .quality/proof/design-audit.json ]; then
  DESIGN_SHA=$(jq -r '.sha' .quality/proof/design-audit.json)
  CURRENT_SHA=$(git rev-parse HEAD)
  if [ "$DESIGN_SHA" = "$CURRENT_SHA" ]; then
    echo "Visual QA covered by design-reviewer at $CURRENT_SHA"
    # Skip visual checks — log and proceed to Phase 4
  fi
fi
```

If design audit does not exist or SHA does not match, run visual checks:

1. **Inspect initial viewport** — before scrolling, verify the intended initial view is complete
2. **Viewport fit** — all required UI elements visible without clipping or horizontal scroll
3. **Visual state coverage** — verify each visual state from the inventory has a matching screenshot
4. **Check for defects** — clipping, overflow, distortion, layout imbalance, spacing inconsistencies, broken layering (z-index issues)

## Phase 4: Signoff (Internal)

Agent self-checks before reporting QA complete. This is an internal checklist, not presented to the user:

- [ ] Functional path passed with real user input (no JS evaluation shortcuts)
- [ ] Coverage mapped to inventory — all items exercised
- [ ] Each claim has a matching GIF or screenshot captured from the correct state
- [ ] Viewport fit verified for the intended initial view
- [ ] Exploratory pass completed — noted what it covered and any findings
- [ ] No unresolved console errors (or errors documented as findings)
- [ ] "What visible part have I NOT yet inspected?" — answered and resolved

If any item fails: fix the issue or report it as a finding. Do not mark QA complete with unresolved items.

## Proof Artifacts

- `.quality/proof/qa.json` — structured test results with fields:
  - `inventory`: array of items with `id`, `description`, `source` (spec/control/state), `status` (pass/fail/skip), `evidence_path`
  - `summary`: total items, passed, failed, skipped
  - `exploratory_notes`: what the exploratory pass covered and any findings
  - `sha`: git commit SHA at time of testing
  - `visual_dedup`: whether visual checks were skipped due to design-audit coverage
- `.quality/proof/recordings/*.gif` — GIF recordings of each flow (named to match inventory item IDs)
- `.quality/proof/recordings/*.png` — screenshots of issues, error states, or visual verification

## Integration with Ship

The ship skill includes QA recordings in the PR description under a `## Demo` section. Each GIF shows the feature being exercised with the inventory item it validates. The signoff checklist status is included in the proof summary.
