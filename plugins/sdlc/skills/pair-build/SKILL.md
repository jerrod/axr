---
name: pair-build
description: "Use this skill when the user wants to implement, build, or code items from an existing plan or checklist — phrases like \"implement the plan\", \"build the plan items\", \"start coding\", \"implement the remaining items\", or \"pair-build\". Takes a structured plan and executes each item with a writer+critic pair so builds pass gates on the first run. Trigger on any intent to go from plan to working code. Do NOT trigger for planning, reviewing, shipping, or fixing tests — only active implementation of plan items."
argument-hint: "<feature description or task ID>"
allowed-tools: Bash(git *), Bash(gh *), Bash(sleep *), Bash(bun *), Bash(bunx *), Bash(pnpm *), Bash(cd * && bun *), Bash(cd * && bunx *), Bash(cd * && pnpm *), Bash(cd * && npx *), Bash(npx *), Bash(wc *), Bash(bin/*), Bash(bash plugins/*), Bash(python3 *), Read, Edit, Write, Glob, Grep, Agent
---

# Pair Build: Writer + Critic

## Audit Trail

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
[ -z "$PLUGIN_DIR" ] && PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log build sdlc:pair-build started --context="$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log build sdlc:pair-build completed --context="<summary>"`

## How It Works

For each plan item, deploy two agents:

1. **Writer** (sdlc:builder) — implements code + tests, does NOT commit
2. **Critic** (sdlc:critic) — reviews all changes against quality rules, reports APPROVED or FINDINGS

If the critic finds violations, the writer fixes them. When the critic approves, commit and run gates for proof artifacts. Gates should pass on the first run because the critic already caught violations.

```
implement → critic reviews → fix violations → commit → gates pass
```

## Commit Protocol (NON-NEGOTIABLE)

Same as standard build. Never leave a dirty tree. Conventional commit format. Stage specifically (`git add <files>`, never `-A` or `.`). One commit per plan item.

```bash
git commit -m "$(cat <<'EOF'
feat: <what this plan item accomplished>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

## Anti-Context-Rot Protocol

Same as standard build. Every phase transition requires checkpoint save. Every phase start requires checkpoint verify. Proof files are the source of truth. Plan items checked off only via `plan-progress.sh mark`.

**NEVER truncate output with `head`/`tail`.** When reading PR comments, CI logs, gate output, or any API response — read ALL of it. If the output is too large, redirect to a file and scan the file. Use `--jq` or `grep` to filter, not positional truncation. Missing one finding because you cut the output is a critical failure.

---

## Phase 0: Orient

### Verify gate scripts

```bash
if [ -z "$PLUGIN_DIR" ]; then
  echo "FATAL: sdlc scripts not found"
  exit 1
fi
echo "Plugin scripts at: $PLUGIN_DIR"
```

### Initialize proof directory

```bash
mkdir -p .quality/proof .quality/checkpoints
```

Add `.quality/` to `.gitignore` if not already present.

### Find the plan

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
git fetch origin
BRANCH=$(git branch --show-current)
REPO_NAME=$(_u=$(git remote get-url origin 2>/dev/null) || _u=""; if [ -n "$_u" ]; then basename "${_u%.git}"; else basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi)
bash "$PLUGIN_DIR/plan-progress.sh" find "$ARGUMENTS"
```

Resolution priority: exact branch match > `Branch:` field match > argument match > ask user > STOP.

Set `PLAN_FILE` and verify structure:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

### Read Design Constraints

If the plan header contains `**Design Constraints:**`, read and apply them to all styling, layout, and animation decisions.

### Branch handling

- On default branch with plan → create feature branch from plan title using semantic prefix (`feat/`, `fix/`, etc.). If the plan has an `Issue:` field, include the issue number in the branch name: `feat/123-short-description`. If the repo requires a ticket reference, it comes first: `PROJ-123/feat/short-description`. Never use personal initials.
- On feature branch with plan → verify plan matches branch
- No plan found → tell user to run `/sdlc:plan`

### Phase 0 Checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save orient "Phase 0 complete — plan found and verified"
```

---

## Phase 1: Pair Build

### Verify previous checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" verify orient
```

### Count unchecked items

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

Count the unchecked items (`- [ ]`). This determines the dispatch mode.

### Dispatch Mode

**3+ unchecked items → Tech Lead (concurrent pairs)**

Dispatch the tech-lead agent using the template (`skills/pair-build/tech-lead-prompt.md`):

```
Agent(subagent_type="sdlc:tech-lead", prompt="<filled tech-lead-prompt template>")
```

The tech-lead will:
1. Analyze plan items for independence (which items touch different files)
2. Group items into lanes (independent items run concurrently, dependent items sequentially)
3. Dispatch writer+critic pairs per lane (max 3 concurrent)
4. Handle fix loops, conflict detection, commit, gates, and checkpoints
5. Pull next batch when current batch completes (kanban)

When the tech-lead returns, verify all items are marked and proceed to Phase 2.

**1-2 unchecked items → Sequential pairs (no coordination overhead)**

For each plan item, run the writer+critic loop directly:

#### Step 1: Dispatch Writer

Using the writer prompt template (`skills/pair-build/writer-prompt.md`), dispatch a writer subagent:

```
Agent(subagent_type="sdlc:builder", prompt="<filled writer-prompt template>")
```

Provide: full plan item text, project context, working directory, existing patterns.

The writer implements the code and tests but does NOT commit. It reports back with: status, files changed, what was implemented, self-review findings.

If the writer reports BLOCKED or NEEDS_CONTEXT, handle it (provide context, break the task down, or escalate to user) before proceeding.

#### Step 2: Dispatch Critic

Using the critic prompt template (`skills/pair-build/critic-prompt.md`), dispatch a critic subagent:

```
Agent(subagent_type="sdlc:critic", prompt="<filled critic-prompt template>")
```

Provide: what was implemented (from writer's report), files changed, quality rules.

The critic reads all changed files and reports APPROVED or FINDINGS.

#### Step 3: Fix Loop (max 3 rounds)

If the critic reports FINDINGS:

1. Send the findings back to a writer subagent with instructions to fix the specific violations
2. Re-dispatch the critic to verify fixes
3. Repeat up to 3 rounds

If after 3 rounds the critic still has findings, escalate to the user:
> "Writer and critic could not resolve these violations after 3 rounds: [findings]. How would you like to proceed?"

#### Step 4: Commit

When the critic reports APPROVED:

```bash
git add <all files from writer's report>
git commit -m "$(cat <<'EOF'
feat: <plan item description>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

#### Step 5: Run Gates for Proof

```bash
bash "$PLUGIN_DIR/run-gates.sh" build
```

Gates should pass because the critic already caught violations. If a gate still fails (the critic missed something), fix it, commit the fix, and re-run.

#### Step 6: Collect Metrics

Metrics are already collected by `run-gates.sh build` in Step 5 (both per-gate and full summary). No separate call needed.

#### Step 7: Checkpoint and Mark

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save build "Completed: <item description>"
bash "$PLUGIN_DIR/plan-progress.sh" mark "$PLAN_FILE" "<search text matching the item>"
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

#### Repeat for each plan item.

---

## Phase 2: Coverage and Integration

### Verify previous checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" verify build
```

### Run ALL gates

```bash
bash "$PLUGIN_DIR/run-gates.sh" all
```

Fix any failures. Re-run until all pass.

### Verify coverage

```bash
bash "$PLUGIN_DIR/gate-coverage.sh"
cat .quality/proof/coverage.json
```

If any file is below 95%, write more tests and re-run.

### Verify plan integrity

```bash
bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"
```

### Collect proof

```bash
bash "$PLUGIN_DIR/collect-proof.sh"
```

### Phase 2 Checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save coverage "Phase 2 complete — all gates pass, coverage verified"
```

---

## Phase 3: Hand off to Review

### Verify checkpoints

```bash
bash "$PLUGIN_DIR/checkpoint.sh" drift
```

If drift detected, re-run affected gates.

### Verify plan complete

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"
```

### Force fresh gates before handing off

Cached gate results are NOT proof the current code is clean — delete the proof directory so every gate runs against the current SHA:

```bash
rm -rf .quality/proof
bash "$PLUGIN_DIR/run-gates.sh" all
bash "$PLUGIN_DIR/collect-proof.sh"
bash "$PLUGIN_DIR/checkpoint.sh" save coverage "Phase 3 fresh gate run — pre-review verification"
```

Every gate line must show `PASSED` (not `pass (cached)`) before proceeding. The checkpoint save overwrites Phase 2's coverage checkpoint with the current SHA so `/sdlc:review`'s drift check doesn't flag stale state.

### Hand off to `/sdlc:review`

Invoke `/sdlc:review`. The review skill dispatches 4 parallel reviewers (architect, security, correctness, style), walks findings with the user, re-runs gates after fixes, and hands off to `/sdlc:ship` when the review round returns zero open issues.

**Do NOT skip review.** Global CLAUDE.md mandates the workflow: build → review → ship. pair-build's job ends at handing off to review, not ship.
