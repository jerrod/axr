---
name: optimize-tests
description: "Analyze and speed up slow pytest test suites. Uses --durations to find bottlenecks, diagnoses root causes (fixture scope, redundant setup, missing mocks at boundaries, sleep calls), and applies targeted fixes. Python/pytest only. Trigger: 'tests are slow', 'speed up tests', 'optimize the test suite'."
argument-hint: "[threshold_seconds] — minimum duration to flag as slow (default: 1.0)"
allowed-tools: Bash(pytest *), Bash(python3 *), Bash(git *), Bash(wc *), Bash(bin/*), Bash(bash plugins/*), Read, Edit, Write, Glob, Grep
---

# Optimize Tests: Pytest Performance Refactoring

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
```

- **Start:** `bash "$AUDIT_SCRIPT" log build sdlc:optimize-tests started --context="$ARGUMENTS"`
- **End:** `bash "$AUDIT_SCRIPT" log build sdlc:optimize-tests completed --context="<summary>"`

## Guiding Principle

**Tests must be fast AND correct.** Speed without correctness is worse than slow — it creates a false sense of safety. Every optimization must preserve the original test's ability to catch regressions. If you cannot speed up a test without weakening it, leave it slow and document why.

## Anti-Mock Constraint

The anti-mock rules from `testing.md` apply at all times during optimization. Specifically:

- NEVER mock the module/class/function under test to make it faster
- NEVER replace real assertions with mock call verifications
- NEVER use `spyOn().mockImplementation()` on internal code
- Mocking is ONLY acceptable at external boundaries: HTTP clients, databases, filesystem, time, third-party SDKs
- If a test is slow because it exercises real business logic, the fix is to make the logic faster or accept the cost — not to fake it

---

## Step 1: Discover Test Files

```bash
echo "=== Pytest Discovery ==="
[ -f "pyproject.toml" ] && echo "pyproject.toml: exists" || echo "pyproject.toml: missing"
[ -f "pytest.ini" ] && echo "pytest.ini: exists"
[ -f "setup.cfg" ] && grep -q "\[tool:pytest\]" setup.cfg 2>/dev/null && echo "setup.cfg: pytest config found"
[ -f "conftest.py" ] && echo "conftest.py: root level"
```

Use Glob to find all test files:

```
Glob: **/test_*.py
Glob: **/*_test.py
Glob: **/conftest.py
```

Count and report:

```bash
find . -name "test_*.py" -o -name "*_test.py" | wc -l | xargs echo "Test files found:"
find . -name "conftest.py" | wc -l | xargs echo "Conftest files found:"
```

---

## Step 2: Baseline Timing

Run pytest with duration reporting to identify slow tests:

```bash
THRESHOLD="${ARGUMENTS:-1.0}"
# Validate threshold is a number
OT_THRESHOLD="$THRESHOLD" python3 -c "float(__import__('os').environ['OT_THRESHOLD'])" 2>/dev/null || { echo "Error: threshold must be a number, got '$THRESHOLD'"; exit 1; }
echo "Slow test threshold: ${THRESHOLD}s"
python3 -m pytest --durations=0 -q 2>&1 | tee /tmp/pytest-durations.txt
```

Parse the output to extract slow tests:

```bash
python3 -c "
import sys

threshold = float(sys.argv[1])
slow_tests = []
parsing = False

for line in open('/tmp/pytest-durations.txt'):
    line = line.strip()
    if 'slowest' in line.lower() or 'durations' in line.lower():
        parsing = True
        continue
    if parsing and line and 's ' in line:
        parts = line.split()
        try:
            duration = float(parts[0].rstrip('s'))
            test_name = parts[-1] if len(parts) >= 2 else line
            if duration >= threshold:
                slow_tests.append((duration, test_name))
        except (ValueError, IndexError):
            continue

if not slow_tests:
    print(f'No tests slower than {threshold}s. Suite is already fast.')
    sys.exit(0)

slow_tests.sort(reverse=True)
total_slow = sum(d for d, _ in slow_tests)
print(f'Found {len(slow_tests)} slow tests (total: {total_slow:.1f}s)')
print()
for duration, name in slow_tests:
    print(f'  {duration:6.2f}s  {name}')
" "$THRESHOLD"
```

Save the baseline for later comparison:

```bash
cp /tmp/pytest-durations.txt /tmp/pytest-durations-baseline.txt
```

If no slow tests are found, report that and stop.

---

## Step 3: Diagnose Root Causes

For each slow test (starting with the slowest), read the test file and its fixtures. Classify the slowness into one or more categories:

### 3a. Fixture Scope Issues

Look for fixtures that are `scope="function"` (the default) but perform expensive operations that could be shared:

```
Grep: @pytest.fixture
Grep: scope=
```

**Symptoms:**
- Database connections created per test instead of per module/session
- Large data files loaded per test
- External service clients initialized per test
- Heavy object construction repeated identically across tests

**Diagnosis rule:** If a fixture produces the same result for every test in a module and has no side effects that leak between tests, it should be `scope="module"` or `scope="session"`.

### 3b. Missing Boundary Mocks

Look for tests that make real external calls:

```
Grep: requests\.(get|post|put|delete|patch)
Grep: httpx\.(get|post|put|delete|patch|Client|AsyncClient)
Grep: urllib\.request
Grep: aiohttp\.ClientSession
Grep: subprocess\.(run|call|Popen|check_output)
Grep: open\(.*['"]/
Grep: sqlite3\.connect|psycopg|pymongo|sqlalchemy\.create_engine
Grep: smtp|smtplib
Grep: boto3
```

**Diagnosis rule:** Any call that crosses a network, hits disk outside `tmp_path`, or talks to an external service should be mocked at the boundary — not at the function under test.

### 3c. Sleep Calls

```
Grep: time\.sleep\(
Grep: asyncio\.sleep\(
Grep: sleep\(
```

**Diagnosis rule:** `sleep()` in tests is almost always wrong. If waiting for a condition, use polling with a short interval. If testing timeout behavior, mock `time.time()` or use `freezegun`.

### 3d. Redundant Parametrize Combinations

```
Grep: @pytest\.mark\.parametrize
```

Read parametrize decorators and check if multiple parameter combinations exercise the same code path. Look for:
- Cartesian products where most combinations are equivalent
- Parameters that only differ in values that do not affect branching
- Parametrize on data that could be a single representative case

### 3e. Repeated Expensive Setup

Look for patterns where multiple test functions in the same file perform identical setup in their body (not via fixtures):

- Same object construction at the top of multiple test functions
- Same file reads or data parsing repeated
- Same mock setup copied across tests

### 3f. Unnecessary Real I/O

Look for tests that read/write real files when they do not need to:

```
Grep: open\(
Grep: Path\(
Grep: os\.(read|write|mkdir|makedirs|listdir)
Grep: shutil\.(copy|move|rmtree)
```

**Diagnosis rule:** If the test is not testing I/O behavior itself, use `tmp_path`, `StringIO`, or in-memory alternatives.

---

## Step 4: Prioritize Optimizations

Rank the diagnosed issues by expected impact:

```
## Optimization Plan

| Priority | Test/File | Issue | Expected Savings | Risk |
|----------|-----------|-------|------------------|------|
| 1 | test_api.py::test_fetch_users | Real HTTP call | ~2.0s | Low — boundary mock |
| 2 | conftest.py::db_connection | function scope → session | ~5.0s total | Medium — verify no leaks |
| 3 | test_parser.py (12 tests) | sleep(0.5) in each | ~6.0s total | Low — remove sleeps |
| 4 | test_integration.py | Redundant parametrize | ~3.0s | Low — reduce combos |
```

Present the plan to the user. For each optimization, explain:
- What will change
- Why it is safe
- What could go wrong
- Whether it needs user confirmation (destructive changes do)

---

## Step 5: Apply Optimizations

Work through the plan one optimization at a time. After each change:

### 5a. Verify correctness

```bash
python3 -m pytest <affected_test_file> -v 2>&1
```

All tests in the affected file must still pass. If any fail, revert and diagnose.

### 5b. Measure improvement

```bash
python3 -m pytest <affected_test_file> --durations=0 -q 2>&1
```

### 5c. Report the change

```
### Optimization: Widen db_connection fixture scope

**File:** conftest.py
**Change:** `@pytest.fixture` -> `@pytest.fixture(scope="module")`
**Before:** 12 tests x 0.5s setup = 6.0s
**After:** 1 setup x 0.5s = 0.5s
**Savings:** 5.5s
**Tests:** 12/12 passing
```

### Optimization Recipes

| Issue | Fix | Safety Check |
|-------|-----|-------------|
| Fixture scope too narrow | Widen `scope="function"` to `"module"` or `"session"` | Verify no test mutates the fixture state |
| Real HTTP/DB calls | Mock at the boundary (httpx_mock, test DB) — never mock the function under test | Assertions still test real logic |
| `time.sleep()` | Poll with short interval + timeout, or use `freezegun` for time-dependent logic | Remove only arbitrary waits, not deliberate timing tests |
| Redundant parametrize | Replace cartesian products with representative edge cases | Cover zeros, negatives, boundaries, large values |
| Repeated setup | Extract to `@pytest.fixture` shared across tests | Ensure fixture is stateless or use teardown |
| Unnecessary file I/O | Use `tmp_path` fixture or `StringIO` | Only for tests not testing I/O behavior itself |

---

## Step 6: Full Suite Verification

After all optimizations are applied, run the complete test suite:

```bash
python3 -m pytest --durations=0 -q 2>&1 | tee /tmp/pytest-durations-after.txt
```

Compare `/tmp/pytest-durations-baseline.txt` vs `/tmp/pytest-durations-after.txt` — parse duration lines, compute total before/after, and list most improved tests.

### Verify all tests still pass

```bash
python3 -m pytest -q 2>&1
```

If any tests fail, revert the last optimization and investigate.

---

## Step 7: Report

Present a summary with:
- Before/after suite time and percentage improvement
- Table of optimizations applied (change, file, savings)
- Table of intentionally slow tests left unchanged (test, duration, reason)
- Recommendations: `@pytest.mark.slow` for integration tests, `pytest-xdist` for parallelism
