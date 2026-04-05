---
description: Score the current repo's Agent eXecution Readiness against the AXR rubric.
allowed-tools: Bash, Read
---

You are the `/axr` orchestrator for the rq-axr plugin. In **Phase 1**, the orchestrator proves the scripts-first architecture end-to-end by scoring **one** dimension (`docs_context`) and printing a summary. When Phase 2 lands, this command runs all 8 dimension checkers and writes `.axr/latest.{json,md}`.

## Strict DO NOT list

- DO NOT run the other 7 dimension checkers. They do not exist yet.
- DO NOT write `.axr/latest.json` or `.axr/latest.md`. Those land in Phase 2.
- DO NOT invent scores, synthesise evidence, or fill in judgment criteria yourself.
- DO NOT edit the rubric or any script while running.

## Steps

1. **Read the rubric.** `Read ${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v1.json`. Extract `version` and the `docs_context` dimension (its `name`, `weight`, and the 5 criteria: id + name + checker_type).

2. **Detect stack.** Run:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh" && axr_detect_stack'
   ```
   The path is double-quoted inside the `bash -c` body so a `CLAUDE_PLUGIN_ROOT` value containing spaces or shell metacharacters does not break the source command. Capture the JSON array.

3. **Run the one Phase-1 checker.** From the user's repo root (the current working directory), run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/check-docs-context.sh"
   ```
   The script path is double-quoted for the same reason. The script emits a single JSON object to stdout. Capture it.

4. **Merge against the rubric.** For each of the 5 criteria in the rubric's `docs_context` dimension, look up the matching criterion in the script output by `id`. Every mechanical criterion must have a non-null integer `score` (0–4). Every judgment criterion must have `score: null` and `deferred: true`.

5. **Compute the partial dimension score.** Sum only the mechanical criterion scores. Max possible for this dimension in Phase 1 = `(mechanical_count × 4)`. Partial dimension score = `(sum / max) × weight`. Report it as "partial (mechanical-only)" — the full score requires judgment criteria, which Phase 1 does not resolve.

6. **Print the summary.** Format:
   ```
   AXR Phase 1 — docs_context only
   Rubric version: <version>
   Detected stack: <stack JSON>
   Dimension: docs_context (weight <N>)

   ID                 | Name                          | Score | Evidence | Notes
   -------------------+-------------------------------+-------+----------+------
   docs_context.1     | <name>                        | <s>   | <count>  | <notes>
   docs_context.2     | <name>                        | <s>   | <count>  | <notes>
   docs_context.3     | <name>                        | DEFER | -        | deferred to judgment
   docs_context.4     | <name>                        | <s>   | <count>  | <notes>
   docs_context.5     | <name>                        | DEFER | -        | deferred to judgment

   Mechanical score: <sum>/<max> → partial dimension score: <X.Y>/<weight>
   PHASE 1: one dimension scored; 7 remaining for Phase 2
   ```

7. **Stop.** Do not archive, commit, or write output files.

## Failure modes

- Script exits non-zero → print stderr verbatim, stop.
- Script output fails `jq empty` → print raw output, stop.
- A mechanical criterion is missing from the output, or a judgment criterion is missing the `deferred: true` flag → flag it in the summary under a `SCHEMA VIOLATION` line and still print the rest.
