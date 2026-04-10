---
name: build
description: "DEPRECATED — redirects to pair-build. Use /sdlc:pair-build directly."
argument-hint: "<feature description or task ID>"
allowed-tools: Bash(git *), Bash(gh *), Bash(sleep *), Bash(bun *), Bash(bunx *), Bash(pnpm *), Bash(cd * && bun *), Bash(cd * && bunx *), Bash(cd * && pnpm *), Bash(cd * && npx *), Bash(npx *), Bash(wc *), Bash(bin/*), Bash(bash plugins/*), Bash(python3 *), Read, Edit, Write, Glob, Grep, Agent
---

# DEPRECATED — Use pair-build

**This skill redirects to `/sdlc:pair-build`.** Invoke it now:

```
Skill("sdlc:pair-build", args="$ARGUMENTS")
```

Do NOT continue with the old build workflow below. Invoke pair-build and follow its instructions instead.

---

# Build: Quality-First Feature Development (Legacy)

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (already detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log build sdlc:build started --context "$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log build sdlc:build completed --context="<summary>"`

## Guiding Principle

**Correctness is the only measure that matters.** Speed is not a factor. Not a preference. Not a tiebreaker. If a gate takes 10 minutes to run, you run it. If a checkpoint reveals drift, you re-run everything from scratch. If coverage is 94.9%, you write more tests. There are no "close enough" results.

Every quality claim in this skill is **proven by an executable script** that writes machine-readable proof to `.quality/proof/`. Claude's context window is ephemeral — proof files are not. If you did not run the script, you did not prove anything.

## Commit Protocol (NON-NEGOTIABLE)

**Never leave a dirty tree.** Every phase transition, every plan item completion, every fix — commit immediately with conventional commit format. Do not accumulate uncommitted changes. Do not ask the user what to do with uncommitted code. Do not wait for a "good stopping point." The stopping point is NOW.

```
feat: <description>      — new functionality
fix: <description>       — bug fix
refactor: <description>  — restructuring without behavior change
test: <description>      — adding or updating tests
chore: <description>     — maintenance, config, scaffolding
```

**Commit granularity:** One commit per plan item or logical unit of work. Each commit should be independently deployable. If you implemented a feature and wrote its tests, that's ONE commit (not two). If you fixed a lint issue, commit it immediately — don't batch it with the next feature.

**Stage specifically:** `git add <files>` — never `git add -A` or `git add .`

**Commit message format:**
```bash
git commit -m "$(cat <<'EOF'
feat: add user authentication endpoint

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

## Anti-Context-Rot Protocol

Context rot is when Claude's adherence to quality gates degrades as conversations grow longer. It manifests as:
- Estimating coverage instead of measuring it
- Skipping gates that were "already checked" (but code changed since)
- Declaring tests pass without running them
- Rationalizing why a gate doesn't apply
- Checking off plan items without running gates first

**Prevention:**
1. **Every phase transition requires a checkpoint save.** You MUST run `checkpoint.sh save <phase>` after gates pass and BEFORE starting the next phase.
2. **Every phase START requires a checkpoint verify.** You MUST run `checkpoint.sh verify <previous-phase>` to confirm no drift occurred.
3. **If code changes after a checkpoint, ALL gates for the current phase must re-run.** No exceptions. Check with `checkpoint.sh drift`.
4. **Never estimate. Always measure.** If a gate script exists, run it. If you catch yourself typing "should be" or "likely passes" — STOP and run the script instead.
5. **Proof files are the source of truth.** If `.quality/proof/tests.json` says tests fail, tests fail — regardless of what you remember from earlier in the conversation.
6. **Plan items are checked off ONLY via `plan-progress.sh mark`.** Never manually edit a checkbox. The script verifies gates passed at the current SHA before allowing the mark.

---

## Phase 0: Environment and Plan

### Check for bin/ scripts

```bash
echo "bin/ scripts:"
for cmd in lint format test typecheck coverage; do
  [ -x "bin/$cmd" ] && echo "  ✓ bin/$cmd" || echo "  ✗ bin/$cmd (missing)"
done
```

If ANY are missing, tell the user: **"Run `/sdlc:bootstrap` to create high-signal bin/ scripts. Gate scripts will produce cleaner output."** Do not block — this is a recommendation, not a gate.

If ALL exist, check if they produce noisy output by running one and inspecting for ANSI codes or verbose success messages. If noisy, recommend **`/sdlc:bootstrap audit`**.

### Verify gate scripts are accessible:

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
fi

if [ -z "$PLUGIN_DIR" ]; then
  echo "FATAL: sdlc scripts not found"
  exit 1
fi

echo "Plugin scripts at: $PLUGIN_DIR"
ls "$PLUGIN_DIR"/*.sh
```

Initialize the proof directory:

```bash
mkdir -p .quality/proof .quality/checkpoints
echo "Proof directory initialized at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > .quality/proof/.init
```

**Add `.quality/` to `.gitignore` if not already present.**

### Find the plan

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
git fetch origin
BRANCH=$(git branch --show-current)
REPO_NAME=$(_u=$(git remote get-url origin 2>/dev/null) || _u=""; if [ -n "$_u" ]; then basename "${_u%.git}"; else basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi)

bash "$PLUGIN_DIR/plan-progress.sh" find "$ARGUMENTS"
```

**Resolution priority:**
1. Exact match at `~/.claude/plans/$REPO_NAME/$BRANCH.md`
2. Any `.md` file under `~/.claude/plans/` whose `Branch:` field matches `$BRANCH`
3. If `$ARGUMENTS` was provided, any plan whose title or Goal matches the arguments
4. If multiple candidates, show them and ask the user which one
5. If none found — **STOP. Tell the user to run `/sdlc:plan` first.**

Once found, set `PLAN_FILE` and verify its structure:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

The plan MUST have checkboxes (`- [ ]` items). If it has context but no checkboxes, tell the user to run `/sdlc:plan adopt` to convert it.

### Read Design Constraints

If the plan header contains a `**Design Constraints:**` field, read it before writing any frontend code. These constraints define the visual direction agreed during brainstorm — font choices, palette direction, motion intent, composition approach. Apply them to all component styling, layout decisions, font choices, color values, and animation implementation. They are not suggestions — they are the agreed design language for this project.

If the plan header has no Design Constraints field, proceed normally — this is a non-visual feature or brainstorm was skipped.

### Branch handling

- **On default branch with no plan** → tell user to run `/sdlc:plan` to create one
- **On default branch with a plan** → create feature branch from plan title, then proceed
- **On feature branch with plan** → verify plan matches branch, then proceed
- **On feature branch, no plan** → tell user to run `/sdlc:plan` to adopt or create one

### Phase 0 Checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save orient "Phase 0 complete — plan found and verified"
```

---

## Phase 1: Build with Continuous Validation

### Verify previous checkpoint before starting

```bash
bash "$PLUGIN_DIR/checkpoint.sh" verify orient
```

If this fails, re-run Phase 0. No exceptions.

### Quality Guardrails (enforced continuously)

These are hard stops. If code violates any of these, **STOP and fix before writing the next line.**

- **File size**: max 300 lines — split immediately
- **Function size**: max 50 lines — extract sub-functions immediately
- **Cyclomatic complexity**: max 8 — extract conditional logic immediately
- **Module-level code**: max 50 lines
- **Dead code**: No unused imports, functions, variables, commented-out code
- **Naming**: PascalCase components, camelCase functions, UPPER_SNAKE_CASE constants, boolean conditions
- **Lint suppressions**: ZERO. Fix the underlying issue.
- **DRY**: Check for existing utilities before writing new ones
- **Single responsibility**: One class per file, one job per module

**Fix violations immediately. Not later. Not in review. Now.**

**ABSOLUTE BAN — "Pre-existing" framing:** There is no such thing as a "pre-existing issue." If a gate flags it, fix it. Do not classify violations by when they were introduced. Do not create a "Pre-existing Issues" section. A gate failure is a gate failure — it has a fix, not an origin story.

### Test File Gate (MANDATORY — BLOCKING)

Every new source file MUST have a corresponding test file BEFORE you commit it.

**Prohibited rationalizations:**
- "No existing test files" → WRONG. Use Glob to verify. Write the first ones.
- "Thin UI wrappers" → WRONG. New file = new tests.
- "Tested indirectly" → WRONG. Direct tests required.
- "I'll write tests in Phase 2" → WRONG. Tests ship in same commit.
- "The real logic is in the backend" → WRONG. Frontend has testable behavior.

### Build Loop: Implement → Validate → Mark

For each plan item, follow this loop:

#### 1. Implement the item

Write the code. Write the tests. Follow the guardrails above.

#### 2. Run gates

```bash
bash "$PLUGIN_DIR/run-gates.sh" build
```

If any gate fails, **STOP and fix.** Do not continue building with failing gates.

#### 3. Commit IMMEDIATELY

Do not proceed without committing. Stage the specific files and commit with conventional format:

```bash
git add <source-files> <test-files>
git commit -m "$(cat <<'EOF'
feat: <what this plan item accomplished>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**This is not optional. This is not "when convenient." Commit NOW, before saving the checkpoint.**

#### 4. Save checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save build "Completed: <item description>"
```

#### 5. Mark the plan item done (PROOF-ANCHORED)

```bash
bash "$PLUGIN_DIR/plan-progress.sh" mark "$PLAN_FILE" "<search text matching the item>"
```

This script will:
- Verify the latest checkpoint exists and passed
- Verify the checkpoint SHA matches HEAD (no code drift)
- Transform `- [ ] item` → `- [x] item <!-- proof: build-latest -->`
- **REFUSE to mark if gates haven't passed** — this is the enforcement mechanism

**NEVER manually edit a checkbox from `[ ]` to `[x]`.** Always use the script.

#### 6. Show progress

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

#### Repeat for each plan item.

---

## Phase 2: Coverage and Integration

### Verify previous checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" verify build
```

### 2a. Run ALL gates

```bash
bash "$PLUGIN_DIR/run-gates.sh" all
```

Every gate must pass. If any fails, fix and re-run. Do not proceed with failures.

### 2b. Verify test file existence (BLOCKING GATE)

The `gate-tests.sh` script checks this. If its proof file shows missing tests, STOP. Write them.

### 2c. Measure coverage (BLOCKING GATE)

The `gate-coverage.sh` script measures this. **ACTUALLY RUN coverage. Do not estimate. Do not assume. Do not declare "should be fine."**

```bash
bash "$PLUGIN_DIR/gate-coverage.sh"
cat .quality/proof/coverage.json
```

If ANY file is below 95%, write more tests and re-run.

### 2d. Integration check

- Does it integrate correctly with existing code?
- Edge cases at module boundaries?
- Run the application if possible and verify the feature works.

### 2e. Verify plan integrity

```bash
bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"
```

This verifies ALL checked items have valid, non-stale proof anchors. If any item was checked without proof or has drifted, the check fails.

### 2f. Collect proof

```bash
bash "$PLUGIN_DIR/collect-proof.sh"
```

This generates `.quality/proof/PROOF.md` — the content that will go into the PR description.

### Phase 2 Checkpoint

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save coverage "Phase 2 complete — all gates pass, coverage verified, plan integrity confirmed"
```

---

## Phase 3: Hand off to Review

### Verify ALL previous checkpoints

```bash
bash "$PLUGIN_DIR/checkpoint.sh" drift
```

If any drift detected, re-run affected gates. Do not hand off with stale proof.

### Verify plan is complete

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"
```

All items must be checked with valid proof. If unchecked items remain, either implement them or discuss with the user about descoping.

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

**Do NOT skip review.** Global CLAUDE.md mandates the workflow: build → review → ship. build's job ends at handing off to review, not ship.

The proof report MUST be included in the PR description under a `## Quality Proof` section. This makes every quality claim independently verifiable by reviewers.
