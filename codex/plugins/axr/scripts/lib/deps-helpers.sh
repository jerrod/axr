#!/usr/bin/env bash
# scripts/lib/deps-helpers.sh — dependency/supply-chain detection helpers
# shared across dimension checkers that inspect lockfiles, audit configs,
# and upgrade automation (check-supply-chain.sh primarily).
#
# Pure functions — take no shell-global state, output to stdout.
#
# Contract: callers MUST be at the target repo root (cwd).

# Source sibling helpers for shared data
# shellcheck source-path=SCRIPTDIR
# shellcheck source=tooling-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/tooling-helpers.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=workflow-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/workflow-helpers.sh"

# ---------------------------------------------------------------------------
# list_audit_configs — print vulnerability scanning config files present.
# ---------------------------------------------------------------------------
list_audit_configs() {
    local f
    for f in .nsprc .audit-ci.json .pip-audit.toml .snyk \
             sonatype-lift.yml cargo-audit.toml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# list_upgrade_configs — print upgrade automation config files present.
# ---------------------------------------------------------------------------
list_upgrade_configs() {
    local f
    for f in renovate.json .renovaterc .renovaterc.json \
             .github/dependabot.yml .github/dependabot.yaml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# lockfile_age_days — print age in days of the most recently modified
# lockfile (minimum age = freshest). Prints nothing if no lockfiles found.
# ---------------------------------------------------------------------------
lockfile_age_days() {
    local now min_age ts age f
    now=$(date +%s)
    min_age=""
    for f in "${_AXR_LOCKFILES[@]}"; do
        [ -f "$f" ] || continue
        ts=$(git log -1 --format=%ct -- "$f" 2>/dev/null) || continue
        [ -z "$ts" ] && continue
        age=$(( (now - ts) / 86400 ))
        if [ -z "$min_age" ] || [ "$age" -lt "$min_age" ]; then
            min_age=$age
        fi
    done
    [ -n "$min_age" ] && printf '%d\n' "$min_age"
    return 0
}

# ---------------------------------------------------------------------------
# ci_has_frozen_lockfile — return 0 if CI workflows use frozen-lockfile
# install patterns; 1 otherwise.
# ---------------------------------------------------------------------------
ci_has_frozen_lockfile() {
    local lines
    lines=$(extract_workflow_run_lines)
    [ -z "$lines" ] && return 1
    printf '%s\n' "$lines" | grep -qE \
        '--frozen-lockfile|npm ci|--locked|--require-hashes|pip install --constraint'
}
