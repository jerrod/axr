---
name: bootstrap
description: "Scaffold high-signal bin/ scripts (lint, format, test, typecheck, coverage) for any project. Detects toolchain, creates minimal-output scripts optimized for LLM agents, and audits existing scripts for noise."
argument-hint: "[audit] — run without args to scaffold, 'audit' to evaluate existing scripts"
allowed-tools: Bash(git *), Bash(ls *), Bash(cat *), Bash(chmod *), Bash(bash plugins/*), Read, Edit, Write, Glob, Grep, Agent
---

# Bootstrap: High-Signal bin/ Scripts

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log bootstrap sdlc:bootstrap started --context "$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log bootstrap sdlc:bootstrap completed --context="<summary>"`

## Purpose

LLM agents waste tokens on noisy tool output. Every `bin/` script this skill creates follows one rule: **failures only, with file:line references.** Zero output on success — the exit code is the signal. Never truncate output with `| head` or `| tail` — use tool-native flags to reduce noise instead.

Gate scripts (`gate-lint.sh`, `gate-tests.sh`, etc.) prefer `bin/` scripts over running tools directly. This skill creates those scripts so gates produce clean, actionable proof.

---

## Step 1: Detect Toolchain

```bash
echo "=== Project Detection ==="
[ -f "package.json" ] && echo "node: $(node -v 2>/dev/null || echo 'not installed')"
[ -f "pnpm-lock.yaml" ] && echo "pkg: pnpm"
[ -f "yarn.lock" ] && echo "pkg: yarn"
[ -f "bun.lockb" ] || [ -f "bun.lock" ] && echo "pkg: bun"
[ -f "package-lock.json" ] && echo "pkg: npm"
[ -f "pyproject.toml" ] && echo "python: $(python3 --version 2>/dev/null || echo 'not installed')"
[ -f "Gemfile" ] && echo "ruby: $(ruby -v 2>/dev/null || echo 'not installed')"
[ -f "go.mod" ] && echo "go: $(go version 2>/dev/null || echo 'not installed')"
[ -f "Cargo.toml" ] && echo "rust: $(rustc --version 2>/dev/null || echo 'not installed')"
[ -f "build.gradle" ] || [ -f "build.gradle.kts" ] && echo "jvm: gradle"
[ -f "pom.xml" ] && echo "jvm: maven"
[ -f "tsconfig.json" ] && echo "typescript: yes"
```

Read `package.json` (if exists) to identify specific tools: eslint, biome, prettier, vitest, jest, mocha, c8, nyc, typescript.

Read `pyproject.toml` (if exists) to identify: ruff, flake8, mypy, pytest, coverage.

Read `Gemfile` (if exists) to identify: rubocop, rspec, minitest, simplecov.

---

## Step 2: Check Existing bin/ Scripts

```bash
ls -la bin/ 2>/dev/null || echo "No bin/ directory"
```

For each of: `lint`, `format`, `test`, `typecheck`, `coverage`:

**If `bin/<name>` exists:**
- Read it
- Run the audit (Step 5)
- If high-signal → skip, report "already good"
- If low-signal → offer to improve

**If `bin/<name>` does not exist:**
- Add to the scaffolding list

If `$ARGUMENTS` is "audit", ONLY audit existing scripts — do not create new ones. Skip to Step 5.

---

## Step 3: Scaffold Missing Scripts

Read the templates reference:

```bash
PLUGIN_DIR=$(find . -path "*/sdlc/scripts/bin-templates.md" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -path "*/sdlc/scripts/bin-templates.md" -exec dirname {} \; 2>/dev/null | head -1)
fi
```

Read `$PLUGIN_DIR/bin-templates.md` for the reference templates.

**For each missing script**, adapt the template to the detected toolchain:

### Package Manager Helper

Every script that uses Node tools needs this at the top:

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

### Script Requirements (NON-NEGOTIABLE)

Every generated script MUST:

1. Start with `#!/usr/bin/env bash` and `set -euo pipefail`
2. Define `strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }`
3. Pipe ALL tool output through `strip_ansi`
4. **NEVER truncate output** with `| head`, `| tail`, or `| grep` — use tool-native flags (e.g., `--max-diagnostics`, `--format unix`) to control verbosity
5. Produce ZERO output on success — exit 0 silently
6. On failure, output ONLY actionable lines: `file:line:message` format
7. Exit non-zero on failure
8. Never print banners, timing, progress, or success confirmations

### What to Generate

| Script | Detect | Tool Flags for Minimal Output |
|--------|--------|-------------------------------|
| `bin/lint` | eslint, biome, ruff, rubocop, go vet, clippy, ktlint | `--format unix`, `--output-format concise`, `--format emacs`, `--message-format short` |
| `bin/format` | prettier, biome, ruff, gofmt, cargo fmt, rubocop Layout | `--list-different`, `--check -l`, `gofmt -l` |
| `bin/test` | vitest, jest, mocha, pytest, rspec, go test, cargo test, gradle test | `--reporter=dot`, `--verbose=false`, `-q --no-header`, `--format progress`, `-count=1` |
| `bin/typecheck` | tsc, mypy, go build | `--pretty false`, `--no-error-summary` |
| `bin/coverage` | vitest, jest, pytest-cov, go test, simplecov | JSON reporters → parse with python3, output `file:pct%` for below-threshold only |

### Present and Confirm

Show the user EACH script before writing it. Group them:

```
## bin/ Scripts to Create

### bin/lint (eslint detected)
<show the script>

### bin/test (vitest detected)
<show the script>

### bin/typecheck (typescript detected)
<show the script>

Create these scripts? [Y/n]
```

After confirmation:

```bash
mkdir -p bin
# Write each script
chmod +x bin/lint bin/format bin/test bin/typecheck bin/coverage
```

Only create scripts for tools that are actually present. Do not create `bin/typecheck` if there's no TypeScript or mypy. Do not create `bin/coverage` if there's no coverage tool.

---

## Step 4: Verify Created Scripts

Run each created script and verify the output matches the high-signal criteria:

```bash
for script in bin/lint bin/format bin/test bin/typecheck bin/coverage; do
  [ -x "$script" ] || continue
  echo "--- $script ---"
  OUTPUT=$($script 2>&1) || true
  HAS_ANSI=$(echo "$OUTPUT" | grep -c $'\x1b\[' || true)
  echo "ANSI codes: $HAS_ANSI"
  [ "$HAS_ANSI" -gt 0 ] && echo "WARNING: contains ANSI escape codes"
done
```

If any script produces noisy output, fix it immediately.

---

## Step 5: Audit Existing Scripts

For each existing `bin/` script (`lint`, `format`, `test`, `typecheck`, `coverage`):

### 5a. Read the script

Understand what it does, what tools it calls, what flags it uses.

### 5b. Run it and capture output

```bash
OUTPUT=$(bin/<name> 2>&1) || true
```

### 5c. Score the output

Check for these LOW-SIGNAL indicators:

| Indicator | Detection | Problem |
|-----------|-----------|---------|
| ANSI codes | `grep -c $'\x1b\['` | Wastes tokens on invisible formatting |
| Banners | `grep -cE '^[=\-\*]{3,}\|^#+\s'` | Decorative noise |
| Progress lines | `grep -cE '(✓\|✗\|PASS\|OK\|\.\.\.)'` on clean runs | Reporting success is noise |
| Timing | `grep -cE '(Done in\|Time:\|[0-9]+\.[0-9]+s$)'` | Not actionable |
| Truncation | `grep -c 'head\|tail'` in script | Silently drops data |
| Missing file refs | Errors without `file:line` format | Not navigable |

### 5d. Report findings

```
## bin/ Script Audit

### bin/lint — LOW SIGNAL
- 12 ANSI escape sequences (tokens wasted on color)
- 3 banner lines ("=== Linting ===")
- Reports 45 passing files (only failures matter)
- No output cap (could produce 500+ lines on large failure)

Suggested fix: Switch to --format unix, add strip_ansi, remove any | head or | tail pipes

### bin/test — HIGH SIGNAL ✓
- No ANSI codes
- Only shows failures
- No output truncation
- file:line references present

### bin/format — MISSING
- Should create: detects prettier in package.json
```

### 5e. Offer to fix low-signal scripts

For each low-signal script, show the specific changes needed and ask:

- **Fix now** — rewrite the script
- **Skip** — leave as-is

---

## Step 6: Quality Config File

Check if `sdlc.config.json` exists at the repo root. If not, create one with the project's defaults:

```json
{
  "thresholds": {
    "max_file_lines": 300,
    "max_function_lines": 50,
    "max_complexity": 8,
    "min_coverage": 95
  },
  "extensions": {}
}
```

The `extensions` field lets repos override thresholds per file type. Baked-in defaults already handle common cases (markdown gets 500 lines, CSS/HTML get 200, shell gets 150, data files like JSON/YAML have no limit). Only add extension overrides if the project needs non-standard values.

Example with overrides:
```json
{
  "thresholds": {
    "max_file_lines": 250,
    "min_coverage": 90
  },
  "extensions": {
    "tsx": { "max_file_lines": 200 },
    "css": { "max_file_lines": 300 }
  }
}
```

Show the user the generated config and confirm before writing.

---

## Step 7: Add to .gitignore Check

Verify `.quality/` is in `.gitignore`:

```bash
grep -q '.quality/' .gitignore 2>/dev/null || echo '.quality/' >> .gitignore
```

---

## Step 8: Add sdlc Section to CLAUDE.md

Check if the project's CLAUDE.md already has an sdlc quality gates section. If not, append one. This ensures sdlc gates survive context compaction and are re-detected in every session.

```bash
CLAUDE_MD="$(git rev-parse --show-toplevel)/CLAUDE.md"
```

**If CLAUDE.md doesn't exist:** Create it with the sdlc section.

**If CLAUDE.md exists but has no sdlc section** (check with `grep -q 'sdlc quality gates\|run-gates\.sh\|PLUGIN_DIR.*sdlc' "$CLAUDE_MD"`): Append the sdlc section.

**If CLAUDE.md already has the sdlc section:** Skip — do not duplicate.

The section to add:

```markdown

## Quality Gates (sdlc)

This project uses sdlc quality gates. Before your first code change in any session, detect the gate scripts:

\`\`\`bash
PLUGIN_DIR=$(find . -path "*/sdlc/scripts/run-gates.sh" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -path "*/sdlc/scripts/run-gates.sh" -exec dirname {} \; 2>/dev/null | head -1)
fi
\`\`\`

Run `bash "$PLUGIN_DIR/run-gates.sh" all` before any commit or push. Gate scripts produce proof artifacts in `.quality/proof/` — use these instead of manual quality checks.
```

---

## Step 9: Commit

Commit all created/modified scripts, config, .gitignore, and CLAUDE.md changes immediately. Do not ask — just commit.

```bash
git add bin/lint bin/format bin/test bin/typecheck bin/coverage sdlc.config.json .gitignore CLAUDE.md 2>/dev/null
git commit -m "$(cat <<'EOF'
chore: bootstrap quality infrastructure (bin/ scripts, sdlc.config.json)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Only stage files that exist and were created/modified.

---

## Step 10: Summary

```
## Bootstrap Complete

Created: bin/lint, bin/test, bin/typecheck
Audited: bin/format (high signal ✓)
Improved: bin/coverage (stripped ANSI, added head cap)
Skipped: bin/typecheck (no TypeScript detected)
CLAUDE.md: sdlc quality gates section added

All bin/ scripts produce LLM-optimized output:
- Failures only with file:line references
- No ANSI, no banners, no progress
- No output truncation (no | head, | tail, | grep)
- Exit code is the signal

Gate scripts (gate-lint.sh, gate-tests.sh, etc.) will now
prefer these bin/ scripts over running tools directly.

The sdlc section in CLAUDE.md ensures gate detection survives
context compaction — every new session will re-detect gates.
```
