---
name: plan
description: "Use this skill to adopt, find, resume, or hook up a plan for the sdlc proof system. Triggers when the user says \"adopt this plan\", \"hook the plan up to sdlc\", \"find the plan for this branch\", \"convert my Claude plan into sdlc format\", \"resume the plan\", or \"where's the plan? pair-build can't find it\". Converts Claude-native plans into sdlc-format plans with proof-anchored checkboxes. Do NOT use for writing plans from scratch (use writing-plans), building plan items (use pair-build), or brainstorming."
argument-hint: "<plan file path, search term, or 'adopt' to adopt latest Claude plan>"
allowed-tools: Bash(git *), Bash(gh *), Bash(bash plugins/*), Bash(python3 *), Bash(wc *), Bash(find *), Bash(ls *), Bash(cat *), Bash(stat *), Bash(grep *), Read, Edit, Write, Glob, Grep, Agent
---

# Plan: Proof-Anchored Planning

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log design sdlc:plan started --context "$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log design sdlc:plan completed --context="<summary>"`

## Purpose

This skill bridges Claude's native planning (free-form, context-rich) with sdlc's proof system (executable, verifiable). It runs **after** Claude creates or identifies a plan and **before** `/sdlc:pair-build` starts implementation.

**When to invoke this skill:**
- After Claude's plan mode creates a plan and compacts context → run `/sdlc:plan adopt` to take over
- Before starting `/sdlc:pair-build` on existing work → run `/sdlc:plan` to find and verify the plan
- When starting fresh → run `/sdlc:plan "feature description"` to create a new plan

## The Problem This Solves

When Claude transitions from plan mode to implementation:
1. Context is compacted — skill instructions, conversation history, and plan details are lost
2. The plan file exists at `~/.claude/plans/{random-words}.md` but is disconnected from the branch
3. Plan checkboxes are honor-system — Claude checks them without proof
4. `/sdlc:pair-build` can't find the plan because it's not at the conventional path

`/sdlc:plan` fixes all of this by adopting the plan, normalizing its location, and wiring it to the proof system.

---

## Phase 1: Find the Plan

```bash
PLUGIN_DIR=$(find . -path "*/sdlc/scripts/plan-progress.sh" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -path "*/sdlc/scripts/plan-progress.sh" -exec dirname {} \; 2>/dev/null | head -1)
fi
if [ -z "$PLUGIN_DIR" ]; then
  echo "FATAL: sdlc scripts not found"
  exit 1
fi
echo "Plugin scripts at: $PLUGIN_DIR"
```

Run the plan finder:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" find "$ARGUMENTS"
```

### Resolution Priority

1. **`$ARGUMENTS` is a file path** → use it directly
2. **`$ARGUMENTS` is "adopt"** → find the most recently modified Claude-native plan (random-word filename in `~/.claude/plans/`)
3. **Exact match** at `~/.claude/plans/$REPO_NAME/$BRANCH.md` → existing sdlc-format plan
4. **Branch field match** → any plan with `Branch: $BRANCH`
5. **Search match** → any plan whose title or content matches `$ARGUMENTS`
6. **Most recent Claude-native plan** → the newest `~/.claude/plans/{random-words}.md`
7. **No plan found** → create a new one (Phase 2b)

If `$ARGUMENTS` is "adopt" or empty and you find a Claude-native plan:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" adopt "$SOURCE_PLAN"
```

If multiple candidates exist, show them and **ask the user which one**.

---

## Phase 2: Validate or Create the Plan

### 2a. If a plan was found — validate its structure

Read the plan file. Check for these required elements:

1. **Branch field** — `Branch: <branch-name>` in the first 10 lines
2. **Checkboxes** — at least one `- [ ]` item in an Implementation Plan section
3. **Context** — substantive content explaining the goal and approach

**If the plan has context but no checkboxes** (common for Claude-native plans):

This is the adoption moment. You must:

1. Read the entire plan carefully — understand every section
2. Identify the implementation phases/steps described in the plan
3. Convert them into checkboxes under an `## Implementation Plan` section
4. **Preserve ALL original context verbatim** — do not summarize, truncate, or rewrite
5. Add the Branch, Created, Updated fields if missing
6. Add `Adopted-From: <original-filename>` if this was a Claude-native plan
7. Write to the conventional path: `~/.claude/plans/$REPO_NAME/$BRANCH.md`

**Critical: The original plan's depth IS the value.** Data models, architecture decisions, user preferences, rationale — keep it all. The checkboxes are scaffolding added on top, not a replacement.

**If the plan has checkboxes but no Branch field** — add the field, copy to conventional path.

**If the plan is already sdlc-format** — verify it, run status:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"
```

**If the plan has no `Issue:` field** and `gh auth status` succeeds, create a tracking issue:

```bash
ISSUE_REF=$(bash "$PLUGIN_DIR/issue-sync.sh" create "$PLAN_FILE" 2>/dev/null || true)
[ -n "$ISSUE_REF" ] && echo "Tracking issue created: $ISSUE_REF"
```

### 2b. If no plan was found — create one

#### Discover test infrastructure (MANDATORY — BLOCKING)

Before writing ANY plan, discover the project's test files:

```
Glob: **/*.test.{ts,tsx,js,jsx}
Glob: **/*.spec.{ts,tsx,js,jsx}
Glob: **/__tests__/**
Glob: **/test_*.py
Glob: **/*_test.go
```

1. Count test files found. **Record the number.**
2. Read at least 2 existing test files in the affected area.
3. Identify the test runner and patterns used.

**If you skip this step, you WILL incorrectly conclude the project has no tests.**

#### Gather context

- Read relevant source files in the area you'll be modifying
- Understand existing patterns, abstractions, and conventions
- If `$ARGUMENTS` references a task ID (Jira, GitHub issue), fetch the details
- Identify edge cases and integration points

#### Write the plan

Create at: `~/.claude/plans/$REPO_NAME/$BRANCH.md`

Required structure:

```markdown
Branch: <branch-name>
Created: <date>
Updated: <date>
Issue: <owner/repo#N — auto-populated by issue-sync.sh create>

# <Title>

## Context
<Rich context — the WHY, the architecture, the decisions, the constraints.
This section should be detailed enough that a new session with no prior
context can understand the full scope of the work.>

## Implementation Plan

### <Section 1>
- [ ] Step description — what to do, what files to touch
- [ ] Step description

### <Section 2>
- [ ] Step description

## Key Decisions
- Decision and rationale

## Edge Cases
- Edge case and how to handle it

## Test Infrastructure
- Test runner: <detected runner>
- Test file count: <N> files found
- Test patterns: <patterns used in this codebase>

## Progress
Plan created on <date>.
```

Present the plan to the user. Get confirmation before proceeding.

---

## Phase 3: Connect to Proof System

### Parent issue linking

If `$ARGUMENTS` contains a parent issue reference (format: `owner/repo#N`), link the plan's tracking issue as a sub-issue:

```bash
if echo "$ARGUMENTS" | grep -qE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+'; then
  PARENT_REF=$(echo "$ARGUMENTS" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | head -1)
  bash "$PLUGIN_DIR/issue-sync.sh" link-parent "$PLAN_FILE" "$PARENT_REF" 2>/dev/null || true
fi
```

Initialize the quality directory:

```bash
mkdir -p .quality/proof .quality/checkpoints
```

Add `.quality/` to `.gitignore` if not already present.

Save the initial plan checkpoint:

```bash
bash "$PLUGIN_DIR/checkpoint.sh" save plan "Plan ready — $(grep -c '\- \[ \]' "$PLAN_FILE") items to implement"
```

Show the plan status:

```bash
bash "$PLUGIN_DIR/plan-progress.sh" status "$PLAN_FILE"
```

---

## Phase 3b: Commit Any Changes

If the plan phase modified any tracked files (e.g., adding `.quality/` to `.gitignore`), commit immediately:

```bash
git status --porcelain | grep -q . && git add -u && git commit -m "$(cat <<'EOF'
chore: initialize quality infrastructure for sdlc workflow

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: Handoff to Build

Tell the user:

1. The plan is ready at `$PLAN_FILE`
2. How many items are in the plan
3. Run `/sdlc:pair-build` to start implementation
4. Each item will be checked off with a proof anchor when gates pass

**DO NOT start building.** This skill's job is planning only. Implementation is `/sdlc:pair-build`'s job.

---

## How Proof-Anchored Checkboxes Work

When `/sdlc:pair-build` completes a plan item:

1. Run the relevant quality gates: `bash "$PLUGIN_DIR/run-gates.sh" build`
2. Save a checkpoint: `bash "$PLUGIN_DIR/checkpoint.sh" save build "Completed: <item description>"`
3. Mark the item done: `bash "$PLUGIN_DIR/plan-progress.sh" mark "$PLAN_FILE" "<search text>"`

This transforms:
```markdown
- [ ] Add user auth endpoint
```

Into:
```markdown
- [x] Add user auth endpoint <!-- proof: build-latest -->
```

The proof anchor references a checkpoint file in `.quality/checkpoints/` that contains:
- Git SHA at time of verification
- All gate results (pass/fail)
- Timestamp

To verify any checked item: `bash "$PLUGIN_DIR/plan-progress.sh" check "$PLAN_FILE"`

This catches:
- Items checked without running gates (no anchor)
- Items checked with failing gates (failed proof)
- Items checked at old commits where code has since changed (stale proof)
