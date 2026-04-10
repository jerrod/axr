# bin/ Script Templates for LLM-Friendly Output

## Design Principles

1. **Failures only** — zero output on success (exit 0 silently)
2. **file:line:message** — every finding references a location
3. **No ANSI** — strip color codes, no spinners, no progress bars
4. **No noise** — no banners, no "checking...", no timing stats
5. **Bounded** — cap output at 50 lines to avoid flooding context
6. **Exit code** — 0 = pass, non-zero = fail (let the code speak)

## Detection Order

Each script should detect the project's toolchain in this order:
1. Project config files (package.json, pyproject.toml, Gemfile, build.gradle, go.mod, Cargo.toml)
2. Lock files (pnpm-lock.yaml → pnpm, yarn.lock → yarn, package-lock.json → npm)
3. Available commands (ruff, rubocop, golangci-lint, ktlint)

## Package Manager Detection

```bash
pkg_run() {
  if [ -f "pnpm-lock.yaml" ]; then pnpm "$@"
  elif [ -f "yarn.lock" ]; then yarn "$@"
  elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then bun "$@"
  else npm "$@"
  fi
}

pkg_exec() {
  if [ -f "pnpm-lock.yaml" ]; then pnpm exec "$@"
  elif [ -f "yarn.lock" ]; then yarn "$@"
  elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then bunx "$@"
  else npx "$@"
  fi
}
```

---

## bin/lint

```bash
#!/usr/bin/env bash
set -euo pipefail

# Strip ANSI codes from output
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

if [ -f "package.json" ]; then
  if grep -q '"biome"' package.json 2>/dev/null; then
    pkg_exec biome check . --max-diagnostics=50 2>&1 | strip_ansi | head -50
  elif grep -q '"eslint"' package.json 2>/dev/null; then
    pkg_exec eslint . --format unix --max-warnings=0 2>&1 | strip_ansi | head -50
  fi
elif [ -f "pyproject.toml" ] || [ -f "setup.cfg" ] || [ -f "ruff.toml" ]; then
  ruff check . --output-format concise 2>&1 | head -50
elif [ -f "Gemfile" ]; then
  bundle exec rubocop --format emacs 2>&1 | strip_ansi | head -50
elif [ -f "go.mod" ]; then
  go vet ./... 2>&1 | head -50
  golangci-lint run --out-format line-number 2>&1 | head -50 || true
elif [ -f "Cargo.toml" ]; then
  cargo clippy --message-format short -- -D warnings 2>&1 | grep '^[a-z]' | head -50
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  ktlint --reporter=plain 2>&1 | head -50 || true
  detekt --report txt:- 2>&1 | head -50 || true
fi
```

**What good output looks like:**
```
src/api/handler.ts:42:10: Unexpected 'any' type
src/utils/parse.ts:17:1: Missing return type
```

**What bad output looks like:**
```
✨ Linting your code...
  ✓ src/index.ts
  ✓ src/app.ts
  ✗ src/api/handler.ts
    Line 42:10  error  Unexpected any type  @typescript-eslint/no-explicit-any
📝 1 problem found (1 error, 0 warnings)
Done in 2.3s
```

---

## bin/format

```bash
#!/usr/bin/env bash
set -euo pipefail

# Output: one file path per line that needs formatting. Nothing on success.

if [ -f "package.json" ]; then
  if grep -q '"biome"' package.json 2>/dev/null; then
    pkg_exec biome format . --write=false 2>&1 | grep '^Formatter' | sed 's/Formatter would have printed the following content: //' | head -50
  elif grep -q '"prettier"' package.json 2>/dev/null; then
    pkg_exec prettier --list-different "**/*.{ts,tsx,js,jsx,json,css,html}" 2>&1 | head -50
  fi
elif [ -f "pyproject.toml" ] || [ -f "ruff.toml" ]; then
  ruff format --check --diff . 2>&1 | grep '^---\|^+++' | sed 's/^[+-]* //' | head -50
elif [ -f "Gemfile" ]; then
  bundle exec rubocop --format files --only Layout 2>&1 | head -50
elif [ -f "go.mod" ]; then
  gofmt -l . 2>&1 | head -50
elif [ -f "Cargo.toml" ]; then
  cargo fmt -- --check -l 2>&1 | head -50
fi
```

**What good output looks like:**
```
src/api/handler.ts
src/utils/parse.ts
```

---

## bin/test

```bash
#!/usr/bin/env bash
set -euo pipefail

# Output: only failures with context. Silent on full pass (exit 0 is enough).
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

if [ -f "package.json" ]; then
  if grep -q '"vitest"' package.json 2>/dev/null; then
    pkg_exec vitest run --reporter=dot 2>&1 | strip_ansi | tail -20
  elif grep -q '"jest"' package.json 2>/dev/null; then
    pkg_exec jest --verbose=false --no-coverage 2>&1 | strip_ansi | grep -E '(FAIL|✕|●|Error|Expected|Received|at )' | head -50
  elif grep -q '"mocha"' package.json 2>/dev/null; then
    pkg_exec mocha --reporter dot 2>&1 | strip_ansi | tail -20
  else
    pkg_run test 2>&1 | strip_ansi | tail -30
  fi
elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
  python -m pytest --tb=short -q --no-header 2>&1 | tail -30
elif [ -f "Gemfile" ]; then
  if [ -d "spec" ]; then
    bundle exec rspec --format progress --no-color 2>&1 | tail -30
  else
    bundle exec rake test 2>&1 | strip_ansi | tail -30
  fi
elif [ -f "go.mod" ]; then
  go test -count=1 ./... 2>&1 | grep -v '^ok' | head -50
  # show only failures — 'ok' lines are passing packages
elif [ -f "Cargo.toml" ]; then
  cargo test --no-fail-fast 2>&1 | grep -E '(FAILED|panicked|failures:|test result:)' | head -50
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  if [ -f "gradlew" ]; then
    ./gradlew test --console=plain --quiet 2>&1 | strip_ansi | tail -30
  fi
elif [ -f "pom.xml" ]; then
  mvn test -q 2>&1 | grep -E '(FAIL|ERROR|Tests run:)' | head -50
fi
```

**What good output looks like (failure):**
```
FAIL src/utils/parse.test.ts
  ● parseAddress › splits components
    Expected: "123 Main St"
    Received: "123 Main"
    at src/utils/parse.test.ts:15:5

1 failed, 23 passed
```

**What good output looks like (pass):**
```
24 passed
```

---

## bin/typecheck

```bash
#!/usr/bin/env bash
set -euo pipefail

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

if [ -f "tsconfig.json" ]; then
  pkg_exec tsc --noEmit --pretty false 2>&1 | head -50
elif [ -f "pyproject.toml" ] || [ -f "mypy.ini" ]; then
  mypy . --no-error-summary 2>&1 | grep ': error:' | head -50
elif [ -f "go.mod" ]; then
  go build ./... 2>&1 | head -50
fi
```

**What good output looks like:**
```
src/api/handler.ts(42,10): error TS2345: Argument of type 'string' is not assignable...
```

---

## bin/coverage

```bash
#!/usr/bin/env bash
set -euo pipefail

MIN_COVERAGE="${MIN_COVERAGE:-95}"
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Output: only files below threshold. Format: file:coverage%
# Silent if everything passes.

if [ -f "package.json" ]; then
  if grep -q '"vitest"' package.json 2>/dev/null; then
    pkg_exec vitest run --coverage --reporter=dot --coverage.reporter=json 2>&1 > /dev/null
  elif grep -q '"jest"' package.json 2>/dev/null; then
    pkg_exec jest --coverage --silent --coverageReporters=json-summary 2>&1 > /dev/null
  fi

  # Parse JSON summary — report only below-threshold files
  SUMMARY=""
  for f in coverage/coverage-summary.json coverage-summary.json; do
    [ -f "$f" ] && SUMMARY="$f" && break
  done
  if [ -n "$SUMMARY" ]; then
    python3 -c "
import json, sys
with open('$SUMMARY') as f:
    data = json.load(f)
below = []
for path, metrics in data.items():
    if path == 'total': continue
    pct = metrics.get('lines', {}).get('pct', 100)
    if pct < $MIN_COVERAGE:
        # Shorten path — remove cwd prefix
        short = path.replace('$PWD/', '')
        below.append(f'{short}:{pct}%')
if below:
    print('\n'.join(sorted(below)))
    sys.exit(1)
total = data.get('total', {}).get('lines', {}).get('pct', 0)
print(f'coverage:{total}%')
"
  fi
elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
  python -m pytest --cov --cov-report=term-missing --tb=no -q --no-header 2>&1 \
    | grep -v '^$' \
    | awk -v min="$MIN_COVERAGE" '
      /TOTAL/ { total=$NF; next }
      /^[a-zA-Z]/ { gsub(/%/,"",$NF); if ($NF+0 < min+0) print $1 ":" $NF "%" }
      END { if (total) print "coverage:" total }
    '
elif [ -f "go.mod" ]; then
  go test -coverprofile=coverage.out ./... 2>&1 > /dev/null
  go tool cover -func=coverage.out 2>/dev/null \
    | awk -v min="$MIN_COVERAGE" '{
        gsub(/%/,"",$NF)
        if ($1 == "total:") { print "coverage:" $NF "%" }
        else if ($NF+0 < min+0) { print $1 ":" $NF "%" }
      }'
  rm -f coverage.out
fi
```

**What good output looks like (pass):**
```
coverage:97.2%
```

**What good output looks like (failure):**
```
src/api/handler.ts:42.1%
src/utils/parse.ts:88.3%
coverage:93.1%
```

---

## Evaluating Existing bin/ Scripts

Signs of LOW-signal output (offer to improve):
- ANSI color codes in output (`\x1b[`, `\033[`)
- Progress indicators (spinners, dots that aren't test dots, percentage bars)
- Banner lines (`===`, `---`, `***`, ASCII art)
- Timing stats (`Done in 2.3s`, `Time: 1.234s`)
- Success messages for passing items (`✓ src/index.ts`, `PASS src/app.test.ts`)
- Verbose mode on by default
- More than 50 lines of output for a clean run
- No `| head` cap — unbounded output on failure

Signs of HIGH-signal output (leave alone):
- Silent on success (exit code is the signal)
- Only failures with file:line references
- Output capped at a reasonable bound
- No ANSI codes (or stripped)
- Machine-parseable format
