---
description: Score the current repository against the AXR rubric (all 9 dimensions, including judgment subagents).
allowed-tools: Bash, Read, Task
---

You are the `/axr` orchestrator. Score the current working directory (target repo) against the AXR rubric and write the results to `.axr/latest.{json,md}`.

## Steps

1. **Verify prerequisites.** Confirm `${CLAUDE_PLUGIN_ROOT}` is set and `${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v3.json` exists. If missing, abort with a clear error.

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
     Prompt: "Score docs.subsystem-readmes and docs.glossary for this repository. Output ONLY a JSON array of criterion objects per your output contract. No markdown wrapping."

   - **architecture-reviewer** -> `.axr/tmp/agent-architecture.json`
     Prompt: "Score change.locatable-logic, change.explicit-boundaries, change.examples, structure.module-boundaries, structure.scoped-files, structure.searchable-naming for this repository. Output ONLY a JSON array of criterion objects per your output contract. No markdown wrapping."

   - **safety-reviewer** -> `.axr/tmp/agent-safety.json`
     Prompt: "Score safety.hitl-checkpoints and safety.reversible-default for this repository. Output ONLY a JSON array of criterion objects per your output contract. No markdown wrapping."

   - **observability-reviewer** -> `.axr/tmp/agent-observability.json`
     Prompt: "Score visibility.structured-logging, visibility.telemetry, visibility.local-diagnostics for this repository. Output ONLY a JSON array of criterion objects per your output contract. No markdown wrapping."

   - **workflow-reviewer** -> `.axr/tmp/agent-workflow.json`
     Prompt: "Score tests.boundary-coverage, workflow.fixtures, workflow.sandbox-parity, workflow.golden-paths for this repository. Output ONLY a JSON array of criterion objects per your output contract. No markdown wrapping."

   As each agent returns, **immediately write its JSON output** to the corresponding file path above. Then verify each output parses:
   ```bash
   for f in .axr/tmp/agent-*.json; do
       jq empty "$f" || { echo "FAIL: agent output $f is invalid JSON" >&2; cat "$f"; exit 1; }
   done
   ```

6. **Aggregate with agent merge.** Run:
   ```bash
   # aggregate.sh --merge-agents <agent-dir> <input-dir> <output-dir>
   "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate.sh" --merge-agents .axr/tmp .axr/tmp .axr
   ```

   This merges agent-draft scores into the mechanical dimension JSONs before computing final totals. The `--merge-agents .axr/tmp` flag tells aggregate.sh to read `agent-*.json` files from `.axr/tmp` (same dir as dimension JSONs — the filename prefix `agent-` prevents collisions).

7. **Print summary.** Read `.axr/latest.json` and print:
   ```
   AXR Score: <total_score>/100 · <band_label>
   Rubric: v<rubric_version> · Scored: <scored_at>

   <N> of <J> judgment criteria scored by agents (draft, needs human confirmation)
   <M> judgment criteria still defaulted to 1 (agent did not return output)

   To compute J (total judgment criteria):
   ```bash
   jq '[.dimensions[].criteria[] | select(.checker_type=="judgment")] | length' "${CLAUDE_PLUGIN_ROOT}/rubric/rubric.v3.json"
   ```

   Top 3 blockers:
   1. <blocker 1>
   2. <blocker 2>
   3. <blocker 3>

   Full report: .axr/latest.md
   Machine-readable: .axr/latest.json
   ```

   To compute N: count criteria in `.axr/latest.json` where `reviewer == "agent-draft"`.
   To compute M: count criteria where `defaulted_from_deferred == true`.

8. **Generate badge.** Build a shields.io badge URL from the score and band, and offer to add it to the repo's README:

   ```bash
   score=$(jq '.total_score' .axr/latest.json)
   band=$(jq -r '.band.label' .axr/latest.json)

   # Color by band
   case "$band" in
       Agent-Native)    color="brightgreen" ;;
       Agent-Ready)     color="green" ;;
       Agent-Assisted)  color="yellow" ;;
       Agent-Hazardous) color="orange" ;;
       *)               color="red" ;;
   esac

   # URL-encode spaces/hyphens for shields.io
   band_encoded="${band// /_}"
   badge_url="https://img.shields.io/badge/AXR-${score}%2F100_${band_encoded}-${color}"
   badge_md="[![AXR Score](${badge_url})](https://github.com/jerrod/axr)"
   ```

   Print the badge markdown and ask if the user wants it added to their README:

   ```
   AXR Badge:
   [![AXR Score](<badge_url>)](https://github.com/jerrod/axr)

   Add to your README? (paste this at the top)
   <badge_md>
   ```

   If the user says yes, read `README.md` and prepend the badge markdown on the line after the first `# ` heading. If no README exists, note it and skip.

9. **Clean up.** `rm -rf .axr/tmp`.

## Failure modes

- Checker script exits non-zero -> capture stderr, report in summary, do not fail the run (partial score).
- Checker JSON fails schema invariants -> treat as score 1 for all its criteria, note dimension as incomplete.
- Agent fails to return valid JSON -> skip its criteria (they remain defaulted to 1). Log a warning but do not fail the overall run.
- `aggregate.sh` fails -> print its stderr, exit non-zero.
