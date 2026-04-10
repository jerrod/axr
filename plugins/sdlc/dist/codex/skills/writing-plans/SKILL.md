---
name: writing-plans
description: "Write a detailed implementation plan from a spec or design doc — TDD steps, exact file paths, code snippets, and proof-anchored checkboxes. Saves to .quality/plans/<branch-slug>.md (gitignored) with a symlink at ~/.claude/plans/<repo>/<branch-slug>.md. Plans are private workflow artifacts, never committed. Distinct from sdlc:plan which adopts existing plans into the proof system. Trigger: 'write the implementation plan', 'create tasks from the spec', 'break this into steps'."
---

# Writing Plans

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log design sdlc:writing-plans started --context "$ARGUMENTS"`
- **End:** `bash "$AUDIT_SCRIPT" log design sdlc:writing-plans completed --context="<summary>"`

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).

**Save plans to:** `~/.claude/plans/<repo>/<branch-slug>.md` (physical location, survives repo deletion) with a symlink at `.quality/plans/<branch-slug>.md` for workspace-proximity.

- Plans are PRIVATE workflow artifacts — they live OUTSIDE the repo and MUST NOT be committed.
- `<branch-slug>` is the current branch name with `/` replaced by `-` (e.g., `feat/post-plan-to-pr` → `feat-post-plan-to-pr`)
- Physical location in `~/.claude/plans/` survives: repo deletion, worktree deletion, `.quality/` nuking
- Symlink into `.quality/plans/` sits alongside proof artifacts and checkpoints — easy workspace access
- `.quality/plans/` is gitignored (the whole `.quality/` directory is)

**Creation steps:**

```bash
source "$(find . -name 'git-helpers.sh' -path '*/sdlc/*' | head -1)"
REPO_NAME=$(get_repo_name)
BRANCH=$(git branch --show-current)
PLAN_SLUG="${BRANCH//\//-}"
REPO_ROOT=$(git rev-parse --show-toplevel)
PLAN_FILE="$HOME/.claude/plans/$REPO_NAME/$PLAN_SLUG.md"

mkdir -p "$HOME/.claude/plans/$REPO_NAME" "$REPO_ROOT/.quality/plans"
# ... write plan content to $PLAN_FILE ...
ln -sf "$PLAN_FILE" "$REPO_ROOT/.quality/plans/$PLAN_SLUG.md"
```

**After saving the plan file**, create a tracking GitHub issue:

```bash
ISSUE_SYNC=$(find . -name 'issue-sync.sh' -path '*/sdlc/*' | head -1)
[ -z "$ISSUE_SYNC" ] && ISSUE_SYNC=$(find "$HOME/.claude" -name 'issue-sync.sh' -path '*/sdlc/*' | head -1)
if [ -n "$ISSUE_SYNC" ]; then
  ISSUE_REF=$(bash "$ISSUE_SYNC" create "$PLAN_FILE" 2>/dev/null || true)
fi
```

**If `$ARGUMENTS` contains a parent issue reference** (e.g. `org/issues#15`):

```bash
if echo "$ARGUMENTS" | grep -qE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+'; then
  PARENT_REF=$(echo "$ARGUMENTS" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -1)
  bash "$ISSUE_SYNC" link-parent "$PLAN_FILE" "$PARENT_REF" 2>/dev/null || true
fi
```

(User preferences for plan location override this default, but the default is always local-only, never committed.)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Front-Matter Fields

The plan file uses key-value front-matter before the first heading:

| Field | Required | Set by |
|-------|----------|--------|
| `Branch:` | Yes | Plan creation |
| `Created:` | Yes | Plan creation |
| `Updated:` | Yes | Plan creation |
| `Issue:` | Auto | `issue-sync.sh create` (injected after Updated:) |
| `Parent-Issue:` | Auto | `issue-sync.sh link-parent` (injected after Updated:) |
| `Adopted-From:` | Only on adopt | `plan-progress.sh adopt` |

## Plan Document Header

**Every plan MUST start with this header (after front-matter):**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED: Use sdlc:pair-build to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

**Design Constraints:** [If the spec contains a Visual Direction section, synthesize it here: font choices, palette direction, motion intent, composition approach. This field is read by the builder as a hard constraint on frontend code. Omit this field entirely when the spec has no Visual Direction section.]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## Remember
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits

## Plan Review Loop

After completing each chunk of the plan:

1. Dispatch `sdlc:plan-reviewer` subagent with precisely crafted review context — never your session history. This keeps the reviewer focused on the plan, not your thought process.
   - Provide: chunk content, path to spec document
2. If Issues Found:
   - Fix the issues in the chunk
   - Re-dispatch reviewer for that chunk
   - Repeat until Approved
3. If Approved: proceed to next chunk (or execution handoff if last chunk)

**Chunk boundaries:** Use `## Chunk N: <name>` headings to delimit chunks. Each chunk should be ≤1000 lines and logically self-contained.

**Review loop guidance:**
- Same agent that wrote the plan fixes it (preserves context)
- If loop exceeds 5 iterations, surface to human for guidance
- Reviewers are advisory - explain disagreements if you believe feedback is incorrect

## Execution Handoff

After saving the plan:

Include the issue URL if one was created:

**"Plan complete and saved to `.quality/plans/<branch-slug>.md` (symlinked at `~/.claude/plans/<repo>/<branch-slug>.md`). Tracking issue: <issue URL or 'none created'>. Ready to execute?"**

**Execution path depends on harness capabilities:**

**If harness has subagents (Claude Code, etc.):**
- **REQUIRED:** Use sdlc:subagent-build
- Do NOT offer a choice - subagent-driven is the standard approach
- Fresh subagent per task + two-stage review

**If harness does NOT have subagents:**
- Execute plan in current session using sdlc:pair-build
- Batch execution with checkpoints for review
