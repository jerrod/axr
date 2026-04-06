---
description: Score the current repository against the AXR rubric (all 9 dimensions, including judgment subagents).
allowed-tools: Bash, Read, Task
---

You are the `/axr` orchestrator. Score the current working directory (target repo) against the AXR rubric and write the results to `.axr/latest.{json,md}`.

## Steps

1. **Verify prerequisites.** Confirm `${CLAUDE_PLUGIN_ROOT}` is set and `${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v2.json` exists. If missing, abort with a clear error.

2. **Detect stack.** Run:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh" && axr_detect_stack'
   ```
   Capture the JSON array of stack tags.

3. **Prepare output dirs.** `mkdir -p .axr/tmp .axr/history`.

4. **Run all dimension checkers in parallel.** Each writes its JSON output to `.axr/tmp/<dimension_id>.json` (stdout only) and stderr to a separate file so checker warnings do not corrupt the JSON:

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

5. **Dispatch 5 judgment subagents in parallel.** Use the Task tool to dispatch all 5 agents concurrently. Each agent reads the target repo, scores its criteria cluster (0-3 only), and emits a JSON array. Write each output to `.axr/tmp/agent-<name>.json`.

   Dispatch these 5 Task calls **simultaneously** (do not wait for one before starting the next):

   - **docs-reviewer** -> `.axr/tmp/agent-docs.json`
     Prompt: "Score docs_context.3 and docs_context.5 for this repository. Output ONLY a JSON array of criterion objects per SCHEMA.md. No markdown wrapping."

   - **architecture-reviewer** -> `.axr/tmp/agent-architecture.json`
     Prompt: "Score change_surface.1, change_surface.2, change_surface.4, structure.1, structure.3, structure.4 for this repository. Output ONLY a JSON array of criterion objects per SCHEMA.md. No markdown wrapping."

   - **safety-reviewer** -> `.axr/tmp/agent-safety.json`
     Prompt: "Score safety_rails.1 and safety_rails.2 for this repository. Output ONLY a JSON array of criterion objects per SCHEMA.md. No markdown wrapping."

   - **observability-reviewer** -> `.axr/tmp/agent-observability.json`
     Prompt: "Score execution_visibility.1, execution_visibility.2, execution_visibility.4 for this repository. Output ONLY a JSON array of criterion objects per SCHEMA.md. No markdown wrapping."

   - **workflow-reviewer** -> `.axr/tmp/agent-workflow.json`
     Prompt: "Score tests_ci.2, workflow_realism.1, workflow_realism.2, workflow_realism.4 for this repository. Output ONLY a JSON array of criterion objects per SCHEMA.md. No markdown wrapping."

   After all 5 agents return, **write each agent's JSON output** to the corresponding file path above. Then verify each output parses:
   ```bash
   for f in .axr/tmp/agent-*.json; do
       jq empty "$f" || { echo "FAIL: agent output $f is invalid JSON" >&2; cat "$f"; exit 1; }
   done
   ```

6. **Aggregate with agent merge.** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate.sh" --merge-agents .axr/tmp .axr/tmp .axr
   ```

   This merges agent-draft scores into the mechanical dimension JSONs before computing final totals. The `--merge-agents .axr/tmp` flag tells aggregate.sh to read `agent-*.json` files from `.axr/tmp` (same dir as dimension JSONs — the filename prefix `agent-` prevents collisions).

7. **Print summary.** Read `.axr/latest.json` and print:
   ```
   AXR Score: <total_score>/100 · <band_label>
   Rubric: v<rubric_version> · Scored: <scored_at>

   <N> of 17 judgment criteria scored by agents (draft, needs human confirmation)
   <M> judgment criteria still defaulted to 1 (agent did not return output)

   Top 3 blockers:
   1. <blocker 1>
   2. <blocker 2>
   3. <blocker 3>

   Full report: .axr/latest.md
   Machine-readable: .axr/latest.json
   ```

   To compute N: count criteria in `.axr/latest.json` where `reviewer == "agent-draft"`.
   To compute M: count criteria where `defaulted_from_deferred == true`.

8. **Clean up.** `rm -rf .axr/tmp`.

## Failure modes

- Checker script exits non-zero -> capture stderr, report in summary, do not fail the run (partial score).
- Checker JSON fails schema invariants -> treat as score 1 for all its criteria, note dimension as incomplete.
- Agent fails to return valid JSON -> skip its criteria (they remain defaulted to 1). Log a warning but do not fail the overall run.
- `aggregate.sh` fails -> print its stderr, exit non-zero.
