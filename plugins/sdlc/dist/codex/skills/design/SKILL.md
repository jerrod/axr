---
name: design
description: "Design system orchestration — bootstraps design-context.md from project scan, enforces design constraints during builds, runs unified design review. Trigger: 'design init', 'design review', 'set up design system', 'check design quality', 'sdlc:design'."
argument-hint: "[init|review] (bare invocation auto-detects phase)"
allowed-tools: Bash(git *), Bash(bash plugins/*), Read, Edit, Write, Glob, Grep, Agent
---

# Design Orchestration

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
[[ "$AUDIT_SCRIPT" != "$HOME/.claude/"* && "$AUDIT_SCRIPT" != "./"* ]] && AUDIT_SCRIPT=""
SAFE_ARGS="${ARGUMENTS//\"/\\\"}"
```

- **Start:** `bash "$AUDIT_SCRIPT" log design sdlc:design started --context="$SAFE_ARGS"`
- **End:** `bash "$AUDIT_SCRIPT" log design sdlc:design completed --context="<summary>"`

## Overview

`sdlc:design` is the design orchestration layer for the sdlc workflow. It routes to the right phase based on project state and explicit arguments.

## Phase Detection

Determine which phase to run:

| Argument | Phase | What happens |
|---|---|---|
| `init` | Bootstrap | Scan project, create or update `.claude/design-context.md` |
| `review` | Review | Run design-reviewer agent for full design verification |
| *(none)* | Auto-detect | Check state and route (see below) |

Use `sdlc:design init` explicitly to re-bootstrap when the design system changes (e.g., switching component libraries, rebrand, adding Tailwind).

### Auto-detection Logic

When invoked without arguments:

1. Check if `.claude/design-context.md` exists
2. If **no** — run the `init` phase
3. If **yes** — run the `review` phase

---

## Phase 1: Init (Bootstrap)

Create or update the project's design context file.

### Step 1: Branch Guard

Verify you are on a feature branch before committing:

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
CURRENT=$(git branch --show-current)
if [ "$CURRENT" = "$DEFAULT_BRANCH" ]; then
  echo "On default branch — create a feature branch first"
  # Create: git checkout -b chore/design-context-init
fi
```

### Step 2: Check for Existing Context

```bash
if [ -f ".claude/design-context.md" ]; then
  echo "design-context.md already exists"
fi
```

If it exists, ask the user: "A design-context.md already exists. Update it from current project state, or start fresh?"

### Step 3: Scan Project

Follow the detection guide in `skills/design/design-bootstrap.md`. Scan for:

1. **Component library** — shadcn components.json, package.json deps
2. **Tailwind config** — theme colors, fonts, spacing
3. **CSS variables** — :root custom properties
4. **Fonts** — Google Fonts, @font-face, next/font, @fontsource
5. **Colors** — hex/rgb values in CSS and components
6. **Spacing patterns** — Tailwind classes, CSS values
7. **Motion** — transitions, animations, motion libraries

Report what was detected:

```
## Scan Results

- Component library: shadcn/ui (components.json found)
- Framework: React (package.json)
- Tailwind: yes (tailwind.config.ts)
- Fonts detected: "Inter" (body), "Cal Sans" (display)
- Colors: 7 unique values found in CSS variables
- Spacing: 8px base scale detected
- Motion: framer-motion detected
```

### Step 4: Generate or Guide

**If design tokens were detected:** Generate `.claude/design-context.md` from scan results. Present to the user for review before writing.

**If no design system found:** Guide the user through aesthetic selection:

1. Present the 11 aesthetic directions (from `skills/design/design-bootstrap.md`)
2. User selects a direction or describes their own
3. Recommend fonts, colors, spacing, motion that match the direction
4. Present the proposed design-context.md
5. User approves or adjusts

### Step 5: Write and Commit

Write `.claude/design-context.md` and commit:

```bash
mkdir -p .claude
# Write the file
git add .claude/design-context.md
git commit -m "$(cat <<'EOF'
feat: add design context for consistent frontend development

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Review

Run a comprehensive design review combining design-audit, accessibility, and responsive checks.

### Prerequisites

- `.claude/design-context.md` must exist (if not, redirect to `init` phase)
- App must be running or buildable for browser-based checks

### Step 1: Determine Scope

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
git diff "origin/$DEFAULT_BRANCH"...HEAD --name-only | grep -E '\.(tsx|jsx|css|scss|html)$'
```

If no frontend files changed, report: "No frontend files in diff. Design review not needed."

### Step 2: Dispatch Design Reviewer

Launch the design-reviewer agent for the full audit:

```
Agent(
  subagent_type="sdlc:design-reviewer",
  description="Design review: audit + a11y + responsive",
  prompt="Run a full design review on the changed frontend files.
    Design context: .claude/design-context.md
    Changed files: <list>
    Produce proof at .quality/proof/design-review.json"
)
```

### Step 3: Present Results

After the agent completes, read the proof file and present results:

```
## Design Review Results

### Grades
| Category | Grade | Score |
|---|---|---|
| Typography | A | 92% |
| Spacing | B+ | 85% |
| ... | ... | ... |

### Findings
- [file:line] CONTRAST: text color #999 on white bg fails 4.5:1 minimum
- [file:line] TOKEN: hardcoded color #ff6b6b not in design palette

### Overall: B+
```

### Step 4: Fix Loop

If any category grades below B:

1. Present specific violations with file:line references
2. Apply fixes (interactively with user)
3. Re-run the affected category checks
4. Repeat until all categories reach B or above

Default threshold: all categories must reach B. When `load-config.sh` gains a `design` section, this will be configurable via `sdlc.config.json`.

---

## Integration Points

### With pair-build

During `pair-build`, the critic reads `.claude/design-context.md` (if present) and checks design constraints from `skills/design/design-constraints.md`. This catches token consistency, a11y baseline, and performance patterns before code is committed.

### With review

During `sdlc:review`, if the diff contains frontend files, the review skill auto-triggers the design review phase (Step 2 above) as an additional review dimension alongside architecture, security, correctness, and style.

### With brainstorm

During `sdlc:brainstorm`, if the project lacks a `.claude/design-context.md`, the brainstorm skill recommends running `sdlc:design init` before or after the boardroom phase to establish design tokens.

### With ship

When `collect-proof.sh` gains a `design-review.json` handler, the ship skill will include design review grades in the PR description. Until then, run `sdlc:design review` standalone and reference the proof file manually.

---

## Reference Documents

| Document | Purpose |
|---|---|
| `skills/design/design-bootstrap.md` | Detection guide for scanning project tokens |
| `skills/design/design-constraints.md` | Proactive rules the critic checks during builds |
| `skills/design/a11y-rules.md` | WCAG 2.1 AA checklist for accessibility verification |
| `skills/brainstorm/frontend-design-principles.md` | Aesthetic direction and creative guidance |
| `agents/design-reviewer.md` | Autonomous agent for unified design review |
| `agents/design-auditor.md` | 80-item browser-based CSS inspection agent (separate from design-reviewer; requires Preview MCP tools) |
