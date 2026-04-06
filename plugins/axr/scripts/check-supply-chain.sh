#!/usr/bin/env bash
# scripts/check-supply-chain.sh — deterministic checker for the supply-chain
# dimension of the axr rubric.
#
# Scores four mechanical criteria. Defers .5 to judgment.
# Emits a single JSON object to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/tooling-helpers.sh
source "$SCRIPT_DIR/lib/tooling-helpers.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/workflow-helpers.sh
source "$SCRIPT_DIR/lib/workflow-helpers.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/deps-helpers.sh
source "$SCRIPT_DIR/lib/deps-helpers.sh"

axr_package_scope "$@"
axr_init_output supply-chain "script:check-supply-chain.sh"

# -- supply-chain.no-vulnerabilities — Vulnerability scanning configured ----
score_supply_chain_1() {
    local name
    name="$(axr_criterion_name supply-chain.no-vulnerabilities)"

    local audit_configs
    audit_configs="$(list_audit_configs)"

    local ci_audit=""
    ci_audit="$(extract_workflow_run_lines | grep -iE 'audit|snyk|trivy|grype|osv-scanner' | head -5)" || true

    local has_config=0 has_ci=0
    [ -n "$audit_configs" ] && has_config=1
    [ -n "$ci_audit" ] && has_ci=1
    local ev=()
    [ "$has_config" -eq 1 ] && ev+=("audit config: $(echo "$audit_configs" | tr '\n' ', ' | sed 's/,$//')")
    [ "$has_ci" -eq 1 ] && ev+=("CI runs audit step")

    if [ "$has_config" -eq 0 ] && [ "$has_ci" -eq 0 ]; then
        axr_emit_criterion "supply-chain.no-vulnerabilities" "$name" script 0 \
            "no vulnerability scanning configured" "no audit config or CI audit step found"
    elif [ "$has_ci" -eq 1 ]; then
        axr_emit_criterion "supply-chain.no-vulnerabilities" "$name" script 3 \
            "CI runs vulnerability scanning" "${ev[@]}"
    else
        axr_emit_criterion "supply-chain.no-vulnerabilities" "$name" script 2 \
            "audit config present but no CI step" "${ev[@]}"
    fi
}

# -- supply-chain.lockfile-verified-in-ci — Lockfile verified in CI ---------
score_supply_chain_2() {
    local name
    name="$(axr_criterion_name supply-chain.lockfile-verified-in-ci)"

    local lockfile_count
    lockfile_count="$(count_lockfiles)"

    if [ "$lockfile_count" -eq 0 ]; then
        axr_emit_criterion "supply-chain.lockfile-verified-in-ci" "$name" script 0 \
            "no lockfile found" "no lockfiles detected"
        return
    fi

    if ci_has_frozen_lockfile; then
        axr_emit_criterion "supply-chain.lockfile-verified-in-ci" "$name" script 3 \
            "CI verifies lockfile with frozen flags" \
            "$lockfile_count lockfile(s) committed, CI uses frozen install"
    else
        # Check if lockfile is committed (git tracked)
        local committed=0
        local f _lf=()
        while IFS= read -r f; do _lf+=("$f"); done < <(list_lockfiles)
        for f in "${_lf[@]}"; do
            if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
                committed=1
                break
            fi
        done

        if [ "$committed" -eq 1 ]; then
            axr_emit_criterion "supply-chain.lockfile-verified-in-ci" "$name" script 2 \
                "lockfile committed but CI does not verify" \
                "$lockfile_count lockfile(s), no frozen-install flag in CI"
        else
            axr_emit_criterion "supply-chain.lockfile-verified-in-ci" "$name" script 1 \
                "lockfile present but not committed" \
                "$lockfile_count lockfile(s) found, not tracked by git"
        fi
    fi
}

# -- supply-chain.upgrades-merged — Automated dependency upgrades -----------
score_supply_chain_3() {
    local name
    name="$(axr_criterion_name supply-chain.upgrades-merged)"

    local upgrade_configs
    upgrade_configs="$(list_upgrade_configs)"

    if [ -z "$upgrade_configs" ]; then
        axr_emit_criterion "supply-chain.upgrades-merged" "$name" script 0 \
            "no dependency upgrade automation" "no renovate or dependabot config found"
        return
    fi

    local config_list
    config_list="$(echo "$upgrade_configs" | tr '\n' ', ' | sed 's/,$//')"

    # Check for auto-merge configuration
    local has_automerge=0
    local f
    for f in renovate.json .renovaterc .renovaterc.json; do
        if [ -f "$f" ]; then
            if grep -qE '"automerge"\s*:\s*true' "$f" 2>/dev/null; then
                has_automerge=1
                break
            fi
        fi
    done

    # Check dependabot + auto-merge actions
    if [ "$has_automerge" -eq 0 ] && [ -d .github/workflows ]; then
        local am_match=""
        am_match="$(extract_workflow_run_lines | grep -iE 'auto-merge|automerge|merge.*dependabot' | head -3)" || true
        [ -n "$am_match" ] && has_automerge=1
    fi

    # Check CI testing (any CI workflow existing counts)
    local has_ci=0
    if [ -d .github/workflows ]; then
        local wf_count
        wf_count="$(find -P .github/workflows -maxdepth 1 -type f -not -type l \
            \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | wc -l | tr -d ' ')"
        [ "$wf_count" -gt 0 ] && has_ci=1
    fi

    if [ "$has_automerge" -eq 1 ] && [ "$has_ci" -eq 1 ]; then
        axr_emit_criterion "supply-chain.upgrades-merged" "$name" script 3 \
            "auto-merge with CI testing" "$config_list, auto-merge enabled, CI workflows present"
    elif [ "$has_automerge" -eq 1 ]; then
        axr_emit_criterion "supply-chain.upgrades-merged" "$name" script 2 \
            "auto-merge configured for patches" "$config_list, auto-merge enabled"
    else
        axr_emit_criterion "supply-chain.upgrades-merged" "$name" script 1 \
            "upgrade config without auto-merge" "$config_list"
    fi
}

# -- supply-chain.freshness — Dependencies are fresh -----------------------
score_supply_chain_4() {
    local name
    name="$(axr_criterion_name supply-chain.freshness)"

    local lockfile_count
    lockfile_count="$(count_lockfiles)"

    if [ "$lockfile_count" -eq 0 ]; then
        axr_emit_criterion "supply-chain.freshness" "$name" script 0 \
            "no lockfile found" "cannot assess freshness without a lockfile"
        return
    fi

    local age
    age="$(lockfile_age_days)"

    if [ -z "$age" ]; then
        axr_emit_criterion "supply-chain.freshness" "$name" script 1 \
            "lockfile present but age unknown" \
            "lockfile exists but no git history for age calculation"
        return
    fi

    if [ "$age" -lt 90 ]; then
        axr_emit_criterion "supply-chain.freshness" "$name" script 3 \
            "lockfile updated within 90 days" "last lockfile update: $age days ago"
    elif [ "$age" -le 180 ]; then
        axr_emit_criterion "supply-chain.freshness" "$name" script 2 \
            "lockfile updated within 180 days" "last lockfile update: $age days ago"
    else
        axr_emit_criterion "supply-chain.freshness" "$name" script 1 \
            "lockfile older than 180 days" "last lockfile update: $age days ago"
    fi
}

# -- Run scoring functions, defer judgment, finalize. -----------------------
score_supply_chain_1
score_supply_chain_2
score_supply_chain_3
score_supply_chain_4
axr_defer_criterion "supply-chain.minimal-surface" \
    "$(axr_criterion_name supply-chain.minimal-surface)" \
    "Deferred to judgment subagent (supply-chain-reviewer)"

axr_finalize_output
