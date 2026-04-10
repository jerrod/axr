---
name: test-fixer
description: "Use this skill to replace over-mocked tests with real behavioral tests. Invoke when: tests mock the module under test, deleting source files wouldn't break tests, tests only assert on mock call counts, spyOn().mockImplementation() everywhere, or the test-quality gate keeps rejecting disguised mocks. Also triggers on \"fix test quality\", \"too many mocks pretending to be real tests\", or \"audit the test suite for antipatterns\". Performs a full codebase scan and rewrites across Python, JS/TS, Java, Kotlin, Go, and Ruby. Do NOT use for slow tests (use optimize-tests), writing new tests, or fixing test failures unrelated to mock quality."
---

# Fix Testing Antipatterns

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log build sdlc:test-fixer started --context="$ARGUMENTS"`
- **End:** `bash "$AUDIT_SCRIPT" log build sdlc:test-fixer completed --context="<summary>"`

Find and fix ALL testing antipatterns in the current codebase. Framework-agnostic — covers Python (pytest, unittest), JavaScript/TypeScript (vitest, jest, mocha), Java (JUnit, Mockito, TestNG), Kotlin (JUnit, MockK), Go (testing, testify), and Ruby (RSpec, Minitest).

**NEVER truncate command output** with `| head`, `| tail`, or `| grep`. Redirect to a tmp file (`> /tmp/output.out 2>&1`) and Read the file. One run, full output.

**Announce at start:** "I'm using the test-fixer skill to find and fix testing antipatterns."

## What This Fixes

| Antipattern | What It Looks Like | What It Should Be |
|---|---|---|
| Mocking module under test | `jest.mock('./calculator')` then testing calculator | Import real calculator, call with real inputs |
| Disguised mocks | `spyOn(calc, 'add').mockReturnValue(5)` | Call `calc.add(2, 3)`, assert result is `5` |
| Internal module mocking | `@patch('myapp.helpers.validate')` | Call real `validate()`, test real behavior |
| Assert-on-mock-calls only | `expect(fn).toHaveBeenCalledWith(x)` | Assert on return value or side effect |
| No meaningful assertions | `expect(true).toBe(true)` | Assert on actual function output |
| Happy-path only | Only tests normal inputs | Add error paths, edge cases, boundaries |

## The Process

1. **Detect** the project's test framework from project files
2. **Scan** all test files for antipatterns (regex-based, same approach as `scan_disguised_mocks.py`)
3. **Present** findings grouped by severity (Critical > High > Medium > Low)
4. **Fix** each finding: rewrite tests to call real code with real inputs
5. **Verify** tests pass and coverage holds after each rewrite
6. **Commit** per-file: `fix: replace mocked tests with behavioral tests in <file>`

## When Coverage Drops

If rewriting a mocked test causes coverage to drop, a mock was hiding a real bug. The real code path fails when actually exercised. Flag this explicitly — it's a genuine bug that the mock was masking. Do not re-add the mock to restore coverage.

## Relationship to Other Tools

- **gate-test-quality.sh** catches disguised mocks reactively — this skill fixes them
- **flaky-test-fixer** agents fix timing/ordering issues — this skill fixes quality issues
- **gate-coverage.sh** enforces 95% coverage — this skill ensures coverage is real, not mocked
