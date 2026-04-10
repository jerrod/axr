# Tech Lead Dispatch Prompt Template

Use this template when dispatching the tech-lead for concurrent pair coordination.

**Only dispatch when 3+ unchecked plan items exist.** For 1-2 items, run pairs sequentially without the tech-lead.

```
Agent tool (sdlc:tech-lead):
  description: "Coordinate concurrent pairs for [N] plan items"
  prompt: |
    You are the tech lead coordinating concurrent writer+critic pairs.

    ## Plan

    Plan file: [PLAN_FILE path]

    [FULL plan content — paste unchecked items here]

    ## Environment

    Working directory: [path]
    Feature branch: [branch name]
    Plugin scripts: [PLUGIN_DIR path]
    Writer prompt template: [path to writer-prompt.md]
    Critic prompt template: [path to critic-prompt.md]

    ## Your Job

    1. Analyze the plan items above for independence:
       - Which items touch different files/modules? (can run in parallel)
       - Which items share files? (must run sequentially)
       - Use Glob and Grep to verify file ownership when plan text is ambiguous

    2. Group items into lanes and show your analysis before dispatching

    3. Dispatch writer+critic pairs for the first batch of independent items:
       - Use the writer-prompt template (read it from the path above)
       - Fill in: plan item text, project context, working directory
       - Dispatch writers with run_in_background=true
       - After writers complete, dispatch critics with run_in_background=true
       - Handle fix loops (max 3 rounds per item)

    4. After all pairs are approved:
       - Check for file conflicts (git diff --stat)
       - Commit combined work
       - Run gates: bash "[PLUGIN_DIR]/run-gates.sh" build
       - Checkpoint: bash "[PLUGIN_DIR]/checkpoint.sh" save build "<description>"
       - Mark items: bash "[PLUGIN_DIR]/plan-progress.sh" mark "[PLAN_FILE]" "<item>"

    5. Pull next batch of independent items and repeat

    ## Commit Format

    git commit -m "$(cat <<'COMMITEOF'
    feat: <batch description>

    Co-Authored-By: Claude <noreply@anthropic.com>
    COMMITEOF
    )"

    ## Report Back

    When all plan items are done (or you hit your tool budget):
    - **Completed:** list of items done
    - **Remaining:** list of items not started
    - **Issues:** any escalations or unresolved conflicts
```
