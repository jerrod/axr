# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

```
Agent tool (sdlc:reviewer):
  description: "Review code quality for Task N"
  prompt: |
    Review the code quality of the implementation.

    WHAT_WAS_IMPLEMENTED: [from implementer's report]
    PLAN_OR_REQUIREMENTS: Task N from [plan-file]
    BASE_SHA: [commit before task]
    HEAD_SHA: [current commit]
    DESCRIPTION: [task summary]
```

**In addition to standard code quality concerns, the reviewer should check:**
- Does each file have one clear responsibility with a well-defined interface?
- Are units decomposed so they can be understood and tested independently?
- Is the implementation following the file structure from the plan?
- Did this implementation create new files that are already large, or significantly grow existing files? (Don't flag pre-existing file sizes — focus on what this change contributed.)
- Do these tests verify behavior from the outside, or do they read like they were written by someone who knows how the function works internally? Tests should be indistinguishable from tests written by someone who only read the function signature and behavioral spec.

**Code reviewer returns:** Strengths, Issues (Critical/Important/Minor), Assessment
