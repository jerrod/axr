---
name: design-audit
description: "UI quality audit — inspects computed CSS across typography, spacing, color, layout, interaction, accessibility, and polish. Produces letter grades per category. Requires Preview MCP tools. Trigger: 'audit the design', 'check UI quality', 'grade the frontend', 'design review'."
---

# Design Audit

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log review sdlc:design-audit started --context "$ARGUMENTS"`
- **End:** `bash "$AUDIT_SCRIPT" log review sdlc:design-audit completed --context="<summary>"`

Perform a structured 80-item design audit powered by browser CSS inspection. Each of 7 categories gets a letter grade (A-F).

## When to Use

- During review phase, after code gates and QA pass
- Standalone: `/sdlc:design-audit` to audit the current UI
- After fixing design-related review findings

## Checklist

1. **Launch the app** — start dev server via Preview tools
2. **Audit each category** — Typography, Spacing, Color, Layout, Interaction, Accessibility, Polish
3. **Inspect with real CSS** — use `preview_inspect` for computed values, not guessing
4. **Test responsive** — resize to mobile/tablet/desktop
5. **Capture screenshots** — document issues and viewport states
6. **Score and grade** — per-item scores, per-category grades
7. **Write proof** — save to `.quality/proof/design-audit.json`

## Categories (80 items total)

| Category | Items | Key tools |
|---|---|---|
| Typography | 12 | `preview_inspect` for font-size, line-height, font-weight |
| Spacing | 10 | `preview_inspect` for padding, margin, gap |
| Color | 12 | `preview_inspect` for color, background-color + contrast calc |
| Layout | 12 | `preview_resize` + `preview_screenshot` for responsive |
| Interaction | 12 | `preview_eval` for hover/focus states |
| Accessibility | 12 | `preview_snapshot` for ARIA, roles, labels |
| Polish | 10 | Mix of all tools |

## Grading Scale

| Score | Grade |
|---|---|
| >= 90% | A |
| >= 80% | B |
| >= 70% | C |
| >= 60% | D |
| < 60% | F |

Configurable minimum grade in `sdlc.config.json` (default: no category below C).

## Proof Artifacts

- `.quality/proof/design-audit.json` — per-item scores, per-category grades, overall grade
- `.quality/proof/screenshots/*.png` — viewport screenshots and issue documentation

## Integration with Ship

The ship skill includes the grade table and screenshots in the PR description under a `## Design Audit` section.
