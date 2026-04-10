#!/usr/bin/env bash
# Collect all gate proof artifacts into a PR-ready markdown report
# Usage: collect-proof.sh [--format=markdown|json]
# Produces: .quality/proof/PROOF.md
set -euo pipefail

PROOF_DIR="${PROOF_DIR:-.quality/proof}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-.quality/checkpoints}"
OUTPUT="$PROOF_DIR/PROOF.md"

mkdir -p "$PROOF_DIR"

# ─── Collect branch SHAs for checkpoint filtering ──────────────
# Only include checkpoints whose git_sha appears in the current
# branch's commit range. On default branch (0 commits ahead),
# include all checkpoints as a fallback.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")}"
BRANCH_SHAS=$(git log --format=%H "origin/$DEFAULT_BRANCH"..HEAD 2>/dev/null || true)
if [ -n "$BRANCH_SHAS" ]; then
  BRANCH_SHA_FILE=$(mktemp)
  trap '[ -n "${BRANCH_SHA_FILE:-}" ] && rm -f "$BRANCH_SHA_FILE"' EXIT
  echo "$BRANCH_SHAS" >"$BRANCH_SHA_FILE"
  FILTER_CHECKPOINTS=true
else
  BRANCH_SHA_FILE=""
  FILTER_CHECKPOINTS=false
fi

# ─── Gather all proof files ─────────────────────────────────────
PROOF_FILES=$(find "$PROOF_DIR" -name "*.json" -type f 2>/dev/null | sort)
CHECKPOINT_FILES=$(find "$CHECKPOINT_DIR" -name "*-latest.json" -type f 2>/dev/null | sort)

if [ -z "$PROOF_FILES" ] && [ -z "$CHECKPOINT_FILES" ]; then
  echo "No proof artifacts found. Run gates first: run-gates.sh"
  exit 1
fi

# ─── Build markdown report ──────────────────────────────────────
cat >"$OUTPUT" <<'HEADER'
## Quality Proof Report

> Every gate below was **executed by script**, not estimated by the model.
> Proof artifacts are in `.quality/proof/`. Verify any claim by re-running:
> `bash plugins/sdlc/scripts/run-gates.sh all`

HEADER

# Plan and review gate summary (rendered above the checkpoint table so GitHub
# markdown does not interleave bold text between the table header and rows)
{
  echo "### Pipeline Summary"
  echo ""
  PROOF_DIR="$PROOF_DIR" python3 -c "
import json, pathlib, os, re

# Escape markdown metacharacters so values pulled from proof JSON (e.g.,
# branch names, error strings) cannot inject links, headings, or tables
# into PROOF.md.
def esc(s):
    return re.sub(r'([\\\\\`*_{}\\[\\]()#+!|<>])', r'\\\\\1', str(s))

pd = pathlib.Path(os.environ['PROOF_DIR'])
for gate, fname in [('Plan', 'plan.json'), ('Review', 'review.json')]:
    p = pd / fname
    if not p.exists(): continue
    d = json.load(open(p))
    s, b = d.get('status', '?'), d.get('bypassed_via')
    if gate == 'Plan':
        pr = d.get('plan_required', False)
        if s == 'pass': print('**Plan gate:** enabled (pass)')
        elif not pr: print('**Plan gate:** disabled')
        elif b: print(f'**Plan gate:** bypassed ({esc(b)})')
        else: print(f'**Plan gate:** {esc(s)}')
    else:
        if s == 'pass': print('**Review gate:** passed')
        elif b: print(f'**Review gate:** bypassed ({esc(b)})')
        elif s == 'skip': print(f'**Review gate:** skipped ({esc(d.get(\"reason\", \"\"))})')
        elif s == 'fail': print(f'**Review gate:** ❌ failed ({esc(d.get(\"error\", \"\"))})')
        else: print(f'**Review gate:** {esc(s)}')
" 2>/dev/null || true
  echo ""
  echo "| Phase | Passed | Failed | Skipped | SHA | Time |"
  echo "|-------|--------|--------|---------|-----|------|"
} >>"$OUTPUT"

if [ -n "$CHECKPOINT_FILES" ]; then
  while IFS= read -r cp; do
    if [ "$FILTER_CHECKPOINTS" = "true" ]; then
      cp_sha=$(CP_FILE="$cp" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha',''))" 2>/dev/null || echo "")
      [ -z "$cp_sha" ] && continue
      grep -qF "$cp_sha" "$BRANCH_SHA_FILE" 2>/dev/null || continue
    fi
    CP_FILE="$cp" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
phase = d.get('phase', '?')
passed = d.get('passed', 0)
failed = d.get('failed', 0)
skip = d.get('skipped', 0)
sha = d.get('git_sha', '?')
ts = d.get('timestamp', '?')
print(f'| {phase} | {passed} | {failed} | {skip} | \`{sha}\` | {ts} |')
" >>"$OUTPUT" 2>/dev/null || echo "| ? | ? | ? | ? | ? | ? |" >>"$OUTPUT"
  done <<<"$CHECKPOINT_FILES"
fi

# Demo recordings
recordings=()
if [[ -d "$PROOF_DIR/recordings" ]]; then
  while IFS= read -r -d '' gif; do
    recordings+=("$gif")
  done < <(find "$PROOF_DIR/recordings" -name "*.gif" -print0 2>/dev/null | sort -z)
fi

if [[ ${#recordings[@]} -gt 0 ]]; then
  {
    echo ""
    echo "## Demo"
    echo ""
    for gif in "${recordings[@]}"; do
      name=$(basename "$gif" .gif)
      echo "![${name}](${gif})"
      echo ""
    done
  } >>"$OUTPUT"
fi

# Design audit grades
if [[ -f "$PROOF_DIR/design-audit.json" ]]; then
  da_status=$(DA_FILE="$PROOF_DIR/design-audit.json" python3 -c "import json, os; print(json.load(open(os.environ['DA_FILE'])).get('status',''))" 2>/dev/null || echo "")
  if [[ "$da_status" == "pass" || "$da_status" == "fail" ]]; then
    {
      echo ""
      echo "## Design Audit"
      echo ""
      echo "| Category | Grade | Notes |"
      echo "|---|---|---|"
      DA_FILE="$PROOF_DIR/design-audit.json" python3 -c "
import json, os, re
def esc(s):
    return re.sub(r'([\\\\\`*_{}\\[\\]()#+!|<>])', r'\\\\\1', str(s))
data = json.load(open(os.environ['DA_FILE']))
cats = data.get('categories', {})
for name, info in cats.items():
    grade = info.get('grade', '?')
    items = info.get('items', [])
    issues = [i for i in items if i.get('score', 1.0) < 1.0]
    note = '; '.join(i.get('note','') for i in issues[:2] if i.get('note'))
    print(f'| {esc(name.title())} | {esc(grade)} | {esc(note)} |')
"
    } >>"$OUTPUT"
    overall=$(DA_FILE="$PROOF_DIR/design-audit.json" python3 -c "import json, os; print(json.load(open(os.environ['DA_FILE'])).get('overall_grade',''))" 2>/dev/null || echo "")
    {
      echo ""
      echo "**Overall: ${overall}**"
    } >>"$OUTPUT"

    # Screenshots in collapsible
    screenshots=()
    if [[ -d "$PROOF_DIR/screenshots" ]]; then
      while IFS= read -r -d '' png; do
        screenshots+=("$png")
      done < <(find "$PROOF_DIR/screenshots" -name "*.png" -print0 2>/dev/null | sort -z)
    fi
    if [[ ${#screenshots[@]} -gt 0 ]]; then
      {
        echo ""
        echo "<details><summary>Screenshots</summary>"
        echo ""
        for png in "${screenshots[@]}"; do
          name=$(basename "$png" .png)
          echo "![${name}](${png})"
          echo ""
        done
        echo "</details>"
      } >>"$OUTPUT"
    fi
  fi
fi

{
  echo ""
  echo "### Gate Details"
  echo ""
} >>"$OUTPUT"

if [ -n "$PROOF_FILES" ]; then
  while IFS= read -r pf; do
    GATE=$(PF_FILE="$pf" python3 -c "import json, os; d=json.load(open(os.environ['PF_FILE'])); print(d.get('gate','unknown'))" 2>/dev/null) || continue
    STATUS=$(PF_FILE="$pf" python3 -c "import json, os; d=json.load(open(os.environ['PF_FILE'])); print(d.get('status','?'))" 2>/dev/null || echo "?")

    ICON="✅"
    [ "$STATUS" = "fail" ] && ICON="❌"
    [ "$STATUS" = "skip" ] && ICON="⏭️"

    if [ "$GATE" = "ci-fix" ]; then
      {
        echo "<details>"
        echo "<summary>$ICON <strong>ci-fix</strong> — $STATUS</summary>"
        echo ""
        echo "| Check | Tier | Fix Applied | Result |"
        echo "|-------|------|-------------|--------|"
        PF_FILE="$pf" python3 -c "
import json, os
data = json.load(open(os.environ['PF_FILE']))
for it in data.get('iterations', []):
    check = it.get('check', '')
    tier = it.get('tier', '')
    fix = it.get('fix_applied', '').replace('|', '\\\\|')
    result = it.get('result', '')
    print(f'| {check} | {tier} | {fix} | {result} |')
"
        echo ""
        echo "</details>"
        echo ""
      } >>"$OUTPUT"
      continue
    fi

    {
      echo "<details>"
      echo "<summary>$ICON <strong>$GATE</strong> — $STATUS</summary>"
      echo ""
      echo '```json'
      PF_FILE="$pf" python3 -c "import json, os; print(json.dumps(json.load(open(os.environ['PF_FILE'])), indent=2))" 2>/dev/null || cat "$pf"
      echo '```'
      echo ""
      echo "</details>"
      echo ""
    } >>"$OUTPUT"
  done <<<"$PROOF_FILES"
fi

# ─── Checkpoint history ──────────────────────────────────────────
ALL_CHECKPOINTS=$(find "$CHECKPOINT_DIR" -name "*.json" -type f ! -name "*-latest.json" 2>/dev/null | sort)
if [ -n "$ALL_CHECKPOINTS" ]; then
  {
    echo "### Checkpoint History"
    echo ""
    echo "Each checkpoint proves gates were run at a specific commit:"
    echo ""
    echo "| Time | Phase | SHA | Pass | Fail |"
    echo "|------|-------|-----|------|------|"
  } >>"$OUTPUT"
  while IFS= read -r cp; do
    if [ "$FILTER_CHECKPOINTS" = "true" ]; then
      cp_sha=$(CP_FILE="$cp" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha',''))" 2>/dev/null || echo "")
      [ -z "$cp_sha" ] && continue
      grep -qF "$cp_sha" "$BRANCH_SHA_FILE" 2>/dev/null || continue
    fi
    CP_FILE="$cp" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
print(f\"| {d.get('timestamp','?')} | {d.get('phase','?')} | \`{d.get('git_sha','?')}\` | {d.get('passed',0)} | {d.get('failed',0)} |\")" >>"$OUTPUT" 2>/dev/null || true
  done <<<"$ALL_CHECKPOINTS"
  echo "" >>"$OUTPUT"
fi

# ─── Audit trail ─────────────────────────────────────────────────
AUDIT_DIR="${AUDIT_DIR:-.quality/audit}"
SCRIPT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$AUDIT_DIR/trail.json" ] || [ -f "$AUDIT_DIR/execution-plan.json" ]; then
  AUDIT_REPORT=$(bash "$SCRIPT_DIR_SELF/audit-trail.sh" report 2>/dev/null || true)
  if [ -n "$AUDIT_REPORT" ]; then
    {
      echo ""
      echo "$AUDIT_REPORT"
    } >>"$OUTPUT"
  fi
fi

# ─── Active + Stale Exceptions ───────────────────────────────────
# Renders exceptions that were active during gate runs, plus any entries
# that were consulted but matched no files (likely stale).
PROOF_DIR="$PROOF_DIR" SDLC_CONFIG_FILE="${SDLC_CONFIG_FILE:-}" \
  python3 "$SCRIPT_DIR_SELF/render_exceptions.py" >>"$OUTPUT" 2>/dev/null || true

# ─── Anti-rot verification ───────────────────────────────────────
{
  echo "### Verification"
  echo ""
  echo "To independently verify these results:"
  echo '```bash'
  echo "# Re-run all gates from scratch"
  echo "rm -rf .quality/proof .quality/checkpoints"
  echo "bash plugins/sdlc/scripts/run-gates.sh all"
  echo "bash plugins/sdlc/scripts/collect-proof.sh"
  echo "cat .quality/proof/PROOF.md"
  echo '```'
} >>"$OUTPUT"

echo ""
echo "Proof report written to: $OUTPUT"
echo ""
cat "$OUTPUT"
