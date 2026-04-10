---
name: review
description: "Use this skill when the user wants a code review — before opening a PR, merging a branch, or shipping to production. Triggers on requests like \"review my code\", \"is this ready to merge\", \"check my work before I push\", \"run the quality gates\", or \"give me a second pair of eyes on this branch\". Runs automated quality gate scripts plus manual review for bugs, security, performance, test quality, and plan compliance. Walks through findings interactively and commits fixes. Do NOT use for building features, fixing bugs, or performance auditing outside a review context."
argument-hint: "[base-branch] (defaults to default branch)"
allowed-tools: Bash(git *), Bash(gh *), Bash(bash plugins/*), Bash(python3 *), Read, Edit, Write, Glob, Grep, Agent
---

# Code Review (Plugin Edition)

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (already detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `CONTEXT="$ARGUMENTS" bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log review sdlc:review started --context="$CONTEXT"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log review sdlc:review completed --context="<summary>"`

## Guiding Principle

**Correctness is the only measure that matters.** Do not rush the review to unblock shipping. Do not downgrade findings to avoid slowing things down. A correct review that takes an hour is infinitely more valuable than a quick review that misses a bug.

Every quality check that CAN be automated IS automated via gate scripts. Manual review focuses on what scripts cannot catch: design, intent, plan compliance, and subtle bugs.

## Anti-Rationalization Rule (NON-NEGOTIABLE)

**If you noticed it, it is a finding. Fix it.**

The reviewer's job is to find problems. Once you identify something — a code smell, an inconsistency, a potential bug, unclear naming — you do NOT get to talk yourself out of it. The following phrases are BANNED during review:

- "Functionally equivalent" — if the new code is worse than the old, that is a finding
- "Not a bug" / "No issue" — if you wrote a finding header, it IS an issue
- "Works correctly" (as a reason to skip fixing) — working is the minimum bar, not the goal
- "Out of scope" / "pre-existing" — if you found it in a changed file, you own it
- "Verified by tests" (as a reason not to fix a code smell) — tests verify behavior, not quality

**ABSOLUTE BAN — "Pre-existing" framing (NON-NEGOTIABLE):**

There is no such thing as a "pre-existing issue." You wrote every line of this codebase (this session or a previous one). When a gate flags a violation, the ONLY correct response is to fix it. Not to classify it. Not to explain when it was introduced. Not to create a separate section for things "on main" or "not introduced by this PR."

If you catch yourself writing "Pre-existing Issues" or "not introduced by this PR" — STOP. Delete it. Fix the violations instead. A gate failure is a gate failure. It does not have an origin story. It has a fix.

**The test:** After writing a finding, did you conclude with "fix it" or "no issue"? If "no issue," you rationalized. Go back and fix it.

**Never self-defer findings.** The reviewer NEVER decides to defer on its own. Present every finding with the expectation of fixing it now. Only the user can decide to defer — if they explicitly say so, record it in the ledger and move on.

## Commit Protocol (NON-NEGOTIABLE)

**Never leave a dirty tree.** Every fix you apply — commit it immediately. Do not accumulate fixes. Do not ask the user what to do with uncommitted code. Do not wait until the walkthrough is complete. Fix → commit → next finding.

```
fix: <description>       — bug fix or review finding fix
refactor: <description>  — restructuring without behavior change
test: <description>      — adding or updating tests
```

**After each finding is fixed:** Stage the specific files and commit:

```bash
git add <changed-files>
git commit -m "$(cat <<'EOF'
fix: <what was fixed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**After a batch of related fixes in one round:** If multiple findings touch the same file and fixing them sequentially would create noise commits, you MAY batch them into one commit per round — but NEVER leave the round with uncommitted changes.

## Anti-Context-Rot Protocol

During long reviews, Claude tends to:
- Get less thorough with later files ("similar to the pattern above")
- Forget findings from early in the review
- Skip manual checks after running scripts ("scripts already verified this")
- **Truncate API output** with `head`/`tail` and miss critical data

**Prevention:**
1. Run gate scripts FIRST. They produce proof files. Then do manual review on top.
2. Write findings to the feedback ledger AS YOU GO — not at the end from memory.
3. Every finding must reference a specific file and line number. No vague findings.
4. Re-read the proof files before writing the summary. Don't rely on memory.
5. **NEVER truncate API responses or command output.** No `head -N`, no `tail -N`, no piping through truncation. Read ALL PR comments, ALL CI logs, ALL gate output. Use `--jq` filters to reduce data server-side, not client-side truncation. Missing one finding because you truncated the output is a critical failure.

---

## Step 1: Determine Scope

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
BASE="${ARGUMENTS:-$DEFAULT_BRANCH}"
CURRENT=$(git branch --show-current)
```

If on the default branch, **STOP** — ask which branch to review.

```bash
git fetch origin "$BASE" --quiet
git diff "origin/$BASE"...HEAD --stat
git diff "origin/$BASE"...HEAD --name-only
```

**Read every changed file in full.** Do not review files you have not read.

### Load prior feedback

```bash
REPO_NAME=$(_u=$(git remote get-url origin 2>/dev/null) || _u=""; if [ -n "$_u" ]; then basename "${_u%.git}"; else basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi)
LEDGER_DIR="$HOME/.claude/reviews/$REPO_NAME"
LEDGER="$LEDGER_DIR/$CURRENT.md"
```

If `$LEDGER` exists, read it. **Do NOT re-report findings already in the ledger.**

---

## Step 2: Run Gate Scripts (Automated Verification)

Run ALL quality gates and produce proof:

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
fi

bash "$PLUGIN_DIR/run-gates.sh" review
```

**Read every proof file and incorporate results into the review.** The gate scripts catch:
- File size violations (`filesize.json`)
- Function length and cyclomatic complexity (`complexity.json`)
- Dead code and unused imports (`dead-code.json`)
- Lint/format/typecheck failures (`lint.json`)

**Do NOT re-check what the scripts already checked.** Trust the proof files. Focus manual review on what scripts cannot detect.

Save a checkpoint:
```bash
bash "$PLUGIN_DIR/checkpoint.sh" save review-gates "Gate scripts completed"
```

---

## Step 3: Parallel Agent Review

Dispatch 4 specialized review agents simultaneously. Each reads the changed files and produces findings as a JSON array.

```bash
CHANGED_FILES=$(git diff "origin/$BASE"...HEAD --name-only)
```

Launch all agents in a single response using the Agent tool. Each call MUST include both `description` and `prompt` parameters.

**Check for frontend files first:**

```bash
FRONTEND_FILES=$(git diff "origin/$BASE"...HEAD --name-only | grep -E '\.(tsx|jsx|css|scss|html)$')
```

**Architect file prioritization (for large PRs):**

Before dispatching the architect agent, classify changed files by architectural significance:

| Priority | Category | Detection |
|----------|----------|-----------|
| 1 | Interfaces/exports | `**/types.*`, `**/interfaces.*`, `**/index.*`; files with changed `export` lines |
| 2 | New files | Status `A` in `git diff --name-status` |
| 3 | Dependencies | `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `requirements*.txt` |
| 4 | Entrypoints | `**/routes.*`, `**/router.*`, `**/main.*`, `**/app.*`, `**/server.*` |
| 5 | Config | `**/config.*`, `**/.env*`, `**/settings.*` |
| 6 | Implementation | All other source files |
| 7 | Skip | `**/*.test.*`, `**/*.spec.*`, `**/*.md`, `**/generated/**`, `**/__snapshots__/**` |

Within each tier, sort by diff size (larger first). Send tiers 1-6 to architect, capped at ~12 files. Always skip tier 7 for architect.

If total changed files ≤ 12, send all non-tier-7 files to architect (no prioritization needed).

**Sharding for large PRs:**

When changed files exceed an agent's per-shard capacity, split into chunks and dispatch multiple agents of the same type in parallel.

| Agent | Max Files/Shard | Shard Threshold |
|-------|----------------|-----------------|
| Architect | N/A (not sharded) | N/A — uses file prioritization |
| Style | 8 | >8 changed files |
| Correctness | 9 | >9 changed files |
| Security | 9 | >9 changed files |

**Shard dispatch:** Use the same `subagent_type` with different `prompt` contents listing different file subsets. All shards run in parallel in a single Agent tool response.

**Conservative sizing:** Err on smaller shards. 3 shards of 6 is better than 2 shards of 9.

**Dispatch all 4 core review agents in a single response.** For agents that require sharding, dispatch multiple instances with different file lists. For architect, use the prioritized file list. All 4 core agents (architect, security, correctness, style) must output a JSON object (not a bare array) with `status`, `reviewed`, `remaining`, `findings`, and `needs_continuation` fields.

```
# Architect — prioritized, not sharded
Agent(
  subagent_type="sdlc:review-architect",
  description="Architecture review",
  prompt="Review these files for architecture concerns: <PRIORITIZED_FILES>. Base branch: origin/$BASE. Output a JSON object with status, reviewed, remaining, findings, needs_continuation fields."
)

# Security — shard if >9 files
Agent(
  subagent_type="sdlc:review-security",
  description="Security review [shard N]",
  prompt="Review these files for security vulnerabilities: <SHARD_FILES>. Base branch: origin/$BASE. Output a JSON object with status, reviewed, remaining, findings, needs_continuation fields."
)

# Correctness — shard if >9 files
Agent(
  subagent_type="sdlc:review-correctness",
  description="Correctness review [shard N]",
  prompt="Review these files for correctness and logic bugs: <SHARD_FILES>. Base branch: origin/$BASE. Output a JSON object with status, reviewed, remaining, findings, needs_continuation fields."
)

# Style — shard if >8 files
Agent(
  subagent_type="sdlc:review-style",
  description="Style review [shard N]",
  prompt="Review these files for style and quality: <SHARD_FILES>. Base branch: origin/$BASE. Output a JSON object with status, reviewed, remaining, findings, needs_continuation fields."
)
```

**If `$FRONTEND_FILES` is non-empty, also dispatch the design-reviewer in the same batch:**

```
# design-reviewer uses legacy bare-array format — separate proof path, not subject to coverage manifest schema
Agent(
  subagent_type="sdlc:design-reviewer",
  description="Design review",
  prompt="Review these changed frontend files for design quality: <FRONTEND_FILES>.
    Design context: .claude/design-context.md (if present).
    Check: design token compliance, WCAG 2.1 AA accessibility, responsive patterns.
    Read skills/design/design-constraints.md and skills/design/a11y-rules.md for rules.
    Output findings as JSON array and write proof to .quality/proof/design-review.json."
)
```

If `.claude/design-context.md` does not exist, the design-reviewer skips token compliance checks but still checks accessibility and responsive patterns. Note this in the review summary:

```
Note: No .claude/design-context.md found. Token compliance not checked.
Run `sdlc:design init` to establish design tokens for full design review coverage.
```

Replace `<CHANGED_FILES>` and `<FRONTEND_FILES>` with the actual file lists from the bash commands above.

### Aggregate findings

**Design-reviewer is handled separately.** If dispatched, collect its bare-array output directly into the findings list. Do NOT feed it through the object-format parsing or coverage/continuation logic below — it uses a separate proof path (`.quality/proof/design-review.json`) and is excluded from coverage tracking.

**For the 4 core agents** (architect, security, correctness, style) and their shards:

1. **Parse** each agent's output as a JSON object (not a bare array). Find the `{...}` object in the response text. Read `.findings` for the findings array, `.reviewed` for files covered, `.remaining` for coverage gaps.
2. **Merge shards** — for agents dispatched as multiple shards, union their `.findings` arrays and `.reviewed` arrays. If any shard has `.remaining` entries, collect them for the continuation loop.
3. **Deduplicate** — same file + similar line + similar description → keep the more detailed one
4. **Sort** by severity: critical > high > medium > low > info
5. **Compute coverage** per agent type: union of all shard `.reviewed` lists vs the full changed file list dispatched to that agent type.

**Fallback parsing:** If a core agent's output is not valid JSON or is missing the `status`/`reviewed` fields, treat the entire dispatch as truncated — set `remaining` to the full file list for that agent/shard and enter the continuation loop.

### Continuation loop

After aggregation, check each agent type for incomplete coverage:

1. For each agent type where `remaining` is non-empty (from any shard):
   a. Re-dispatch the same `subagent_type` with `remaining` files as the file list
   b. Prompt includes: "Continue reviewing. These files were not covered in a prior pass. Output a JSON object with status, reviewed, remaining, findings, needs_continuation fields."
   c. Merge returned findings with prior findings for that agent type
   d. Update coverage: add newly `.reviewed` files, recompute `.remaining`
2. **Max 2 automatic continuation passes** per agent type. If still incomplete after 2 passes, stop and include the remaining files in the coverage report.
3. Continuation passes run sequentially per agent type (not parallel — need prior pass results).

**User visibility:** During continuation, report progress:
```
  ↻ Security continuing... (reviewed 6/9, fetching remaining 3)
```

When done:
```
  ✓ Security complete (9/9 files, 2 passes)
```

### Write coverage proof

After aggregation and continuation, write `.quality/proof/review-coverage.json`:

```json
{
  "sha": "<current HEAD>",
  "timestamp": "<ISO 8601>",
  "status": "complete",
  "agents": {
    "architect": {"dispatched": [], "reviewed": [], "remaining": [], "shards": 1, "passes": 1},
    "security": {"dispatched": [], "reviewed": [], "remaining": [], "shards": 1, "passes": 1},
    "correctness": {"dispatched": [], "reviewed": [], "remaining": [], "shards": 1, "passes": 1},
    "style": {"dispatched": [], "reviewed": [], "remaining": [], "shards": 1, "passes": 1}
  }
}
```

Top-level `status` is `"complete"` when all agents have empty `remaining`, `"incomplete"` otherwise. This file is consumed by the ship skill's review completeness check.

---

## Step 4: Plan Compliance (SKEPTICAL)

**Assume the work does NOT match the plan until proven otherwise.**

1. Find the plan (`.claude/plans/`, PR description, branch name, linked issue)
2. Read the plan in full
3. **Audit each requirement against the diff:**
   - Implemented? → If not, **CRITICAL**
   - Correctly implemented? → Be skeptical. Existence ≠ correctness. If partial, **HIGH**
   - Tested? → If not, **HIGH**
4. Check for scope drift — changes not in the plan → **MEDIUM**
5. Check constraints and edge cases from the plan

Summarize:
```
Plan: <name>
Requirements: N total
- Fully implemented + tested: X
- Implemented but untested: Y
- Partially implemented: Z
- Missing: W
- Unplanned changes: V
```

---

## Step 5: Test Coverage and Quality Review

Run the test, coverage, and test quality gates:

```bash
bash "$PLUGIN_DIR/gate-tests.sh"
bash "$PLUGIN_DIR/gate-coverage.sh"
bash "$PLUGIN_DIR/gate-test-quality.sh"
```

Read the proof files:
- `tests.json` — are there missing test files? Did tests pass?
- `coverage.json` — is any changed file below 95%?
- `test-quality.json` — are there disguised mocks in test files?

### Disguised Mock Detection (CRITICAL — Manual Review Required)

The gate script catches common patterns, but manual review catches what automation misses. For every test file in the diff, verify:

1. **The litmus test:** "If I delete the source file, does this test still pass?" If yes, the test is mocking away the module under test. **CRITICAL.**

2. **Banned patterns** — any `spyOn()` with a `.mock*()` chain on internal code:
   - `vi.spyOn(module, 'fn').mockImplementation(...)` — mock wearing a spy costume
   - `vi.spyOn(module, 'fn').mockReturnValue(...)` — same thing
   - `vi.spyOn(module, 'fn').mockResolvedValue(...)` — same thing
   - `jest.mock('./internal-module')` — replaces entire module with fake
   - `@patch('mymodule.fn')` without `wraps=` — Python equivalent

3. **The mechanical check:** After `spyOn()`, is there a `.mock*()` chained on it? If yes, it's a mock, not a spy. Real spies have NO `.mock*()` chain.

4. **Acceptable boundary mocks** (NOT violations):
   - HTTP clients (`fetch`, `axios`, API adapters)
   - Timers (`Date.now`, `setTimeout`)
   - Third-party SDKs (Stripe, AWS, etc.)
   - `spyOn()` WITHOUT `.mock*()` — this is a real spy, it observes real code

### General Test Quality

- Edge cases — are boundary conditions tested?
- Error paths — are failure modes tested?
- Test isolation — does each test verify one logical concept?

---

## Step 6: Report Summary

Before the interactive walkthrough, present the full picture:

### Review Coverage

Show per-agent coverage from `.quality/proof/review-coverage.json`:

```
Review Coverage
  Architect   ✓ 12/12 files
  Security    ✓ 18/18 files (2 shards)
  Correctness ✓ 18/18 files (2 shards)
  Style       ✓ 16/16 files (2 shards)
```

If any agent has remaining files after all continuation passes:

```
Review Coverage
  Architect   ✓ 12/12 files
  Security    ✓ 18/18 files (2 shards)
  Correctness ✓ 18/18 files (2 shards)
  Style       ⚠ 14/16 files — 2 not reviewed: utils/helpers.ts, lib/format.ts
```

**Incomplete coverage blocks the "review complete" signal.** The review cannot reach Step 9 (zero open issues) while any agent has unreviewed files, unless the user explicitly dismisses each unreviewed file with a reason.

### Dismissal collection

When coverage is incomplete after all continuation passes, prompt the user for each unreviewed file:

```
Style did not review: utils/generated-types.ts
  Dismiss? Enter reason (or 'no' to block review): _
```

For each dismissed file, collect the reason and write `.quality/proof/review-dismissals.json`:

```json
{
  "sha": "<current HEAD>",
  "timestamp": "<ISO 8601>",
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

If the user declines to dismiss any file, the review remains incomplete. The user can re-run `/sdlc:review` or manually review the skipped files.

Dismissals are SHA-pinned — they expire if HEAD changes (new commits invalidate them).

### Summary

```
## Code Review: <branch-name>

### Automated Gates
<paste relevant sections from proof files>

### Manual Findings
Found N issues: X critical, Y high, Z medium, W low

Now walking through each finding...
```

---

## Step 7: Interactive Walkthrough

Walk through each finding ONE AT A TIME, ordered by severity (critical first).

For each finding:
1. **The relevant diff** — specific file and lines
2. **The finding** — what, why, severity
3. **Suggested fix** — concrete code when possible

Ask:
- **Fix now** — apply immediately, commit, move on
- **Fix differently** — user provides approach, apply, commit
- **Defer** — ONLY if the user explicitly requests it. The reviewer NEVER defers on its own. Present findings with the expectation of fixing them. If the user decides to defer, record in ledger and move on.

### After each fix: COMMIT

```bash
git add <changed-files>
git commit -m "$(cat <<'EOF'
fix: <description of what was fixed>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**Do NOT accumulate fixes.** Each fix gets its own commit (or batch related fixes touching the same file into one commit). Never end a walkthrough round with uncommitted changes.

---

## Step 8: Recursive Review Loop

**The review is not done when findings are fixed. The review is done when a full re-review finds ZERO issues.**

Fixes introduce new code. New code can introduce new bugs, new complexity, new dead code, new violations. A single-pass review that stops after fixes is incomplete by definition.

### 8a. Re-run ALL gate scripts

```bash
bash "$PLUGIN_DIR/run-gates.sh" review
```

If any gate fails, fix and re-run. Do not proceed with gate failures.

### 8b. Re-run the full review (Steps 3–5) on the CURRENT state

This is not a quick "check if fixes look right." This is a full re-review:

1. Re-dispatch the 4 review agents on the updated code (Step 3)
2. Re-check plan compliance (Step 4) and test quality (Step 5)
3. Collect all new findings into a new findings list

**Anti-rot note:** Do NOT skip this because "I just reviewed it." You reviewed the OLD code. The fixes changed the code. Review the NEW code. If you catch yourself thinking "this is redundant" — that is context rot. Run the review.

### 8c. Evaluate the new findings list

- **If ZERO new findings** → proceed to Step 9 (exit the loop)
- **If new findings exist** → present them to the user, walk through interactively (Step 7), apply fixes, then **return to Step 8a**

### 8d. Loop tracking

Maintain a loop counter to give the user visibility:

```
## Review Round <N>

Previous rounds: <N-1>
Findings this round: <count>
Cumulative fixes applied: <total>
```

**There is no maximum number of rounds.** The review runs until clean. If round 5 still finds issues, run round 6. Correctness is the only measure that matters.

However, if a finding keeps reappearing across rounds (fix introduces regression that reintroduces it), flag it explicitly:

```
⚠ RECURRING FINDING: <description>
This was found in round <X>, fixed, and reappeared in round <Y>.
The fix approach needs to change — the current fix is introducing a regression cycle.
```

Stop and discuss the approach with the user rather than looping indefinitely on the same issue.

### 8e. Save checkpoint after each round

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save "review-round-<N>" "Round <N> complete — <findings_count> findings"
```

---

## Step 9: Review Complete — Zero Open Issues

This step is ONLY reached when a full review round (Steps 2–5) produces zero findings.

### 9a. Final gate verification

```bash
bash "$PLUGIN_DIR/run-gates.sh" review
bash "$PLUGIN_DIR/collect-proof.sh"
bash "$PLUGIN_DIR/checkpoint.sh" save review-complete "Review complete — zero open issues after <N> rounds"
```

### 9b. Verify clean tree

All fixes should already be committed from the walkthrough. If any uncommitted changes remain (they shouldn't), commit them now:

```bash
git status --porcelain | grep -q . && git add -u && git commit -m "$(cat <<'EOF'
fix: address remaining review findings

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### 9c. Update feedback ledger

Write ALL findings from ALL rounds to the ledger at `$LEDGER`.

```bash
mkdir -p "$LEDGER_DIR"
```

Format: Fixed items (with round number and commit SHA), Previously Reported items. Subsequent review runs skip findings already in the ledger.

### 9d. Final summary

```
## Review Complete

Rounds: <N>
Total findings discovered: <total across all rounds>
Total findings fixed: <fixed count>
Deferred by user: <deferred count>
Open: 0

Gate status: ALL PASS
```

**The review is complete when and only when this summary shows Open: 0.**

### 9e. Hand off to `/sdlc:ship`

Zero open issues and all gates pass. Invoke `/sdlc:ship` to rebase on the default branch, push the feature branch, open (or update) the PR with embedded proof, watch CI, and ask before merge.

**The workflow is build → review → ship.** Review hands off to ship only after zero open findings — do not ship earlier.
