---
name: dev
description: "Detect project quality state and determine the next sdlc phase. Runs diagnostics on branch, bin/ scripts, plans, gates, and PR status, then recommends a single action. Use when resuming work, starting fresh, or unsure what to do next. Trigger: 'what's next', 'continue', 'pick up where I left off', 'what should I do'."
argument-hint: "[optional: build|review|ship|bootstrap to force a phase]"
allowed-tools: Bash(git *), Bash(gh *), Bash(bash plugins/*), Bash(python3 *), Bash(bin/*), Bash(find *), Bash(ls *), Bash(cat *), Bash(wc *), Read, Glob, Grep, Agent
---

# sdlc:dev — Orchestration Loop

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log orchestration sdlc:dev started --context="$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log orchestration sdlc:dev completed --context="<summary of what was done>"`

This skill is an **orchestrator**. It diagnoses project state, spawns the appropriate worker agent, then re-diagnoses and continues until the workflow is complete or the user intervenes.

**Flow:** Diagnose → Delegate → Wait → Re-diagnose → Delegate → ... → Done

## Step 1: Detect sdlc Scripts

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
fi
echo "sdlc scripts: ${PLUGIN_DIR:-NOT FOUND}"
```

If not found, delegate to `sdlc:bootstrapper` and continue the loop after it returns.

---

## Step 2: Run Diagnostics

Run ALL of these checks:

### 2a. Repository state
```bash
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo "main")
BRANCH=$(git branch --show-current)
REPO=$(_u=$(git remote get-url origin 2>/dev/null) || _u=""; if [ -n "$_u" ]; then basename "${_u%.git}"; else basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi)
echo "repo:$REPO branch:$BRANCH default:$DEFAULT_BRANCH"
git status --porcelain
git log --oneline "origin/$DEFAULT_BRANCH"..HEAD 2>/dev/null | wc -l | xargs echo "commits ahead:"
```

### 2b. bin/ scripts
```bash
for cmd in lint format test typecheck coverage; do
  [ -x "bin/$cmd" ] && echo "✓ bin/$cmd" || echo "✗ bin/$cmd"
done
```

### 2c. Quality proof (if exists)
```bash
[ -d ".quality/proof" ] && ls .quality/proof/*.json 2>/dev/null | while read f; do
  gate_status=$(PF="$f" python3 -c "import json, os; print(json.load(open(os.environ['PF'])).get('status','?'))" 2>/dev/null)
  echo "  $(basename $f .json):$gate_status"
done || echo "no proof files"
```

### 2d. Spec and plan status
```bash
# Check for specs
SPEC=$(ls -t docs/specs/*.md 2>/dev/null | head -1)
[ -n "$SPEC" ] && echo "spec:$(basename $SPEC)" || echo "spec:none"

# Check for plan (~/.claude/plans/<repo>/ is canonical; plans are never committed)
PLAN_SLUG="${BRANCH//\//-}"
PLAN="$HOME/.claude/plans/$REPO/$PLAN_SLUG.md"
# Auto-create the workspace symlink if the canonical plan exists (idempotent)
[ -f "$PLAN" ] && bash "$PLUGIN_DIR/link-plan.sh" "$PLAN_SLUG" 2>/dev/null || true
[ -f "$PLAN" ] || PLAN=".quality/plans/$PLAN_SLUG.md"  # workspace symlink fallback
if [ -f "$PLAN" ]; then
  echo "plan:$PLAN_SLUG.md"
  grep -c '\- \[ \]' "$PLAN" | xargs echo "  unchecked:"
  grep -c '\- \[x\]' "$PLAN" | xargs echo "  checked:"
else
  echo "plan:none"
fi
```

### 2e. PR status
```bash
gh pr view --json number,state,title,reviewDecision 2>/dev/null || echo "no PR"
```

### 2f. Review ledger
```bash
LEDGER="$HOME/.claude/reviews/$REPO/$BRANCH.md"
[ -f "$LEDGER" ] && echo "review ledger exists" || echo "no review ledger"
```

---

## Step 2.5: Initialize Audit Trail (first iteration only)

On the **first iteration** of the orchestration loop, initialize the audit trail and write the execution plan:

```bash
bash "$PLUGIN_DIR/../scripts/audit-trail.sh" init "$ARGUMENTS"
```

Then generate the execution plan JSON based on diagnostic results. Write it to a **temp file** and register via the `plan` command (which validates and copies it to the final location):

```json
{
  "task": "<from $ARGUMENTS or user's request>",
  "created_at": "<ISO timestamp>",
  "git_branch": "<current branch>",
  "version": 1,
  "plugin_version": "<from plugin.json>",
  "initial_state": {
    "bin_scripts": ["<detected scripts>"],
    "missing_scripts": ["<missing scripts>"],
    "spec_exists": true,
    "plan_exists": false,
    "commits_ahead": 0,
    "pr_status": null
  },
  "planned_phases": [
    {
      "order": 1,
      "phase": "<phase name>",
      "agent": "sdlc:<agent>",
      "skills": ["sdlc:<skill>"],
      "reason": "<from decision matrix>"
    }
  ]
}
```

Use the decision matrix results to predict the full workflow path. Walk forward from current state.

```bash
# Write plan to temp file, then register (validates JSON + copies to final path)
PLAN_TMP="$(mktemp)"
cat > "$PLAN_TMP" << 'PLAN_JSON'
<your generated JSON here>
PLAN_JSON
bash "$PLUGIN_DIR/../scripts/audit-trail.sh" plan "$PLAN_TMP"
rm -f "$PLAN_TMP"
```

**Skip this step on subsequent iterations** (check if `.quality/audit/execution-plan.json` exists).

Before each agent delegation, log:
```bash
bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log <phase> sdlc:<agent> started --context="<one sentence why>"
```

After each agent returns, log:
```bash
bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log <phase> sdlc:<agent> completed --context="<summary>"
```

---

## Step 3: Decide

If `$ARGUMENTS` specifies a phase (build, review, ship, bootstrap, brainstorm), skip the decision matrix and delegate directly to that agent/skill (Step 4). Only use the forced phase for the **first iteration** — subsequent iterations use the decision matrix.

Otherwise, use this decision matrix:

| State | Agent to spawn |
|-------|----------------|
| No bin/ scripts (3+ missing) | `sdlc:bootstrapper` |
| On default branch, no changes | Ask user what they're working on — STOP the loop |
| On default branch, user describes new work | Invoke `sdlc:brainstorm` skill |
| User asks about performance, bottlenecks, antipatterns, N+1, caching (not test speed) | `sdlc:performance-auditor` |
| Feature branch, spec exists but no plan | Invoke `sdlc:writing-plans` skill |
| Feature branch, plan has unchecked items | `sdlc:builder` |
| Feature branch, plan complete or no plan, no review | `sdlc:reviewer` |
| Feature branch, reviewed, no PR | `sdlc:shipper` |
| PR exists, CI failing | `sdlc:shipper` |
| PR exists, review comments pending | `sdlc:shipper` |
| PR merged or all green, ready to merge | STOP the loop — ask user to confirm merge |
| Stale proof files | Run `bash "$PLUGIN_DIR/run-gates.sh" all` then reassess |

**Performance audit vs test optimization:** If the user mentions "tests are slow" or "speed up tests", route to `sdlc:builder` with `optimize-tests` skill. If the user mentions "app is slow", "performance audit", "bottlenecks", "N+1", "antipatterns", or "caching strategy", route to `sdlc:performance-auditor`.

## Step 4: Present State and Delegate

Show the user a brief status summary:

```
## State: <repo> (<branch>) — Iteration N
- Branch: N commits ahead of <default>
- bin/: N/5 present
- Plan: <status>
- Gates: <last run status>
- PR: <status>

## Delegating to: sdlc:<agent>
<One sentence explaining why>
```

Then spawn the worker agent using the Agent tool:

```
Agent(subagent_type="sdlc:<agent>", prompt="<context from diagnostics + what needs to be done>")
```

**Include diagnostic context in the agent prompt.** The worker agent starts with a fresh context — pass it:
- Current branch name and how many commits ahead
- Which bin/ scripts exist
- Current gate status (pass/fail per gate)
- Plan status (items remaining)
- PR status if applicable
- The specific task or user request if provided

---

## Step 5: Re-diagnose and Continue

After the worker agent returns:

1. **Show what the agent accomplished** — summarize its output in 2-3 sentences
2. **Re-run Step 2** (all diagnostics) to get fresh state
3. **Re-run Step 3** (decision matrix) with the updated state
4. **If the next phase is different**, go to Step 4 and delegate to the next agent
5. **If the state hasn't changed** (same phase recommended), STOP and report — something may be stuck

### Stop Conditions

Stop the loop when ANY of these are true:
- **PR is merged** — work is done
- **PR is open, CI green, review approved** — ask user to confirm merge
- **On default branch with no changes** — nothing to do
- **Same phase recommended twice in a row** — the agent didn't make progress; report and let user decide
- **User's original request is fulfilled** — the specific task from `$ARGUMENTS` is complete (agent confirmed it)

### Iteration Limit

Maximum **4 iterations** per `/sdlc:dev` invocation. If you reach 4 without hitting a stop condition, report current state and stop. The user can run `/sdlc:dev` again to continue.

**Do NOT just recommend — actually spawn agents and drive the workflow forward.** The user invoked `/sdlc:dev` because they want work done, not a report.
