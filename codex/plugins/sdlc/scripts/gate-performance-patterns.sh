#!/usr/bin/env bash
# Language-specific performance patterns — sourced by gate-performance.sh
# Expects: LANG_PY, LANG_JS, LANG_TS, LANG_RB, LANG_GO, LANG_JAVA, CHANGED_FILES, add_finding(), is_allowed()
# Matches go through is_allowed "performance" (shared with gate-performance.sh),
# so tracking + report + hint all live in that gate's hooks — none needed here.

# ─── Python patterns ──────────────────────────────────────────────
if [ "${LANG_PY:-false}" = "true" ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" == *.py ]] || continue

    # N+1 query: for var in queryset followed by var.related.field
    N_PLUS_ONE_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
for_pattern = re.compile(r'^\s*for\s+(\w+)\s+in\s+(\w+)')
rel_pattern = re.compile(r'\b(\w+)\.([\w]+)\.([\w]+)')
has_prefetch = re.compile(r'select_related|prefetch_related')
file_text = ''.join(lines)
if has_prefetch.search(file_text):
    sys.exit(0)
loop_vars = {}
for i, line in enumerate(lines, 1):
    m = for_pattern.match(line)
    if m:
        loop_vars[m.group(1)] = i
    rm = rel_pattern.search(line)
    if rm and rm.group(1) in loop_vars:
        print(i)
" "$file" 2>/dev/null || true)

    if [ -n "$N_PLUS_ONE_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=n-plus-one-query" && continue
        add_finding "critical" "$file" "$lineno" "n-plus-one-query" "N+1 query: loop over queryset without select_related/prefetch_related"
      done <<<"$N_PLUS_ONE_LINES"
    fi

    # Sync HTTP in async: requests.* inside async def
    SYNC_IN_ASYNC_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
async_depth = 0
async_pattern = re.compile(r'^\s*async\s+def\s+')
sync_http_pattern = re.compile(r'\brequests\.(get|post|put|patch|delete|head|options|request)\s*\(')
indent_stack = []
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    if async_pattern.match(line):
        async_depth += 1
        indent_stack.append(indent)
    elif indent_stack and indent <= indent_stack[-1] and stripped and not stripped.startswith('#'):
        if not async_pattern.match(line) and not line.strip().startswith('def '):
            pass
        else:
            async_depth -= 1
            indent_stack.pop()
    if async_depth > 0 and sync_http_pattern.search(line):
        print(i)
" "$file" 2>/dev/null || true)

    if [ -n "$SYNC_IN_ASYNC_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=sync-in-async" && continue
        add_finding "critical" "$file" "$lineno" "sync-in-async" "Sync HTTP call (requests.*) inside async def — use httpx or aiohttp"
      done <<<"$SYNC_IN_ASYNC_LINES"
    fi

    # Unbounded queryset: .objects.all() without slicing
    UNBOUNDED_QS_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
pattern = re.compile(r'\.objects\.all\(\)')
slice_pattern = re.compile(r'\.objects\.all\(\)\s*\[')
for i, line in enumerate(lines, 1):
    if pattern.search(line) and not slice_pattern.search(line):
        print(i)
" "$file" 2>/dev/null || true)

    if [ -n "$UNBOUNDED_QS_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=unbounded-queryset" && continue
        add_finding "high" "$file" "$lineno" "unbounded-queryset" "Unbounded queryset: .objects.all() without slicing — may load entire table"
      done <<<"$UNBOUNDED_QS_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi

# ─── JavaScript/TypeScript patterns ───────────────────────────────
_LANG_JSLIKE=false
[ "${LANG_JS:-false}" = "true" ] && _LANG_JSLIKE=true
[ "${LANG_TS:-false}" = "true" ] && _LANG_JSLIKE=true

if [ "$_LANG_JSLIKE" = "true" ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" == *.js || "$file" == *.jsx || "$file" == *.ts || "$file" == *.tsx ]] || continue

    # Serial await in loop
    SERIAL_AWAIT_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
loop_depth = 0
loop_pattern = re.compile(r'^\s*(for\s*[\(\s]|while\s*\(|for\s+\w+\s+of\s+|for\s+\w+\s+in\s+)')
await_pattern = re.compile(r'\bawait\b')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if loop_pattern.match(line):
        loop_depth += 1
    if loop_depth > 0 and await_pattern.search(line) and not stripped.startswith('//'):
        print(i)
    if stripped == '}' or stripped == '};':
        if loop_depth > 0:
            loop_depth -= 1
" "$file" 2>/dev/null || true)

    if [ -n "$SERIAL_AWAIT_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=serial-await-in-loop" && continue
        add_finding "critical" "$file" "$lineno" "serial-await-in-loop" "Serial await in loop — use Promise.all() to parallelize"
      done <<<"$SERIAL_AWAIT_LINES"
    fi

    # Sync fs calls
    SYNC_FS_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
pattern = re.compile(r'\bfs\.(readFileSync|writeFileSync|appendFileSync|readdirSync|existsSync|mkdirSync|unlinkSync|statSync|copyFileSync)\s*\(')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if stripped.startswith('//') or stripped.startswith('*'):
        continue
    if pattern.search(line):
        print(i)
" "$file" 2>/dev/null || true)

    if [ -n "$SYNC_FS_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=sync-fs" && continue
        add_finding "high" "$file" "$lineno" "sync-fs" "Synchronous fs call blocks the event loop — use async fs methods"
      done <<<"$SYNC_FS_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi

# ─── Ruby patterns ────────────────────────────────────────────────
if [ "${LANG_RB:-false}" = "true" ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" == *.rb ]] || continue

    # N+1 in .each: nested .where/.find_by inside .each
    N_PLUS_ONE_RB_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
each_depth = 0
each_pattern = re.compile(r'\.(each|map|select|reject|find_each)\s*(do|\{)')
query_pattern = re.compile(r'\.(where|find_by|find|includes|joins|eager_load)\s*[\(\{]')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if each_pattern.search(line):
        each_depth += 1
    if each_depth > 0 and query_pattern.search(line):
        print(i)
    if stripped in ('end', '}') or stripped.startswith('end '):
        if each_depth > 0:
            each_depth -= 1
" "$file" 2>/dev/null || true)

    if [ -n "$N_PLUS_ONE_RB_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=n-plus-one-query" && continue
        add_finding "critical" "$file" "$lineno" "n-plus-one-query" "N+1 query: DB query inside .each loop — use includes/eager_load"
      done <<<"$N_PLUS_ONE_RB_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi

# ─── Go patterns ──────────────────────────────────────────────────
if [ "${LANG_GO:-false}" = "true" ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" == *.go ]] || continue

    # Query in loop
    QUERY_IN_LOOP_GO_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
loop_depth = 0
loop_pattern = re.compile(r'^\s*for\s+')
query_pattern = re.compile(r'\.(Query|QueryRow|QueryContext|QueryRowContext|Exec|ExecContext)\s*\(')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if loop_pattern.match(line):
        loop_depth += 1
    if loop_depth > 0 and query_pattern.search(line):
        print(i)
    if stripped == '}':
        if loop_depth > 0:
            loop_depth -= 1
" "$file" 2>/dev/null || true)

    if [ -n "$QUERY_IN_LOOP_GO_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=query-in-loop" && continue
        add_finding "critical" "$file" "$lineno" "query-in-loop" "DB query inside for loop — batch queries or use IN clause"
      done <<<"$QUERY_IN_LOOP_GO_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi

# ─── Java/Kotlin patterns ─────────────────────────────────────────
if [ "${LANG_JAVA:-false}" = "true" ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" == *.java || "$file" == *.kt ]] || continue

    # String concat in loop
    STRING_CONCAT_JAVA_LINES=$(python3 -c "
import re, sys
filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()
loop_depth = 0
loop_pattern = re.compile(r'^\s*(for\s*\(|while\s*\(|do\s*\{)')
concat_pattern = re.compile(r'\b\w+\s*\+=\s*[\"\\']|\bString\s+\w+\s*\+=')
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if loop_pattern.match(line):
        loop_depth += 1
    if loop_depth > 0 and concat_pattern.search(line):
        print(i)
    if stripped == '}' or stripped == '};':
        if loop_depth > 0:
            loop_depth -= 1
" "$file" 2>/dev/null || true)

    if [ -n "$STRING_CONCAT_JAVA_LINES" ]; then
      while IFS= read -r lineno; do
        is_allowed "performance" "file=$file" "pattern=string-concat-in-loop" && continue
        add_finding "high" "$file" "$lineno" "string-concat-in-loop" "String concatenation in loop — use StringBuilder or joinToString()"
      done <<<"$STRING_CONCAT_JAVA_LINES"
    fi

  done <<<"$CHANGED_FILES"
fi
