#!/usr/bin/env bash
# Orchestrator: Run all quality gates and produce a combined proof report
# Usage: run-gates.sh [phase] [--fix]
#   phase: build|review|ship|all (default: all)
#   --fix: attempt auto-fixes before re-running gates
# Reports each gate result individually via collect-metrics.sh as it completes,
# plus a full summary report at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE="${1:-all}"
FIX_MODE="${2:-}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-.quality/checkpoints}"

# Load shared config (sets PROOF_DIR, SDLC_* variables)
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"
mkdir -p "$CHECKPOINT_DIR"

# Show config source
if [ -n "$SDLC_CONFIG_FILE" ]; then
  echo "Config: $SDLC_CONFIG_FILE"
else
  echo "Config: defaults (no sdlc.config.json found)"
fi
echo ""

# ─── Gate registry ───────────────────────────────────────────────
# Each gate: name|script|phases (csv)
GATES=(
  "filesize|gate-filesize.sh|build,review,ship"
  "complexity|gate-complexity.sh|build,review,ship"
  "dead-code|gate-dead-code.sh|build,review,ship"
  "lint|gate-lint.sh|build,review,ship"
  "plan|gate-plan.sh|ship"
  "tests|gate-tests.sh|build,ship"
  "test-quality|gate-test-quality.sh|build,review,ship"
  "coverage|gate-coverage.sh|ship"
  "review|gate-review.sh|ship"
  "qa|gate-qa.sh|review,ship"
  "design-audit|gate-design-audit.sh|review,ship"
  "performance|gate-performance.sh|perf"
)

# ─── Auto-fix if requested ──────────────────────────────────────
if [ "$FIX_MODE" = "--fix" ]; then
  echo "=== Attempting auto-fixes ==="
  if [ -x "bin/lint" ]; then
    bin/lint --fix 2>&1 || bin/lint 2>&1 || true
  elif [ -f "package.json" ]; then
    if grep -q '"lint:fix"' package.json 2>/dev/null; then npm run lint:fix 2>&1 || true; fi
  fi
  if [ -x "bin/format" ]; then
    bin/format 2>&1 || true
  elif [ -f "package.json" ]; then
    if grep -q '"format"' package.json 2>/dev/null; then npm run format 2>&1 || true; fi
    if grep -q '"prettier"' package.json 2>/dev/null; then npx prettier --write . 2>&1 || true; fi
  fi
  if command -v ruff &>/dev/null; then ruff check --fix . 2>&1 || true; fi
  if command -v ruff &>/dev/null; then ruff format . 2>&1 || true; fi
  if [ -f "Cargo.toml" ]; then cargo fmt 2>&1 || true; fi
  if [ -f "go.mod" ]; then gofmt -w . 2>&1 || true; fi
  echo "=== Auto-fix complete ==="

  # Commit auto-fix results if anything changed, then continue to run gates
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -u
    git commit -m "style: auto-fix formatting and lint issues"
    echo "Auto-fix changes committed."
  else
    echo "No changes needed."
  fi
  echo ""
fi

# ─── Dirty tree rejection ───────────────────────────────────────
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "✗ Uncommitted changes detected. Commit all changes before running gates."
  exit 1
fi

# ─── Cache helpers ──────────────────────────────────────────────
CURRENT_SHA="$(git rev-parse HEAD)"

_gate_patterns() {
  case "$1" in
    filesize | complexity) echo '*' ;;
    dead-code) echo '*.rb *.py *.ts *.tsx *.js *.jsx *.go *.rs *.kt *.java *.sh' ;;
    lint) echo '*.rb *.py *.ts *.tsx *.js *.jsx *.go *.rs *.kt *.java *.sh *.bash *.json *.yml *.yaml .rubocop* .eslint* pyproject.toml build.gradle* *.kts' ;;
    tests) echo '*.rb *.py *.ts *.tsx *.js *.jsx *.go *.rs *.kt *.java *.sh test/* tests/* spec/* __tests__/* *.test.* *_test.* *Test.kt *Test.java fixtures/*' ;;
    test-quality) echo 'test/* tests/* spec/* __tests__/* *.test.* *_test.* *Test.kt *Test.java test_*.sh' ;;
    coverage) echo '*.rb *.py *.ts *.tsx *.js *.jsx *.go *.rs *.kt *.java test/* tests/* spec/*' ;;
    plan) echo 'sdlc.config.json' ;;
    review) echo '.quality/proof/review-coverage.json' ;;
    qa) echo '*.erb *.html *.css *.scss *.vue *.svelte app/views/* app/javascript/*' ;;
    design-audit) echo '*.erb *.html *.css *.scss *.vue *.svelte app/views/* app/javascript/* app/helpers/*' ;;
    performance) echo '*.rb *.py *.ts *.tsx *.js *.jsx *.go *.rs *.kt *.java' ;;
    *) echo '*' ;;
  esac
}

# Check if files matching gate's patterns changed since proof SHA. Returns 0 if changed (cache invalid), 1 if not.
_files_changed_for_gate() {
  local gate_name="$1" proof_sha="$2"
  local patterns
  patterns="$(_gate_patterns "$gate_name")"

  [ "$proof_sha" = "$CURRENT_SHA" ] && return 1

  local changed_files
  changed_files="$(git diff --name-only "$proof_sha" "$CURRENT_SHA" 2>/dev/null)" || return 0

  if [ "$patterns" = "*" ]; then
    [ -n "$changed_files" ] && return 0 || return 1
  fi

  local pattern
  for pattern in $patterns; do
    while IFS= read -r file; do
      # shellcheck disable=SC2254
      case "$file" in
        $pattern) return 0 ;; # relevant file changed → cache invalid
      esac
    done <<<"$changed_files"
  done

  return 1 # no relevant files changed → cache still valid
}

# Returns 0 if proof file shows pass and no relevant files changed since
_gate_cached() {
  local name="$1"
  local proof_file="$PROOF_DIR/$name.json"
  [ -f "$proof_file" ] || proof_file="$PROOF_DIR/${name//-/_}.json"
  [ -f "$proof_file" ] || return 1

  local proof_status proof_sha
  read -r proof_status proof_sha < <(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('status',''), d.get('sha',''))" "$proof_file" 2>/dev/null || echo "")
  [ "$proof_status" = "pass" ] || [ "$proof_status" = "skip" ] || return 1

  # Exact SHA match → definitely cached
  [ "$proof_sha" = "$CURRENT_SHA" ] && return 0

  # Content-addressed: check if files relevant to this gate changed
  if _files_changed_for_gate "$name" "$proof_sha"; then
    return 1 # relevant files changed → must re-run
  fi

  return 0 # no relevant files changed → cache is valid
}

# Check if all gates for this phase already passed at current SHA
ALL_CACHED=true
CACHED_NAMES=()
for gate_entry in "${GATES[@]}"; do
  IFS='|' read -r name script phases <<<"$gate_entry"
  if [ "$PHASE" = "all" ]; then
    echo "$phases" | grep -qE '(^|,)(build|review|ship)(,|$)' || continue
  else
    echo "$phases" | grep -qE "(^|,)$PHASE(,|$)" || continue
  fi
  if ! _gate_cached "$name"; then
    ALL_CACHED=false
    break
  fi
  CACHED_NAMES+=("$name")
done

if [ "$ALL_CACHED" = true ]; then
  echo "✓ All gates cached — no relevant files changed"
  for cached_name in "${CACHED_NAMES[@]}"; do
    proof_file="$PROOF_DIR/$cached_name.json"
    [ -f "$proof_file" ] || proof_file="$PROOF_DIR/${cached_name//-/_}.json"
    echo "  ✓ $cached_name (proof @ $(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('sha','?')[:7])" "$proof_file" 2>/dev/null || echo '?'))"
  done
  exit 0
fi

# Clear allow-list tracking at phase start so only gates run this phase contribute entries
rm -f "$PROOF_DIR"/allow-tracking-*.jsonl 2>/dev/null || true

# ─── Run gates ───────────────────────────────────────────────────
PASSED=0
FAILED=0
SKIPPED=0
GATE_RESULTS=()

for gate_entry in "${GATES[@]}"; do
  IFS='|' read -r name script phases <<<"$gate_entry"

  # Filter by phase
  if [ "$PHASE" = "all" ]; then
    # "all" runs gates in build/review/ship phases, not opt-in phases like perf
    if ! echo "$phases" | grep -qE '(^|,)(build|review|ship)(,|$)'; then
      continue
    fi
  else
    if ! echo "$phases" | grep -qE "(^|,)$PHASE(,|$)"; then
      continue
    fi
  fi

  # Check cache: skip if proof exists with pass/skip status and no relevant files changed
  if _gate_cached "$name"; then
    # Detect cached skip vs cached pass (use same dash-to-underscore fallback as _gate_cached)
    cached_proof="$PROOF_DIR/$name.json"
    [ -f "$cached_proof" ] || cached_proof="$PROOF_DIR/${name//-/_}.json"
    cached_status=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','pass'))" "$cached_proof" 2>/dev/null || echo "pass")
    if [ "$cached_status" = "skip" ]; then
      SKIPPED=$((SKIPPED + 1))
      GATE_RESULTS+=("{\"gate\":\"$name\",\"status\":\"skip\",\"cached\":true}")
      echo "~ $name: skip (cached)"
    else
      PASSED=$((PASSED + 1))
      GATE_RESULTS+=("{\"gate\":\"$name\",\"status\":\"pass\",\"cached\":true}")
      echo "✓ $name: pass (cached)"
    fi
    echo ""
    continue
  fi

  echo "━━━ Gate: $name ━━━"
  EXIT_CODE=0
  bash "$SCRIPT_DIR/$script" || EXIT_CODE=$?

  # Determine status: check proof file for skip, then fall back to exit code
  STATUS=""
  PROOF_FILE="$PROOF_DIR/$name.json"
  [ -f "$PROOF_FILE" ] || PROOF_FILE="$PROOF_DIR/${name//-/_}.json"

  if [ -f "$PROOF_FILE" ] && grep -qE '"status"\s*:\s*"skip"' "$PROOF_FILE" 2>/dev/null; then
    STATUS="skip"
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASON=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('reason',''))" "$PROOF_FILE" 2>/dev/null || echo "")
    echo "~ $name: skipped${SKIP_REASON:+ ($SKIP_REASON)}"
  elif [ $EXIT_CODE -eq 0 ]; then
    STATUS="pass"
    PASSED=$((PASSED + 1))
    echo "✓ $name: PASSED"
  else
    STATUS="fail"
    FAILED=$((FAILED + 1))
    echo "✗ $name: FAILED"
  fi

  GATE_RESULTS+=("{\"gate\":\"$name\",\"status\":\"$STATUS\"}")

  # Report this gate's result immediately
  if [ -x "$SCRIPT_DIR/collect-metrics.sh" ]; then
    bash "$SCRIPT_DIR/collect-metrics.sh" "$PHASE" --gate "$name" 2>/dev/null || true
  fi

  echo ""
done

# ─── Write checkpoint ────────────────────────────────────────────
CHECKPOINT_FILE="$CHECKPOINT_DIR/${PHASE}-$(date -u +%Y%m%d-%H%M%S).json"
RESULTS_JSON=""
[ ${#GATE_RESULTS[@]} -gt 0 ] && RESULTS_JSON=$(printf '%s,' "${GATE_RESULTS[@]}" | sed 's/,$//')
# JSON-escape git branch so refs containing " or \ cannot corrupt proof
BRANCH_JSON=$(BR="$(git branch --show-current 2>/dev/null || echo 'unknown')" python3 -c "import json,os;print(json.dumps(os.environ['BR']))")

cat >"$CHECKPOINT_FILE" <<ENDJSON
{
  "phase": "$PHASE",
  "passed": $PASSED,
  "failed": $FAILED,
  "skipped": $SKIPPED,
  "gates": [${RESULTS_JSON}],
  "git_sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "git_branch": $BRANCH_JSON,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

# Also write as latest for this phase
cp "$CHECKPOINT_FILE" "$CHECKPOINT_DIR/${PHASE}-latest.json"

# ─── Summary ─────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase: $PHASE"
echo "  Passed: $PASSED  Failed: $FAILED"
echo "  Checkpoint: $CHECKPOINT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Collect metrics (non-fatal) — runs on pass AND fail, must not alter exit code ─
if [ -x "$SCRIPT_DIR/collect-metrics.sh" ]; then
  bash "$SCRIPT_DIR/collect-metrics.sh" "$PHASE" 2>/dev/null || true
fi

if [ $FAILED -gt 0 ]; then
  echo ""
  echo "PIPELINE FAILED — $FAILED gate(s) did not pass"
  exit 1
fi

echo ""
echo "ALL GATES PASSED"
exit 0
