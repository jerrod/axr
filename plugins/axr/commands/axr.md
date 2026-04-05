---
description: Score the current repository against the AXR rubric (all 8 dimensions).
allowed-tools: Bash, Read
---

You are the `/axr` orchestrator. Score the current working directory (target repo) against the AXR rubric and write the results to `.axr/latest.{json,md}`.

## Steps

1. **Verify prerequisites.** Confirm `${CLAUDE_PLUGIN_ROOT}` is set and `${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v1.json` exists. If missing, abort with a clear error.

2. **Detect stack.** Run:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh" && axr_detect_stack'
   ```
   Capture the JSON array of stack tags.

3. **Prepare output dirs.** `mkdir -p .axr/tmp .axr/history`.

4. **Run all 8 dimension checkers in parallel.** Each writes its JSON output to `.axr/tmp/<dimension_id>.json` (stdout only) and stderr to a separate file so checker warnings do not corrupt the JSON:

   ```bash
   for checker in "${CLAUDE_PLUGIN_ROOT}"/scripts/check-*.sh; do
       dim=$(basename "$checker" | sed -E 's/^check-(.+)\.sh$/\1/' | tr - _)
       "$checker" > ".axr/tmp/$dim.json" 2> ".axr/tmp/$dim.stderr" &
   done
   wait
   ```

   After `wait` completes, verify each `.axr/tmp/<dim>.json` is valid JSON:
   ```bash
   for f in .axr/tmp/*.json; do
       jq empty "$f" || { echo "FAIL: $f is invalid JSON" >&2; echo "--- stderr: ---"; cat "${f%.json}.stderr"; echo "--- stdout: ---"; cat "$f"; exit 1; }
   done
   ```

   Any non-empty stderr files should be surfaced in the summary but do not fail the run.

5. **Aggregate.** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate.sh" .axr/tmp .axr
   ```

6. **Print summary.** Read `.axr/latest.json` and print:
   ```
   AXR Score: <total_score>/100 · <band_label>
   Rubric: v<rubric_version> · Scored: <scored_at>
   Phase 2 mechanical-only: 18 of 40 criteria defaulted to 1 (Phase 3 judgment subagents will replace)

   Top 3 blockers:
   1. <blocker 1>
   2. <blocker 2>
   3. <blocker 3>

   Full report: .axr/latest.md
   Machine-readable: .axr/latest.json
   ```

7. **Clean up.** `rm -rf .axr/tmp`.

## Notes on Phase 2 scoring

Judgment criteria (18 of 40) are defaulted to score 1 per the "unknown defaults to 1" rubric rule and flagged `defaulted_from_deferred: true`. Phase 3 judgment subagents will replace these defaults with agent-draft scores. A Phase 2 score is a conservative lower-bound estimate.

Phase 2 `/axr` IS the mechanical-only fast path — until Phase 3 adds judgment dispatch, no `--fast` flag is needed because judgment criteria are already defaulted rather than dispatched.

The orchestrator MUST print this disclaimer in its summary output: `"Phase 2 mechanical-only: 18 of 40 criteria defaulted to 1 (Phase 3 judgment subagents will replace)"`.

## Failure modes

- Checker script exits non-zero → capture stderr, report in summary, do not fail the run (partial score).
- Checker JSON fails schema invariants → treat as score 1 for all its criteria, note dimension as incomplete.
- `aggregate.sh` fails → print its stderr, exit non-zero.
