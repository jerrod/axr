---
name: performance-audit
description: "Invoke for broad codebase performance investigations: slow apps or APIs, endpoint latency problems, N+1 queries, algorithmic bottlenecks, missing caching, memory inefficiencies, and framework antipatterns. Triggers on \"audit the performance\", \"find bottlenecks\", \"why are our endpoints slow\", \"find N+1 queries\", or \"check for performance antipatterns\". Scans hot paths across any language or framework, produces a prioritized findings report with impact estimates, and walks through fixes interactively. Do NOT use for single targeted fixes, test speed optimization, infrastructure scaling, or general code review."
argument-hint: "[scope] — optional: 'gate-only' to run just the gate, or file/directory path to limit scope"
allowed-tools: Bash(git *), Bash(python3 *), Bash(bash plugins/*), Bash(bin/*), Bash(grep *), Bash(wc *), Bash(find *), Read, Edit, Write, Glob, Grep
---

# Performance Audit

## Audit Trail

Log skill invocation:

Use `$PLUGIN_DIR` (detected in Step 1 via `find . -name "run-gates.sh"`):

- **Start:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log review sdlc:performance-audit started --context "$ARGUMENTS"`
- **End:** `bash "$PLUGIN_DIR/../scripts/audit-trail.sh" log review sdlc:performance-audit completed --context="<summary>"`

## Guiding Principle

**Find real performance problems, not style preferences.** Every finding must describe a concrete performance impact (CPU, memory, I/O, latency) with a specific fix. "Could be slow" is not a finding — "O(n²) nested loop over user list, will degrade at ~1000 users" is.

## Step 1: Discovery

Detect project languages, frameworks, and structure:

```bash
echo "=== Project Detection ==="
[ -f "pyproject.toml" ] && echo "Python project"
[ -f "package.json" ] && echo "Node/JS/TS project"
[ -f "Gemfile" ] && echo "Ruby project"
[ -f "go.mod" ] && echo "Go project"
[ -f "Cargo.toml" ] && echo "Rust project"
[ -f "build.gradle" ] || [ -f "pom.xml" ] && echo "Java/Kotlin project"
```

Use Glob to identify hot paths — files most likely to have performance impact:

```
Glob: **/routes/**
Glob: **/controllers/**
Glob: **/api/**
Glob: **/models/**
Glob: **/services/**
Glob: **/queries/**
Glob: **/middleware/**
```

Build a prioritized file list: data layer first, then services, then controllers, then utilities.

## Step 2: Gate Scan

Run the performance gate script to catch Tier 1 issues:

```bash
PLUGIN_DIR=$(find . -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR=$(find "$HOME/.claude" -name "run-gates.sh" -path "*/sdlc/*" -exec dirname {} \; 2>/dev/null | sort -V | tail -1)
fi
bash "$PLUGIN_DIR/gate-performance.sh"
```

Read the proof file and use gate findings as the initial findings list:

```bash
cat .quality/proof/performance.json
```

## Step 3: Deep Audit

Read files in priority order from Step 1. For each file, check all applicable categories:

### Tier 2 — High Impact
- **Missing caching:** Look for repeated expensive computations, redundant API calls, functions that compute the same result on every call without memoization.
- **Algorithmic complexity:** Look for O(n²) nested loops, repeated linear searches where a set/map/dict would give O(1) lookup, sorting inside loops.
- **Memory issues:** Look for unbounded caches, loading entire files into memory when streaming would work, large object retention beyond its useful lifetime.

### Tier 3 — Medium Impact
- **Concurrency:** Look for serial execution of independent I/O operations, missing connection pooling, thread-unsafe shared state.
- **Frontend/bundle:** Look for barrel file re-exports pulling in entire modules, large synchronous imports that could be lazy/dynamic, missing code splitting.
- **Serialization:** Look for repeated JSON parse/stringify cycles, over-fetching (serializing fields nobody reads), missing response compression.

### Tier 4 — Advisory
- **Data structure choice:** Look for arrays used where Set/Map would be better, string concatenation in loops instead of join/builder, unnecessary object copies.
- **Framework misuse:** Look for missing database indexes on foreign keys, ORM features used incorrectly, framework-provided caching mechanisms being ignored.

**Write findings to `.quality/performance-audit-ledger.md` as you go.** Format:

```markdown
## Finding: [category] — [file:line]

**Severity:** critical|high|medium|advisory
**Impact:** [concrete description of performance impact]
**Current code:** [snippet]
**Suggested fix:** [snippet or description]
```

## Step 4: Report

After scanning all priority files, write `PERFORMANCE-AUDIT.md` to the project root:

- Summary: languages detected, files scanned, finding counts by severity
- Top 5 highest-impact recommendations
- All findings grouped by tier, sorted by severity within each tier
- Each finding: severity, file:line, description, suggested fix, estimated impact

## Step 5: Fix (Interactive)

Walk through findings one at a time with the user:

1. Present the finding: what it is, where it is, why it matters
2. Show the suggested fix
3. Ask: "Fix now, skip, or discuss?"
4. If fix: apply the change, commit with `perf: <description>`
5. After all critical/high fixes: re-run the gate to confirm resolution

```bash
bash "$PLUGIN_DIR/gate-performance.sh"
cat .quality/proof/performance.json
```

## Anti-Laziness Rules

- Do NOT skip files because they "look fine" — read them and check.
- Do NOT get less thorough with later files — context rot is your enemy.
- Do NOT rationalize away findings — if you noticed it, report it.
- Write findings to the ledger AS YOU GO, not from memory at the end.
- Re-read proof files before writing the report.
