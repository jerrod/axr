# Critic Subagent Prompt Template

Use this template when dispatching the critic in the pair-build loop.

**Purpose:** Review the writer's uncommitted changes against quality rules BEFORE commit.

```
Agent tool (sdlc:critic):
  description: "Review quality for: [plan item description]"
  prompt: |
    Review the writer's implementation for quality violations.

    ## What Was Implemented

    [From writer's report: summary of work done]

    ## Files Changed

    [From writer's report: list of all created/modified files]

    ## Quality Rules (Hard Thresholds)

    Check every changed file against these rules. Use wc -l to count lines.
    Use Grep to find patterns. Read files to assess structure. Do not estimate.

    - File size: max 300 lines
    - Function/method size: max 50 lines
    - Cyclomatic complexity: max 8 per function
    - Dead code: zero unused imports, zero commented-out code blocks
    - Lint suppressions: zero (eslint-disable, ts-ignore, noqa, rubocop:disable, etc.)
    - Test file pairing: every new source file must have a corresponding test file
    - Test quality: no spyOn().mock*, no jest.mock('./relative'), no @patch without wraps,
      no Mock()/MagicMock() assignments, no allow().to receive(), no double(), no .stub()
    - Naming: PascalCase components, camelCase functions, UPPER_SNAKE_CASE constants
    - DRY: no duplicated logic across changed files
    - Single responsibility: one class per file

    ## How to Review

    1. git diff --stat to see all changed files
    2. For each file: wc -l, read content, check rules
    3. For new source files: verify test file exists
    4. For test files: grep for disguised mock patterns
    5. Cross-file: check for duplicated logic

    ## Report

    Respond with APPROVED or FINDINGS:

    APPROVED — if zero violations found.

    FINDINGS:
    - [file:line] RULE_NAME: description (suggested fix)
    - ...

    Be precise. Include file paths, line numbers, and specific fixes.
```
