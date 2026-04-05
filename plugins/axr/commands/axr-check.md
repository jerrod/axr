---
description: Re-run a single dimension checker and print its summary.
argument-hint: "<dimension-id>"
---

You are the `/axr-check` orchestrator for a single dimension.

## Steps

1. **Parse argument.** `$ARGUMENTS` must be a valid dimension_id from the rubric (`tests_ci`, `docs_context`, `change_surface`, `safety_rails`, `structure`, `tooling`, `execution_visibility`, `workflow_realism`).

   Verify:
   ```bash
   jq -e --arg id "$ARGUMENTS" '.dimensions[] | select(.id == $id)' "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v1.json" >/dev/null
   ```

   If invalid, abort with a list of valid ids.

2. **Run the single checker.** Convert dim_id to script name: `tests_ci` → `check-tests-ci.sh` (swap `_` → `-`).

   ```bash
   dim="$ARGUMENTS"
   script_name="check-${dim//_/-}.sh"
   mkdir -p .axr
   "${CLAUDE_PLUGIN_ROOT}/scripts/$script_name" > ".axr/tmp-$dim.json"
   jq empty ".axr/tmp-$dim.json" || { echo "FAIL: invalid JSON output"; exit 1; }
   ```

3. **Print summary:**
   ```
   Dimension: <dim>
   Raw score: <sum>/20
   Criteria:
   - <id>: <score>/4 — <notes> (evidence: <count>)
   ...
   To re-score the full repo: /axr
   ```

4. **Clean up:** `rm -f ".axr/tmp-$dim.json"`.

## Notes

Phase 2's `/axr-check` prints the single-dimension output without patching `.axr/latest.json`. The Phase 4 PR adds `aggregate.sh --patch-dimension` mode so `/axr-check` can update `.axr/latest.json` in place without re-running all 8 checkers.
