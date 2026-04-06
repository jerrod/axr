#!/usr/bin/env bash
# scripts/check-workflow-realism.sh — deterministic checker.
# Scores 2 mechanical criteria (.3, .5). Defers .1, .2, .4 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_package_scope "$@"
axr_init_output workflow_realism "script:check-workflow-realism.sh"

# ---------------------------------------------------------------------------
# workflow_realism.3 — External integrations stubable
# ---------------------------------------------------------------------------
score_workflow_realism_3() {
    local name
    name="$(axr_criterion_name workflow_realism.3)"

    local techs=()
    local ev=()

    # VCR cassettes
    local vcr_count
    vcr_count="$(find -P . -type f -not -type l \( -name '*.yml' -o -name '*.yaml' \) \
        \( -path '*/cassettes/*' -o -path '*/vcr/*' -o -path '*/fixtures/vcr_cassettes/*' \) \
        -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$vcr_count" -gt 0 ]; then techs+=("vcr"); ev+=("$vcr_count VCR cassette(s)"); fi

    # WireMock
    local wm_count
    wm_count="$(find -P . -type d -not -type l \( -name 'wiremock' -o -name 'wiremock-mappings' \) \
        -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$wm_count" -gt 0 ]; then techs+=("wiremock"); ev+=("$wm_count wiremock dir(s)"); fi

    # MSW
    if [ -d src/mocks ] || find -P . -type f -not -type l -name 'handlers.*' \
        \( -path '*/mocks/*' -o -path '*/__mocks__/*' \) \
        -not -path './node_modules/*' 2>/dev/null | head -1 | grep -q .; then
        techs+=("msw")
        ev+=("msw mocks/handlers present")
    fi

    # nock — grep source
    if grep -rE 'nock\(' --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' \
        . 2>/dev/null \
        | grep -v -E '(^|/)\.git/|(^|/)node_modules/|(^|/)\.axr/' \
        | head -1 | grep -q .; then
        techs+=("nock")
        ev+=("nock() calls in source")
    fi

    # Pact
    local pact_count
    pact_count="$(find -P . -type f -not -type l -name '*.json' -path '*/pacts/*' \
        -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$pact_count" -gt 0 ]; then techs+=("pact"); ev+=("$pact_count pact contract(s)"); fi

    # __mocks__
    local mocks_dirs
    mocks_dirs="$(find -P . -type d -not -type l -name '__mocks__' \
        -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$mocks_dirs" -gt 0 ]; then techs+=("__mocks__"); ev+=("$mocks_dirs __mocks__ dir(s)"); fi

    local n="${#techs[@]}"
    local score=0
    if [ "$n" -eq 0 ]; then
        score=0
    elif [ "$n" -ge 2 ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "workflow_realism.3" "$name" script 0 "no stubbing technology found"
    else
        axr_emit_criterion "workflow_realism.3" "$name" script "$score" "$n stubbing tech" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# workflow_realism.5 — Regression artifacts
# ---------------------------------------------------------------------------
score_workflow_realism_5() {
    local name
    name="$(axr_criterion_name workflow_realism.5)"

    local types=()
    local total=0
    local ev=()

    local snap_count
    snap_count="$(find -P . -type f -not -type l -name '*.snap' \
        -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$snap_count" -gt 0 ]; then
        types+=("snap")
        total=$((total + snap_count))
        ev+=("$snap_count .snap file(s)")
    fi

    local snapshot_dirs
    snapshot_dirs="$(find -P . -type d -not -type l -name '__snapshots__' \
        -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$snapshot_dirs" -gt 0 ] && [ "$snap_count" -eq 0 ]; then
        types+=("__snapshots__")
        total=$((total + snapshot_dirs))
        ev+=("$snapshot_dirs __snapshots__ dir(s)")
    fi

    local screenshot_count
    screenshot_count="$(find -P . -type f -not -type l \
        \( -path '*/cypress/screenshots/*' -o -path '*/percy/*' -o -path '*/loki/*' \) \
        -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$screenshot_count" -gt 0 ]; then
        types+=("visual")
        total=$((total + screenshot_count))
        ev+=("$screenshot_count visual regression file(s)")
    fi

    local golden_count
    golden_count="$(find -P . -type f -not -type l \
        \( -name '*.golden' -o -name '*golden*' \) \
        -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$golden_count" -gt 0 ]; then
        types+=("golden")
        total=$((total + golden_count))
        ev+=("$golden_count golden file(s)")
    fi

    local n="${#types[@]}"
    local score=0
    if [ "$total" -eq 0 ]; then
        score=0
    elif [ "$total" -ge 11 ] && [ "$n" -ge 2 ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "workflow_realism.5" "$name" script 0 "no regression artifacts found"
    else
        axr_emit_criterion "workflow_realism.5" "$name" script "$score" "$total regression artifact(s)" \
            "${ev[@]}"
    fi
}

axr_defer_criterion "workflow_realism.1" "$(axr_criterion_name workflow_realism.1)" "deferred to Phase 3 judgment subagent"
axr_defer_criterion "workflow_realism.2" "$(axr_criterion_name workflow_realism.2)" "deferred to Phase 3 judgment subagent"
score_workflow_realism_3
axr_defer_criterion "workflow_realism.4" "$(axr_criterion_name workflow_realism.4)" "deferred to Phase 3 judgment subagent"
score_workflow_realism_5

axr_finalize_output
