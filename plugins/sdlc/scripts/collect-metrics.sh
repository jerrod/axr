#!/usr/bin/env bash
# Collect quality gate metrics and push to sdlc-metrics repo.
# Usage: bash collect-metrics.sh [phase] [--gate gate-name]
#
# $1 = phase (build/review/ship/all, default: all)
# --gate flag: only report a single gate's proof (per-gate mode)
# Without --gate: reads ALL proof files for a full summary report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

REPO_NAME=$(get_repo_name)
BRANCH=$(git branch --show-current)
SHA=$(git rev-parse HEAD)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
USER_NAME=$(git config user.name 2>/dev/null || echo "unknown")
USER_EMAIL=$(git config user.email 2>/dev/null || echo "")

PHASE="${1:-all}"
GATE_NAME=""
if [ "${2:-}" = "--gate" ]; then
  GATE_NAME="${3:-}"
fi

# Find or clone the sdlc-metrics repo, printing its path to stdout.
# Returns 1 if no repo could be located.
#
# Environment variables:
#   RQ_METRICS_DIR      — absolute path to local sdlc-metrics clone (preferred,
#                         documented exception to the RQ_→SDLC_ rename because
#                         it's a user-scoped path unrelated to plugin identity)
#   SDLC_METRICS_REMOTE — GitHub owner/repo to clone from (default:
#                         arqu-co/sdlc-metrics). Legacy RQ_METRICS_REMOTE is
#                         still honored as a fallback for existing user shells.
find_or_clone_metrics_repo() {
  # 1. Explicit path via env var (most reliable)
  if [ -n "${RQ_METRICS_DIR:-}" ] && [ -d "$RQ_METRICS_DIR/.git" ]; then
    echo "$RQ_METRICS_DIR"
    return 0
  fi

  # 2. Common locations
  local candidates=("$HOME/Sites/sdlc-metrics" "$HOME/sdlc-metrics")
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -d "$candidate/.git" ]; then
      echo "$candidate"
      return 0
    fi
  done

  # 3. Clone from GitHub
  local remote="${SDLC_METRICS_REMOTE:-${RQ_METRICS_REMOTE:-arqu-co/sdlc-metrics}}"
  local target="${RQ_METRICS_DIR:-$HOME/Sites/sdlc-metrics}"
  if gh repo view "$remote" &>/dev/null 2>&1; then
    git clone --depth 1 "https://github.com/$remote.git" \
      "$target" 2>/dev/null || true
    if [ -d "$target/.git" ]; then
      echo "$target"
      return 0
    fi
  fi

  echo "WARN: Set RQ_METRICS_DIR to your sdlc-metrics clone path" >&2
  return 1
}

# Resolve metrics data dir BEFORE invoking Python so run_number works
METRICS_DATA_DIR=""
if METRICS_REPO=$(find_or_clone_metrics_repo 2>/dev/null); then
  METRICS_DATA_DIR="$METRICS_REPO/data/$REPO_NAME/$BRANCH"
else
  METRICS_REPO=""
fi

# Build metrics JSON via Python (reads proof files)
METRICS_JSON=$(python3 -c "
$(cat "$SCRIPT_DIR/collect_metrics_payload.py")
" "$PROOF_DIR" "" "0" \
  "$REPO_NAME" "$BRANCH" "$SHA" "$USER_NAME" "$TIMESTAMP" \
  "$PHASE" "$GATE_NAME" "$METRICS_DATA_DIR" "$USER_EMAIL" 2>/dev/null) || {
  echo "WARN: failed to build metrics JSON" >&2
  exit 0
}

# Save locally
mkdir -p "$PROOF_DIR"
echo "$METRICS_JSON" >"$PROOF_DIR/metrics.json"
echo "$METRICS_JSON"

# Copy metrics JSON into the repo's data directory and return first_pass.
copy_metrics_to_repo() {
  local metrics_repo="$1"
  local metrics_dir="$metrics_repo/data/$REPO_NAME/$BRANCH"
  mkdir -p "$metrics_dir"
  local filename="${SHA}"
  if [ -n "$GATE_NAME" ]; then
    filename="${SHA}-${GATE_NAME}"
  fi
  filename="${filename}-$(date +%Y%m%d%H%M%S).json"
  cp "$PROOF_DIR/metrics.json" "$metrics_dir/$filename"
  python3 -c "
import json, sys
m = json.loads(sys.stdin.read())
print(str(m.get('gates_first_pass', True)).lower())
" <"$PROOF_DIR/metrics.json" 2>/dev/null || echo "true"
}

# Stage, commit, and push metrics data.
commit_and_push_metrics() {
  local metrics_repo="$1" is_first_pass="$2"
  (
    cd "$metrics_repo"
    git pull --rebase --quiet 2>/dev/null || true
    git add data/
    git commit -m "metrics: $REPO_NAME/$BRANCH@$SHA (first_pass=$is_first_pass)" \
      --quiet 2>/dev/null || true
    git push --quiet 2>/dev/null ||
      echo "WARN: could not push metrics (non-fatal)" >&2
  )
  echo "Metrics pushed to sdlc-metrics repo" >&2
}

# Push to sdlc-metrics repo if available (reuses METRICS_REPO from early resolution)
push_to_metrics_repo() {
  if [ -z "$METRICS_REPO" ]; then
    echo "WARN: sdlc-metrics repo not found — metrics saved locally only" >&2
    return 0
  fi
  local is_first_pass
  is_first_pass=$(copy_metrics_to_repo "$METRICS_REPO")
  # Per-gate mode: copy only, defer commit+push to summary call.
  # Unsent files are picked up by the next summary's "git add data/".
  if [ -n "$GATE_NAME" ]; then
    return 0
  fi
  commit_and_push_metrics "$METRICS_REPO" "$is_first_pass"
}

push_to_metrics_repo
