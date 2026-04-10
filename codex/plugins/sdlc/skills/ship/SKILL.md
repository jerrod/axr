---
name: ship
description: "Use this skill whenever the user wants to open, update, or push a pull request. Triggers for: creating a new PR from a feature branch, addressing reviewer feedback and re-pushing, updating a PR description with fresh verification results, or any \"ship it\" / \"create the PR\" / \"push and open a PR\" request. Runs quality gates, collects proof artifacts into the PR description, rebases on main, watches CI, and asks before merging. Do NOT use for code review, building features, or brainstorming."
argument-hint: "[optional PR title]"
allowed-tools: Bash(git *), Bash(gh *), Bash(sleep *), Bash(bun *), Bash(bunx *), Bash(pnpm *), Bash(cd * && bun *), Bash(cd * && bunx *), Bash(cd * && pnpm *), Bash(cd * && npx *), Bash(npx *), Bash(wc *), Bash(bin/*), Bash(bash plugins/*), Bash(python3 *), Read, Edit, Write, Glob, Grep, Agent
---

# Ship: Full PR Lifecycle with Proof (Plugin Edition)

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (detected in Step 2 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log ship sdlc:ship started --context "$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log ship sdlc:ship completed --context="<summary of what was done>"`

## Guiding Principle

**Correctness is the only measure that matters.** Speed is irrelevant. A PR that ships in 2 minutes with a missed regression is worse than a PR that takes 2 hours and lands clean. Every quality claim in the PR description is backed by a proof artifact that any reviewer can independently verify by re-running the scripts.

## Commit Protocol (NON-NEGOTIABLE)

**Never leave a dirty tree.** Every fix, every gate resolution, every CI fix — commit immediately with conventional commit format. Do not ask the user what to do with uncommitted changes. Commit them.

```
fix: <description>       — bug fix, gate fix, CI fix
refactor: <description>  — restructuring
test: <description>      — test additions
chore: <description>     — config, formatting
```

**Stage specifically:** `git add <files>` — never `git add -A` or `git add .`

## Anti-Context-Rot Protocol

The ship phase is where context rot is most dangerous — Claude has been working for a while, wants to "finish up," and starts cutting corners. Watch for:
- "Tests passed earlier" → Did code change since? Run them again.
- "Coverage was 97%" → Was that before or after the last fix? Measure again.
- "Lint was clean" → After the review fixes? Run again.

**Rule: Re-run ALL gates immediately before creating/updating the PR.** Not from memory. Not from cached proof. Fresh execution, fresh proof files, fresh checkpoint.

**ABSOLUTE BAN — "Pre-existing" framing:** Never categorize gate failures or findings as "pre-existing," "on main," or "not introduced by this PR" in any output, PR description, or summary. If a gate flags it, fix it. There are no origin stories — only fixes.

---

## Step 1: Get onto a feature branch

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
git fetch origin
BRANCH=$(git branch --show-current)
```

**If on default branch:** Check for changes, generate branch name, create branch.
**If on feature branch:** Check uncommitted changes, existing PR, commits ahead.
**If uncommitted changes:** Commit them immediately with an appropriate conventional commit message. Do not ask.

### Branch naming

Branch names MUST use a semantic prefix: `feat/`, `fix/`, `chore/`, `refactor/`, `perf/`, `ci/`, `test/`, `docs/`, `build/`.
If the repo requires a Jira/ticket reference, it comes first: `PROJ-123/feat/short-description`.
If the plan has an `Issue:` field, include the issue number: `feat/123-short-description`.
Never use personal initials (`jt/`, `ab/`, etc.).

### Argument parsing

Check `$ARGUMENTS` for flags:
- `--skip-pr-feedback` — if present, set `SKIP_PR_FEEDBACK=true`. Remove the flag from arguments before further processing.

---

## Step 2: Pre-flight — Run ALL Quality Gates

This replaces the manual pre-flight audit. Scripts are more thorough and don't get tired.

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
fi

bash "$PLUGIN_DIR/run-gates.sh" ship
```

**If ANY gate fails, STOP.** Fix the issue. Re-run ALL gates (not just the failed one — fixes can introduce new violations). Repeat until all gates pass.

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save ship-preflight "Pre-flight gates passed"
```

---

## Step 3: Run quality pipeline (format, lint, typecheck, tests)

The `gate-lint.sh` and `gate-tests.sh` scripts cover this, but also run the project's own pipeline to catch anything project-specific:

1. **Format**: Run the project formatter
2. **Lint**: Run the linter — zero warnings
3. **Type check**: `tsc --noEmit` or equivalent
4. **Tests**: Full test suite

If anything fails, fix and re-run ALL gates:

```bash
bash "$PLUGIN_DIR/run-gates.sh" ship
```

---

## Step 4: Verify test coverage (BLOCKING GATE)

**This step is MANDATORY. You CANNOT skip it. Skipping has caused untested code to reach main.**

```bash
bash "$PLUGIN_DIR/gate-tests.sh"
bash "$PLUGIN_DIR/gate-coverage.sh"
```

Read the proof files:

```bash
cat .quality/proof/tests.json
cat .quality/proof/coverage.json
```

- If `tests.json` shows missing test files → STOP. Write tests. Re-run.
- If `coverage.json` shows any file below 95% → STOP. Write tests. Re-run.
- If `tests.json` shows test failures → STOP. Fix. Re-run.

**Do not proceed with failing tests or incomplete coverage. Ever.**

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save ship-coverage "Coverage gate passed"
```

---

## Step 5: Address ALL Code Review Feedback (NON-NEGOTIABLE)

**Every piece of review feedback is mandatory.** Nits, minors, suggestions, "request changes" — all of it. The only exception is feedback that is **provably incorrect**, and that assessment **requires human approval** before you can skip it.

### 5a. Gather ALL feedback sources

```bash
PR_JSON=$(gh pr view --json number,url,state,reviewDecision,reviews,comments,reviewRequests 2>/dev/null)
PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number // empty')
```

If a PR exists, fetch ALL feedback — leave nothing behind:

```bash
# PR-level reviews (approve, request changes, comment)
gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews" --paginate > /tmp/pr-reviews.json

# Inline review comments (line-level feedback)
gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" --paginate > /tmp/pr-comments.json

# General PR conversation comments
gh api "repos/{owner}/{repo}/issues/$PR_NUMBER/comments" --paginate > /tmp/pr-conversation.json
```

**NEVER truncate with `head`/`tail`.** Missing a comment because you truncated output is a critical failure.

### 5b. Check review decision

```bash
REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // empty')
```

If `reviewDecision` is `CHANGES_REQUESTED`, this PR **cannot ship until every requested change is addressed.** No exceptions.

### 5c. Process EVERY piece of feedback

Read every comment from all three sources. For each one:

1. **Read the referenced file at the referenced lines** — understand the context
2. **Determine if already addressed** in current code — check the actual code, not your memory
3. **If unresolved → fix it immediately.** This includes:
   - "Nit" comments — fix them. Nits are valid feedback, not optional suggestions.
   - "Minor" comments — fix them. Minor still means wrong or improvable.
   - "Suggestion" comments — implement them unless provably incorrect.
   - "Request changes" reviews — every item must be addressed.
   - Style feedback — fix it. The reviewer's style preference wins.
4. **If unclear → STOP and ask the user.** Do not guess what the reviewer meant.

### 5d. The ONLY exception: provably incorrect feedback

If you believe review feedback is **factually wrong** (e.g., reviewer says "this function doesn't handle nulls" but it demonstrably does on line 42), you may propose skipping it — but:

1. **Present your evidence to the user** — show the specific code that contradicts the feedback
2. **Wait for explicit human approval** before skipping
3. If the user says "fix it anyway" — fix it. No arguing.
4. If the user approves skipping — reply to the review comment explaining why, so the reviewer has context

**You do NOT get to unilaterally decide feedback is incorrect.** The user must approve.

### 5e. Present the feedback checklist

Before committing fixes, show the user a complete checklist of ALL feedback:

```
## PR Feedback — <N> items from <M> reviewers

### Changes Requested
- [ ] <reviewer>: <file>:<line> — <summary of feedback> → <your fix>
- [ ] <reviewer>: <file>:<line> — <summary> → <fix>

### Nits / Minor
- [ ] <reviewer>: <file>:<line> — <summary> → <fix>

### Disputed (requires your approval to skip)
- [ ] <reviewer>: <file>:<line> — <feedback> → DISPUTE: <your evidence>
```

### 5f. Commit and resolve

After fixing, commit all feedback fixes:

```bash
git add <changed-files>
git commit -m "$(cat <<'EOF'
fix: address PR review feedback

<list each feedback item addressed>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Resolve addressed threads on GitHub:

```bash
# For each resolved inline comment thread
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<thread-id>"}) { thread { isResolved } } }'
```

### 5g. Re-run ALL gates after feedback fixes

Feedback fixes change code. Changed code must be re-verified.

```bash
bash "$PLUGIN_DIR/run-gates.sh" ship
bash "$PLUGIN_DIR/checkpoint.sh" save ship-feedback "PR feedback addressed, gates re-verified"
```

### 5h. Re-request review if changes were requested

If `reviewDecision` was `CHANGES_REQUESTED`, re-request review after pushing fixes:

```bash
gh pr edit $PR_NUMBER --add-reviewer <reviewer-login>
```

---

## Step 6: Rebase on latest default branch

```bash
git fetch origin
git rebase origin/$DEFAULT_BRANCH
```

If conflicts, **STOP** and notify the user.

**After rebase, re-run ALL gates** (rebase can introduce issues):

```bash
bash "$PLUGIN_DIR/run-gates.sh" ship
bash "$PLUGIN_DIR/checkpoint.sh" save ship-rebase "Post-rebase gates passed"
```

---

## Step 7: Final proof collection

This is the moment of truth. Everything that goes into the PR must be proven NOW, not recalled from earlier.

```bash
# Verify no drift from any previous checkpoint
bash "$PLUGIN_DIR/checkpoint.sh" drift

# Run ALL gates one final time
bash "$PLUGIN_DIR/run-gates.sh" all

# Collect proof into markdown
bash "$PLUGIN_DIR/collect-proof.sh"

# Save final checkpoint
bash "$PLUGIN_DIR/checkpoint.sh" save ship-final "Final gates passed — ready to ship"
```

Read the generated proof report:

```bash
cat .quality/proof/PROOF.md
```

### Review Completeness Check

Before creating or updating the PR, verify that the most recent review achieved full coverage:

1. Read `.quality/proof/review-coverage.json` (written by the review skill after aggregation). If the file does not exist: **STOP** — "Ship blocked — no review coverage proof found. Run `/sdlc:review` first."
2. For each agent type, check that `remaining` is empty
3. If any agent has unreviewed files:
   a. Check `.quality/proof/review-dismissals.json` for per-file dismissals
   b. Every `(agent, file)` pair must have a matching dismissal where `dismissal.agent == agent` AND `dismissal.file == file` with a non-empty `reason`. A dismissal for one agent does not satisfy another agent's gap for the same file.
   c. Dismissals must have `sha` matching current HEAD (stale dismissals don't count)
4. If any `(agent, file)` pair lacks a matching dismissal: **STOP** — ship is blocked

```json
// .quality/proof/review-dismissals.json
{
  "sha": "abc1234",
  "timestamp": "2026-04-05T12:00:00Z",
  "dismissals": [
    {
      "agent": "style",
      "file": "utils/generated-types.ts",
      "reason": "generated code, not authored",
      "dismissed_by": "user"
    }
  ]
}
```

If blocked, present:
```
Ship blocked — incomplete review coverage:
  Style: utils/generated-types.ts (no dismissal)

Dismiss with reason to unblock, or re-run /sdlc:review.
```

**Note on rebase and dismissals:** Step 6 (rebase) changes HEAD SHA, which invalidates SHA-pinned dismissals from `/sdlc:review`. This is intentional — rebase introduces new code that may affect reviewed files. If the completeness check blocks after rebase due to stale dismissals, re-run `/sdlc:review` at the new HEAD. The review will be fast (only re-reviews files affected by the rebase) and will re-collect dismissals at the current SHA.

---

## Step 8: Push the branch

```bash
git push --force-with-lease
```

If first push: `git push -u origin $BRANCH`

---

## Step 8.5: Media in PR Descriptions

If `.quality/proof/recordings/` or `.quality/proof/screenshots/` contain files:

1. **Commit media to branch:** Copy media files to `docs/proof/` in the branch and commit:
   ```bash
   mkdir -p docs/proof
   cp .quality/proof/recordings/*.gif docs/proof/ 2>/dev/null || true
   cp .quality/proof/screenshots/*.png docs/proof/ 2>/dev/null || true
   git add docs/proof/
   git commit -m "docs: add QA recordings and design audit screenshots"
   ```

2. **Size check:** If total media exceeds 5MB, skip committing and instead upload as PR comment attachments after PR creation.

3. **PROOF.md references:** The `collect-proof.sh` script already includes Demo and Design Audit sections with image references. These will render inline in the PR description.

If no media files exist (non-UI change), the Demo and Design Audit sections are omitted from PROOF.md automatically.

---

## Step 9: Open or update the PR

### Build the PR body with embedded proof

Read the proof report and incorporate it into the PR description:

```bash
PROOF_CONTENT=$(cat .quality/proof/PROOF.md)
```

**If no PR exists:**

The PR title MUST use a conventional commit prefix: `feat:`, `fix:`, `chore:`, `refactor:`, `perf:`, `ci:`, `test:`, `docs:`, `build:`, `revert:`. Many repos enforce this with a CI check. Derive the type from the branch name or the nature of the changes.

Before creating the PR, check if the plan has a tracking issue:

```bash
PLAN_FILE="$HOME/.claude/plans/$REPO_NAME/$PLAN_SLUG.md"
ISSUE_REF=$(grep -m1 '^Issue:' "$PLAN_FILE" 2>/dev/null | sed 's|^Issue:[[:space:]]*||' || true)
ISSUE_NUM="${ISSUE_REF##*#}"
ISSUE_OWNER_REPO="${ISSUE_REF%#*}"
CURRENT_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
CLOSES_LINE=""
if [ -n "$ISSUE_NUM" ]; then
  if [ "$ISSUE_OWNER_REPO" = "$CURRENT_REPO" ] || [ -z "$CURRENT_REPO" ]; then
    CLOSES_LINE="Closes #${ISSUE_NUM}"
  else
    CLOSES_LINE="Closes ${ISSUE_OWNER_REPO}#${ISSUE_NUM}"
  fi
fi
```

```bash
gh pr create --base $DEFAULT_BRANCH --title "<type>: <description>" --body "$(cat <<PREOF
## Summary
<1-3 bullet points describing what this PR does>
$CLOSES_LINE

## Changes
<grouped list of meaningful changes>

## Quality Proof

> Every gate below was executed by script, not estimated by the model.
> Re-run verification: \`bash plugins/sdlc/scripts/run-gates.sh all\`

<INSERT FULL CONTENTS OF .quality/proof/PROOF.md HERE>

(PROOF.md already includes execution plan and audit trail sections if they exist — do not duplicate them.)

## Test Plan
- [ ] All quality gates pass (automated — see proof above)
- [ ] CI checks pass
- [ ] <manual testing steps if applicable>

## Checkpoint History
<INSERT CHECKPOINT HISTORY — shows gates were run at every phase, not just at the end>
PREOF
)"
```

**CRITICAL:** The proof report MUST be in the PR description. This is the entire point of the plugin — reviewers can see exactly what was verified, when, and at what commit SHA.

**If PR already exists:**
- Compare current description against actual changes
- Update with `gh pr edit` to include fresh proof report
- Always update the Quality Proof section with latest proof

### Post plan as first comment

After the PR exists, post the associated implementation plan as a top-level comment. This gives reviewers the scannable plan view (Goal + Status + checklist) alongside the embedded PROOF.md in the PR body.

```bash
PR_NUMBER=$NUMBER PLAN_COMMENT_STATUS=$(bash "$PLUGIN_DIR/post-plan-to-pr.sh" | tail -1)
```

The script discovers the plan at `~/.claude/plans/<repo>/<branch-slug>.md`, extracts Goal + per-task status + checklist, wraps the full plan in `<details>`, and posts it as a top-level PR comment. An HTML marker (`<!-- sdlc-plan -->`) prevents duplicate posts on re-ship. The script ends with one summary line on stdout — `tail -1` captures that into `PLAN_COMMENT_STATUS` for Step 11. One of:

- `Plan comment: posted`
- `Plan comment: already present (skipped)`
- `Plan comment: no plan file found`
- `Plan comment: post failed (non-fatal)`

### Link PR to tracking issue

If the plan has an `Issue:` field, link the PR to the tracking issue:

```bash
if [ -n "$ISSUE_REF" ]; then
  bash "$PLUGIN_DIR/issue-sync.sh" link-pr "$PLAN_FILE" "$PR_NUMBER" 2>/dev/null || true
fi
```

---

## Step 9.5: PR Feedback

If `SKIP_PR_FEEDBACK` is NOT set:

Invoke `Skill(sdlc:pr-feedback)`. The skill auto-detects the PR from the current branch.

This monitors the PR for review feedback (automated and human), addresses it autonomously, and repeats until clean or the round limit is reached. Runs while CI executes on GitHub — feedback is handled before the CI watch in Step 10, but CI has been running in the background since the push in Step 8.

After the feedback skill completes:
- If all threads resolved: proceed to Step 10
- If threads remain after round limit: capture unresolved count for Step 11 report

If `SKIP_PR_FEEDBACK` is set: skip this step, proceed to Step 10. Note in Step 11 report: "PR feedback skipped (--skip-pr-feedback)".

---

## Step 10: Watch CI and fix failures

**ALL checks are required — including Codacy.**

### 10a. Wait for checks

```bash
gh pr checks $NUMBER --watch --fail-fast=false
```

If "no checks reported" — wait 60s, verify workflows triggered, retry up to 3 times.

### 10b. On failure — diagnose with inspection script

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
python3 "$PLUGIN_DIR/inspect_pr_checks.py" --pr $NUMBER --json > /tmp/ci-failures.json
```

Read the JSON. For each failing check:
- `status: "external"` — report URL, cannot auto-fix (Buildkite, etc.)
- `status: "log_pending"` — wait 60s, retry
- `status: "ok"` — read `tier` and `tierContext` to diagnose:
  - **compile** tier: read `tierContext.file` and `tierContext.line`, fix the compile error
  - **test** tier: read `tierContext.assertion` and `tierContext.diff_snippet`, fix the test failure
  - **infra** tier: read `tierContext.tail_lines`, diagnose the environment issue

### 10c. Fix and re-verify

1. Fix the diagnosed issue
2. Re-run ALL gates:
   ```bash
   bash "$PLUGIN_DIR/run-gates.sh" all
   bash "$PLUGIN_DIR/collect-proof.sh"
   bash "$PLUGIN_DIR/checkpoint.sh" save ship-ci-fix "CI fix — gates re-verified"
   ```
3. Commit the fix, push, update PR description with fresh proof
4. Go back to 10a

---

## Step 11: Report and land

Once every check is green:

```
## Ship Complete

PR: <url>
Branch: <branch> -> <default-branch>
Checks: All passing

### Quality Proof Summary
- Gates run: <N>
- All passed: <yes/no>
- Coverage: <overall %>
- Checkpoints recorded: <N>
- Last verified at: <SHA> (<timestamp>)
- Plan comment: <$PLAN_COMMENT_STATUS>

### Review Feedback
- Rounds: <N> (or "skipped" if --skip-pr-feedback)
- Threads addressed: <M> (<X> bot, <Y> human)
- Remaining unresolved: <K>

### What was done
- <quality fixes>
- <review feedback addressed>
- <CI failures fixed>
```

If unresolved threads remain (K > 0), ask the user to address them before offering to merge.

**Ask the user if they want to merge.** Do NOT merge autonomously. Ever.
