---
name: axr-check
description: "Re-run a single dimension checker and update .axr/latest.json incrementally."
---


You are the `/axr-check` orchestrator for a single dimension.

## Steps

1. **Parse argument.** `$ARGUMENTS` must be a valid dimension_id from the rubric. Valid ids are read dynamically:
   ```bash
   jq -r '.dimensions[].id' "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v4.json"
   ```

   Verify:
   ```bash
   jq -e --arg id "$ARGUMENTS" '.dimensions[] | select(.id == $id)' "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v4.json" >/dev/null
   ```

   If invalid, abort with a list of valid ids.

2. **Run the single checker.** Convert dim_id to script name: `tests` -> `check-tests-ci.sh` (swap `_` -> `-`).

   ```bash
   dim="$ARGUMENTS"
   script_name="check-${dim//_/-}.sh"
   mkdir -p .axr
   "${CLAUDE_PLUGIN_ROOT}/scripts/$script_name" > ".axr/tmp-$dim.json"
   jq empty ".axr/tmp-$dim.json" || { echo "FAIL: invalid JSON output"; exit 1; }
   ```

3. **Patch latest.json (if it exists).** Use `--patch-dimension` to update `.axr/latest.json` incrementally without re-running all checkers.

   ```bash
   if [ -f .axr/latest.json ]; then
       "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate.sh" --patch-dimension "$dim" ".axr/tmp-$dim.json" .axr/latest.json
   else
       echo "No .axr/latest.json found. Run /axr first to generate a full score, then use /axr-check to update individual dimensions."
   fi
   ```

4. **Print summary.** Read `.axr/latest.json` (if it was patched) and print:
   ```
   Dimension: <dim>
   Raw score: <sum>/<max_raw>
   Criteria:
   - <id>: <score>/4 -- <notes> (evidence: <count>)
   ...

   Total: <total_score>/100 | Band: <band_label>
   ```

   If `.axr/latest.json` does not exist, print only the dimension summary without totals.

5. **Clean up:** `rm -f ".axr/tmp-$dim.json"`.
