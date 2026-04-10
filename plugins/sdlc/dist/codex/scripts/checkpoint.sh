#!/usr/bin/env bash
# Checkpoint: Save or verify quality state at a point in time
# This is the core anti-context-rot mechanism.
#
# Claude's context window is ephemeral. This script persists proof to disk
# so that quality claims survive context compression, session restarts,
# and long conversations where Claude "forgets" what was already verified.
#
# Usage:
#   checkpoint.sh save <phase> <message>  — Record current state
#   checkpoint.sh verify <phase>          — Check if gates passed since last code change
#   checkpoint.sh history                 — Show all checkpoints
#   checkpoint.sh drift                   — Detect if code changed since last checkpoint
set -euo pipefail

CHECKPOINT_DIR="${CHECKPOINT_DIR:-.quality/checkpoints}"
PROOF_DIR="${PROOF_DIR:-.quality/proof}"
mkdir -p "$CHECKPOINT_DIR" "$PROOF_DIR"

ACTION="${1:-help}"
PHASE="${2:-}"
MESSAGE="${3:-}"

case "$ACTION" in

  save)
    [ -z "$PHASE" ] && {
      echo "Usage: checkpoint.sh save <phase> [message]"
      exit 1
    }

    SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    FILE_HASH=$(git diff --stat HEAD 2>/dev/null | md5sum | cut -d' ' -f1)

    # Snapshot current proof files
    PROOF_SNAPSHOT="[]"
    if ls "$PROOF_DIR"/*.json &>/dev/null; then
      PROOF_SNAPSHOT=$(CP_PROOF_DIR="$PROOF_DIR" python3 -c "
import json, glob, os
proofs = []
for f in sorted(glob.glob(os.path.join(os.environ['CP_PROOF_DIR'], '*.json'))):
    try:
        with open(f) as fh:
            d = json.load(fh)
            proofs.append({'gate': d.get('gate','?'), 'status': d.get('status','?'), 'file': os.path.basename(f)})
    except: pass
print(json.dumps(proofs))
" 2>/dev/null || echo "[]")
    fi

    ESCAPED_MSG=$(echo "$MESSAGE" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')

    CHECKPOINT_FILE="$CHECKPOINT_DIR/${PHASE}-$(date -u +%Y%m%d-%H%M%S)-${SHA}.json"

    cat >"$CHECKPOINT_FILE" <<ENDJSON
{
  "action": "save",
  "phase": "$PHASE",
  "message": $ESCAPED_MSG,
  "git_sha": "$SHA",
  "git_branch": "$BRANCH",
  "uncommitted_files": $DIRTY,
  "working_tree_hash": "$FILE_HASH",
  "proof_snapshot": $PROOF_SNAPSHOT,
  "timestamp": "$TIMESTAMP"
}
ENDJSON

    cp "$CHECKPOINT_FILE" "$CHECKPOINT_DIR/${PHASE}-latest.json"
    echo "Checkpoint saved: $CHECKPOINT_FILE"
    echo "  Phase: $PHASE | SHA: $SHA | Dirty: $DIRTY files"
    ;;

  verify)
    [ -z "$PHASE" ] && {
      echo "Usage: checkpoint.sh verify <phase>"
      exit 1
    }

    LATEST="$CHECKPOINT_DIR/${PHASE}-latest.json"
    if [ ! -f "$LATEST" ]; then
      echo "NO CHECKPOINT for phase '$PHASE' — gates have never been run"
      echo "Run: bash plugins/sdlc/scripts/run-gates.sh $PHASE"
      exit 1
    fi

    SAVED_SHA=$(CP_FILE="$LATEST" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha','?'))" 2>/dev/null)
    CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    # Normalize saved SHA to full length — checkpoints may store short or full SHAs
    SAVED_SHA_FULL=$(git rev-parse "$SAVED_SHA" 2>/dev/null || echo "$SAVED_SHA")
    SAVED_DIRTY=$(CP_FILE="$LATEST" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('uncommitted_files',0))" 2>/dev/null)
    CURRENT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    PROOFS=$(CP_FILE="$LATEST" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
for p in d.get('proof_snapshot', []):
    print(f\"  {p['gate']}: {p['status']}\")
" 2>/dev/null || echo "  (no proof data)")

    echo "Checkpoint verification for phase: $PHASE"
    echo "  Saved at:    SHA ${SAVED_SHA_FULL:0:7} (dirty: $SAVED_DIRTY)"
    echo "  Current:     SHA ${CURRENT_SHA:0:7} (dirty: $CURRENT_DIRTY)"
    echo "  Gate results:"
    echo "$PROOFS"

    if [ "$SAVED_SHA_FULL" != "$CURRENT_SHA" ] || [ "$CURRENT_DIRTY" -gt "$SAVED_DIRTY" ]; then
      echo ""
      echo "⚠ CODE HAS CHANGED since checkpoint — re-run gates"
      echo "Run: bash plugins/sdlc/scripts/run-gates.sh $PHASE"
      exit 1
    fi

    # Check all proofs passed
    FAILED=$(CP_FILE="$LATEST" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
failed = [p['gate'] for p in d.get('proof_snapshot', []) if p['status'] == 'fail']
print(' '.join(failed))
" 2>/dev/null || echo "")

    if [ -n "$FAILED" ]; then
      echo ""
      echo "CHECKPOINT INVALID: These gates failed: $FAILED"
      exit 1
    fi

    echo ""
    echo "✓ Checkpoint valid — no drift detected"
    ;;

  drift)
    echo "Drift detection — checking all phases:"
    echo ""
    CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    CURRENT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    HAS_DRIFT=0

    for latest in "$CHECKPOINT_DIR"/*-latest.json; do
      [ -f "$latest" ] || continue
      PHASE_NAME=$(CP_FILE="$latest" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('phase','?'))" 2>/dev/null)
      SAVED_SHA=$(CP_FILE="$latest" python3 -c "import json, os; print(json.load(open(os.environ['CP_FILE'])).get('git_sha','?'))" 2>/dev/null)

      # Normalize saved SHA to full length — checkpoints may store short or full SHAs
      SAVED_SHA_FULL=$(git rev-parse "$SAVED_SHA" 2>/dev/null || echo "$SAVED_SHA")

      if [ "$SAVED_SHA_FULL" = "$CURRENT_SHA" ]; then
        echo "  $PHASE_NAME: ✓ no drift (SHA ${SAVED_SHA_FULL:0:7})"
      else
        echo "  $PHASE_NAME: ⚠ DRIFT (saved: ${SAVED_SHA_FULL:0:7}, current: ${CURRENT_SHA:0:7})"
        HAS_DRIFT=1
      fi
    done

    if [ $HAS_DRIFT -eq 1 ]; then
      echo ""
      echo "Code has changed — re-run affected gates"
      exit 1
    fi
    echo ""
    echo "No drift detected across all phases"
    ;;

  history)
    echo "Checkpoint history:"
    echo ""
    find "$CHECKPOINT_DIR" -name "*.json" ! -name "*-latest.json" -type f 2>/dev/null | sort | while read -r cp; do
      CP_FILE="$cp" python3 -c "
import json, os
d = json.load(open(os.environ['CP_FILE']))
phase = d.get('phase','?')
sha = d.get('git_sha','?')
ts = d.get('timestamp','?')
msg = d.get('message','')
proofs = d.get('proof_snapshot', [])
passed = sum(1 for p in proofs if p['status'] == 'pass')
failed = sum(1 for p in proofs if p['status'] == 'fail')
status = '✓' if failed == 0 and passed > 0 else '✗' if failed > 0 else '?'
print(f'  {status} [{ts}] {phase} @ {sha} — {passed} pass, {failed} fail {(\": \" + msg) if msg else \"\"}')
" 2>/dev/null || true
    done
    ;;

  *)
    echo "Usage: checkpoint.sh <save|verify|drift|history> [phase] [message]"
    echo ""
    echo "Commands:"
    echo "  save <phase> [msg]  Save checkpoint after gates pass"
    echo "  verify <phase>      Check if checkpoint is still valid"
    echo "  drift               Check all phases for code drift"
    echo "  history             Show all checkpoints"
    exit 1
    ;;
esac
