#!/usr/bin/env bash
# Gate: Plan — ensure the current branch has a plan file in ~/.claude/plans/
# Produces: .quality/proof/plan.json
# Opt-in: only enforces when plan_required=true in sdlc.config.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Clear tracking file from prior runs
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-plan.jsonl"

# Default PLAN_REQUIRED so the inline crash trap below can reference it even
# if the ERR fires before step 1 resolves the real value.
PLAN_REQUIRED=false
SHA=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# _rc is assigned and read inside the inline trap below
_rc=0

# Inline trap: always produce a crash-proof JSON even on unexpected ERR.
# Inline form (not a named function) avoids shellcheck SC2329 false positive
# for trap-invoked functions. Variables are expanded at ERR time, not at
# trap-declaration time, so PLAN_REQUIRED reflects its latest value.
trap '_rc=$?; printf "{\n  \"gate\": \"plan\",\n  \"sha\": \"%s\",\n  \"status\": \"fail\",\n  \"error\": \"script crashed with exit code %s\",\n  \"plan_required\": %s,\n  \"plan_path\": null,\n  \"bypassed_via\": null,\n  \"reason\": \"\",\n  \"timestamp\": \"%s\"\n}\n" "$SHA" "$_rc" "$PLAN_REQUIRED" "$TIMESTAMP" > "$PROOF_DIR/plan.json"; cat "$PROOF_DIR/plan.json"; echo "GATE FAILED: script crashed (exit $_rc) — run with bash -x to debug" >&2' ERR

# ─── 1. plan_required check ─────────────────────────────────────
# Resolve plan_required up front so both the CI-skip path and the
# plan_required=false path report the repo's actual configuration.
PLAN_REQUIRED=$(python3 -c "
import json, os, sys
cfg = os.environ.get('SDLC_CONFIG_FILE', '')
if not cfg or not os.path.isfile(cfg):
    print('false')
    sys.exit(0)
with open(cfg) as f:
    data = json.load(f)
print('true' if data.get('plan_required', False) else 'false')
" 2>/dev/null || echo 'false')

# ─── 1.5. CI skip ───────────────────────────────────────────────
# Plan files live in ~/.claude/plans/<repo>/<branch>.md on author workstations
# and are intentionally not checked into the repo. CI environments never have
# them, so enforcing this gate in CI would always fail. Author-side pre-push
# is the point of enforcement; CI enforces the committed code.
if [ "${CI:-}" = "true" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
  trap - ERR
  cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "skip",
  "error": null,
  "plan_required": $PLAN_REQUIRED,
  "plan_path": null,
  "bypassed_via": "ci_environment",
  "reason": "plan gate is author-side only — plan files live outside the repo",
  "timestamp": "$TIMESTAMP"
}
ENDJSON
  cat "$PROOF_DIR/plan.json"
  exit 0
fi

if [ "$PLAN_REQUIRED" != "true" ]; then
  trap - ERR
  cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "skip",
  "error": null,
  "plan_required": false,
  "plan_path": null,
  "bypassed_via": null,
  "reason": "plan_required not set in sdlc.config.json",
  "timestamp": "$TIMESTAMP"
}
ENDJSON
  cat "$PROOF_DIR/plan.json"
  exit 0
fi

# ─── 2. Resolve branch and slug ─────────────────────────────────
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)
BRANCH_SLUG="${BRANCH//\//-}"
REPO_NAME=$(get_repo_name)
PLAN_PATH="$HOME/.claude/plans/$REPO_NAME/$BRANCH_SLUG.md"
# JSON-safe form for interpolation inside heredoc string literals
BRANCH_ESC=$(printf '%s' "$BRANCH" | sed 's/\\/\\\\/g; s/"/\\"/g')
PLAN_PATH_ESC=$(printf '%s' "$PLAN_PATH" | sed 's/\\/\\\\/g; s/"/\\"/g')

# ─── 3. Hotfix bypass ───────────────────────────────────────────
HEAD_MSG=$(git log -1 --format='%s' 2>/dev/null || echo '')
if echo "$HEAD_MSG" | grep -qE '^hotfix:'; then
  trap - ERR
  cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "skip",
  "error": null,
  "plan_required": true,
  "plan_path": null,
  "bypassed_via": "hotfix_prefix",
  "reason": "hotfix: prefix on HEAD commit",
  "timestamp": "$TIMESTAMP"
}
ENDJSON
  cat "$PROOF_DIR/plan.json"
  exit 0
fi

# ─── 4. Plan file exists ─────────────────────────────────────────
if [ -f "$PLAN_PATH" ]; then
  trap - ERR
  cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "pass",
  "error": null,
  "plan_required": true,
  "plan_path": "$PLAN_PATH_ESC",
  "bypassed_via": null,
  "reason": null,
  "timestamp": "$TIMESTAMP"
}
ENDJSON
  cat "$PROOF_DIR/plan.json"
  exit 0
fi

# ─── 5. Allow-list check ────────────────────────────────────────
if is_allowed "plan" "branch=$BRANCH"; then
  trap - ERR
  cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "skip",
  "error": null,
  "plan_required": true,
  "plan_path": null,
  "bypassed_via": "allow_list",
  "reason": "branch '$BRANCH_ESC' matched allow.plan entry",
  "timestamp": "$TIMESTAMP"
}
ENDJSON
  cat "$PROOF_DIR/plan.json"
  report_unused_allow_entries plan
  exit 0
fi

# ─── 6. Fail ────────────────────────────────────────────────────
trap - ERR
cat >"$PROOF_DIR/plan.json" <<ENDJSON
{
  "gate": "plan",
  "sha": "$SHA",
  "status": "fail",
  "error": "No plan file found for branch '$BRANCH_ESC'",
  "plan_required": true,
  "plan_path": null,
  "bypassed_via": null,
  "reason": null,
  "timestamp": "$TIMESTAMP"
}
ENDJSON
cat "$PROOF_DIR/plan.json"

cat >&2 <<ERRMSG

GATE FAILED: plan file not found
  Branch:    $BRANCH
  Expected:  $PLAN_PATH

Options:
  • Create a plan: /sdlc:plan
  • Emergency bypass: prefix the tip commit with 'hotfix:' (logged in PROOF.md)
  • Per-branch allow: add {"branch": "$BRANCH", "reason": "..."} under allow.plan in sdlc.config.json
  • Repo-level opt-out: remove or set plan_required=false in sdlc.config.json

ERRMSG
report_unused_allow_entries plan
exit 1
