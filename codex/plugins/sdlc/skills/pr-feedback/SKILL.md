---
name: pr-feedback
description: >
  Monitor a PR for review feedback and address it in an autonomous loop. Handles both
  automated (CodeRabbit, Codacy, etc.) and human reviewer feedback. Auto-detects PR
  from current branch. Waits for review checks, fetches unresolved threads, spawns a
  handler agent per round, optionally runs code-simplifier on changes, and repeats
  until clean. Triggers: 'handle PR feedback', 'address review comments',
  'pr feedback', 'fix review comments', 'respond to reviews'.
argument-hint: "[PR number — auto-detected from current branch if omitted]"
allowed-tools:
  - Bash(git *)
  - Bash(gh *)
  - Bash(sleep *)
  - Read
  - Glob
  - Grep
  - Agent
---

# PR Feedback

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log ship sdlc:pr-feedback started --context="PR #$PR_NUMBER"`
- **End:** `bash "$AUDIT_SCRIPT" log ship sdlc:pr-feedback completed --context="<summary>"`

Monitor a PR for review feedback (automated and human), address it, and repeat until clean.

---

## Step 0 — Resolve PR Context

### Auto-detect PR number

```bash
PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null)
```

If that fails (no PR for current branch), fall back to `$ARGUMENTS`:
- If argument is a full GitHub URL, extract the PR number from it
- If argument is a number, use it directly
- If neither works, respond with usage and **stop**:
  > `/sdlc:pr-feedback [PR number]` — or push a branch and open a PR first.

### Gather context

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
OWNER=$(echo "$REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$REPO" | cut -d/ -f2)
CURRENT_USER=$(gh api user --jq '.login')
PR_URL=$(gh pr view "$PR_NUMBER" --json url -q '.url')
IS_DRAFT=$(gh pr view "$PR_NUMBER" --json isDraft -q '.isDraft')
LAST_PUSH_SHA=$(git rev-parse HEAD)
```

Initialize: `ROUND=0`, `CUMULATIVE_TABLE=""` (collects assessment rows across all rounds).

---

## Step 0.5 — CI-State Guard

One-time CI check before polling. Run `gh pr checks "$PR_NUMBER" --json name,state,conclusion`.
- **Build/compile `FAILURE`** (names containing "build", "compile", "typecheck"): Warn — "CI has a build failure. Address that first, or proceed with feedback anyway?" Wait for input.
- **Test/lint failures**: One-line warning, proceed normally.
- **CI pending or green**: Proceed without comment.

---

## Step 1 — Wait for Review Feedback

### Draft PR shortcut

If `IS_DRAFT == true`:
- **Round 0**: Skip polling — go straight to Step 2 to check for existing unresolved threads. If threads exist, process them. If none, exit with "No unresolved feedback found."
- **Round > 0**: Single quick check for new threads (one fetch, no polling loop). If new threads appeared, process them. Otherwise, exit successfully.

If `IS_DRAFT == false` (Ready for Review), use the full polling logic below.

### Full polling (non-Draft PRs only)

Three layers: (1) detect review environment, (2) use bot-specific signals when available, (3) fall back to generic thread polling.

### Phase A: Detect review environment

Gather two signals:

**Signal 1 — PR checks:**
```bash
gh pr checks "$PR_NUMBER" --json name,state
```

**Signal 2 — Bot comments on this PR:**
```bash
gh api "repos/OWNER/REPO/issues/PR_NUMBER/comments" \
  --jq '[.[] | select(.user.type == "Bot") | {login: .user.login, body_start: (.body[0:200])}]'
```

**Classify the environment:**

| Condition | Classification | Behavior |
|-----------|---------------|----------|
| Check name matches a known bot | **Known bot** | Use bot-specific polling (Phase B1) |
| Bot comments from an unrecognized bot | **Unknown bot** | Use generic polling (Phase B2) |
| No bot checks AND no bot comments | **No AI reviewer** | Use short generic polling (Phase B3) |

**Known review-bot check name patterns** (case-insensitive):
- `coderabbit`, `codacy`, `sonar`, `deepsource`, `copilot`, `claude`
- Names containing `review` (but NOT `peer-review`, `review-app`, or CI-flavored variants like `review-deploy`)

If known bot checks are PENDING/IN_PROGRESS/QUEUED, poll every 15 seconds until terminal state. Timeout: 15 minutes. Then proceed to Phase B1.

**Do NOT wait for non-review checks** (CI builds, tests, deployments).

### Phase B: Poll for review comments

A bot's check can complete **minutes** before it finishes posting review comments. Poll actively.

**Core loop** (all variants share this structure):
1. Count unresolved review threads via GraphQL
2. **If threads found → stability check (wait 15s, re-fetch, confirm count stable) → proceed.** This is the primary exit condition and is SUFFICIENT on its own.
3. If zero threads AND a known bot is detected and still processing → keep waiting
4. Otherwise → sleep 15s, repeat

**Critical: thread stability is the primary exit.** If unresolved threads are found and the count is stable across two consecutive fetches, exit the loop immediately. Bot comment status is secondary — used only when thread count is zero.

**Bot "still processing" detection** (checked only when a known bot is detected):

Fetch the bot's latest issue comment and look for signals:
- **Still processing**: Comment < 500 chars, or contains "processing", "in progress", "analyzing"
- **Done**: Comment > 1000 chars, or contains structured review content (headings, file references)

**Implementation note — avoid double jq parsing:** Extract scalar values in a single `--jq` filter pass: `gh api ... --jq '... | .body | length'` — not `$(echo "$json" | jq ...)`.

**Timeout by environment:**

| Environment | Max polling time |
|-------------|-----------------|
| Known bot (B1) | 15 minutes |
| Unknown bot (B2) | 15 minutes |
| No AI reviewer (B3) | 2 minutes |

### Edge cases after polling

- **Round 0, no threads found:** Exit with "No review feedback found for PR #N."
- **Round > 0, no threads found:** Success exit — all previous feedback resolved.
- **Timeout exceeded:** Warn and proceed to Step 2 anyway.

---

## Step 2 — Fetch Unresolved Review Threads

Use `gh api graphql` to query `repository.pullRequest.reviewThreads(first: 100)`. For each thread, fetch: `id`, `isResolved`, and comments with `author.login`, `body`, `path`, `line`, `databaseId`, `url`.

**Filter**: `isResolved == false` only. Include threads from ALL authors.

**Reviewer type detection**: Cross-check against REST API:
```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments --paginate --jq '[.[] | {id, user_type: .user.type}]'
```
`user.type == "Bot"` → Bot; otherwise → Human. REST is authoritative (GraphQL may strip `[bot]` suffix).

---

## Step 3 — Evaluate

If **zero unresolved threads** remain: proceed to **Exit Summary**.
If unresolved threads exist: proceed to Step 4.

---

## Step 4 — Delegate to Handler Agent

Increment: `ROUND += 1`

Log: `"Round ROUND: Found N unresolved review threads. Delegating to handler..."`

Spawn the handler agent:

```
Agent(subagent_type="sdlc:pr-feedback-handler")
```

Pass context in the agent prompt:
- PR number, owner/repo
- Round number
- The unresolved thread data (JSON) including comment URLs and reviewer type classifications

The agent will:
1. Gather full PR context
2. Assess each feedback item (ACTION / ACKNOWLEDGE / DECLINE)
3. Implement changes for ACTION items
4. Reply individually to every comment
5. Resolve all threads
6. Return: assessment table, files modified, commit SHAs

**After the agent returns:**
- Collect the agent's assessment table rows into `CUMULATIVE_TABLE`
- Capture the list of files modified

---

## Step 5 — Code Simplifier Pass (Optional)

**Check if code-simplifier is available** before attempting to use it. This is not a hard dependency.

To detect: attempt to reference `code-simplifier:code-simplifier` as a subagent type. If the plugin is not installed, skip this step silently and proceed to Step 6.

**If available AND the handler made code changes (ACTION items):**
- Invoke `Agent(subagent_type="code-simplifier:code-simplifier")` targeting files modified this round
- If simplifier makes changes, commit: `refactor: simplify PR feedback changes`

**If code-simplifier is not installed:** Proceed directly to Step 6. No error, no warning.

---

## Step 6 — Push and Loop

**This is the ONLY push in the entire round.** Neither the handler nor the code simplifier push.

```bash
git push
```

Update `LAST_PUSH_SHA` to current HEAD. Loop back to **Step 1**.

---

## Safety Limits

- **Max rounds**: 5. After 5 rounds, exit with:
  > "Completed 5 feedback rounds. Some threads may still be unresolved. Re-invoke `/sdlc:pr-feedback` to continue."
- **Session awareness**: If approaching tool-call or turn limits, report current state so the user can re-invoke.

---

## Exit Summary

When exiting (success, timeout, or round limit), present:

```
## PR Feedback Summary

- **PR**: #<number> (<PR_URL>)
- **Rounds completed**: N
- **Total threads addressed**: M (X automated, Y human)
- **Remaining unresolved**: K
- **Final status**: [Clean / Timed out / Round limit reached]

### Cumulative Assessment

(table of all feedback items across all rounds)
```
