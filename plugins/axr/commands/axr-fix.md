---
description: Fix low-scoring AXR criteria by applying automated remediations.
argument-hint: "<criterion-id | dimension-id | blockers>"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

You are the `/axr-fix` orchestrator. Read `.axr/latest.json`, identify low-scoring criteria, apply remediations, re-score affected dimensions, and report deltas.

## Steps

1. **Verify prerequisites.** Confirm `.axr/latest.json` exists. If not, tell the user to run `/axr` first and abort.

2. **Parse arguments.** `$ARGUMENTS` determines the fix scope:

   - `blockers` — fix the top 3 blockers from `.axr/latest.json` (the `blockers[]` array, excluding any with `defaulted_from_deferred: true`)
   - A criterion id (e.g., `docs_context.1`) — fix that single criterion
   - A dimension id (e.g., `safety_rails`) — fix all criteria in that dimension scoring ≤ 1

   If `$ARGUMENTS` is empty, abort with usage: `/axr-fix <blockers | criterion-id | dimension-id>`.

   Validate against the rubric:
   ```bash
   # Empty check
   [ -n "$ARGUMENTS" ] || { echo "Usage: /axr-fix <blockers | criterion-id | dimension-id>"; exit 1; }

   # Check if it's "blockers"
   if [ "$ARGUMENTS" = "blockers" ]; then
       echo "Mode: fix top 3 blockers"
   # Check if it's a criterion id (contains a dot followed by digits)
   elif echo "$ARGUMENTS" | grep -qE '^\w+\.\d+$'; then
       jq -e --arg id "$ARGUMENTS" \
           '[.dimensions[].criteria[] | select(.id == $id)] | length > 0' \
           "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v2.json" >/dev/null \
           || { echo "Unknown criterion: $ARGUMENTS"; exit 1; }
       echo "Mode: fix criterion $ARGUMENTS"
   # Check if it's a dimension id
   else
       jq -e --arg id "$ARGUMENTS" '.dimensions[] | select(.id == $id)' \
           "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v2.json" >/dev/null \
           || { echo "Unknown dimension or criterion: $ARGUMENTS"; exit 1; }
       echo "Mode: fix dimension $ARGUMENTS"
   fi
   ```

3. **Build target list.** Read `.axr/latest.json` and collect criteria to fix:

   For `blockers` mode (blockers array is pre-filtered by aggregate.sh to exclude `defaulted_from_deferred`, but filter defensively):
   ```bash
   jq -r '[.blockers[] | select(.defaulted_from_deferred != true)][:3][] | .id' .axr/latest.json
   ```

   For a criterion id: use that id alone. If its current score is already ≥ 3, report "Already scoring well (<score>/4) — skipping" and stop.

   For a dimension id:
   ```bash
   jq -r --arg dim "$ARGUMENTS" \
       '.dimensions[$dim].criteria[] | select(.score <= 1) | .id' \
       .axr/latest.json
   ```

   If the target list is empty (all criteria already ≥ 3 for dimension mode, or blockers array empty), report "Nothing to fix — all targets already scoring well" and stop.

   Print the target list with current scores before starting:
   ```
   Targets (<N> criteria):
     <id>: score <S>/4 — <name>
     ...
   ```

4. **Apply remediations.** For each target criterion:

   a. Read `${CLAUDE_PLUGIN_ROOT}/docs/remediation-strategies.md` and find the section headed `## <criterion_id>` matching the target (e.g., `## docs_context.1`). If no section exists for this criterion, print "No automated remediation available for <id>" and skip to the next target.

   b. Execute the strategy described in that section. The strategy describes what files to create or modify — follow it using Write/Edit/Glob/Grep tools, adapting to the target repo's actual structure and stack. The strategy is a guide, not a rigid script.

   c. After applying the fix, print what was done:
   ```
   Fixed <id>: <one-line summary of what was created/modified>
   ```

5. **Save pre-fix baseline.** BEFORE re-scoring any dimensions, save the current scores for delta comparison. This must happen before step 6 because each `--patch-dimension` call archives `latest.json` to history — intermediate states would corrupt the baseline if we saved it later.

   ```bash
   cp .axr/latest.json .axr/tmp-baseline.json
   ```

6. **Re-score affected dimensions.** Collect the unique set of dimension ids touched by the remediations. For each:

   ```bash
   dim="<dimension_id>"
   script_name="check-${dim//_/-}.sh"
   "${CLAUDE_PLUGIN_ROOT}/scripts/$script_name" > ".axr/tmp-$dim.json"
   jq empty ".axr/tmp-$dim.json" || { echo "FAIL: checker output for $dim is invalid JSON"; continue; }

   # Patch latest.json incrementally
   "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate.sh" --patch-dimension "$dim" ".axr/tmp-$dim.json" .axr/latest.json
   rm -f ".axr/tmp-$dim.json"
   ```

7. **Report deltas.** After all dimensions are re-scored, diff against the saved baseline:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/diff-scores.sh" .axr/tmp-baseline.json .axr/latest.json
   rm -f .axr/tmp-baseline.json
   ```

   Print summary:
   ```
   ## /axr-fix Results

   Score: <from> → <to> (<+delta>)
   Band: <from_band> → <to_band>

   Criteria improved (<count>):
     <id>: <from_score> → <to_score> — <name>
     ...

   Criteria unchanged (<count>):
     <id>: <score> — <name> (remediation applied but score unchanged)
     ...

   Remaining blockers (<count>):
     1. <blocker>
     ...
   ```

8. **Suggest next steps.**
   - If score improved and blockers remain, suggest: "Run `/axr-fix blockers` again to continue improving."
   - If score improved and no blockers, suggest: "Run `/axr` for a full re-score to verify."
   - If no improvement, suggest: "The remaining low-scoring criteria may need manual attention. Run `/axr` to review."

## Failure modes

- `.axr/latest.json` missing → abort with: "No scoring data found. Run `/axr` first to generate scores."
- Unknown criterion or dimension id → abort with list of valid ids from the rubric.
- No remediation strategy for a criterion → skip with message "No automated remediation available for <id>", continue to next target.
- Checker script fails after remediation → report the error, do not update scores for that dimension, continue with remaining dimensions.
- All targeted criteria already score ≥ 3 → report "Nothing to fix — all targets already scoring well" and stop.
- `$ARGUMENTS` is empty → abort with usage: `/axr-fix <blockers | criterion-id | dimension-id>`.
