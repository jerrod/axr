#!/usr/bin/env bash
# scripts/check-execution-visibility.sh — deterministic checker.
# Scores 2 mechanical criteria (.3, .5). Defers .1, .2, .4 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_package_scope "$@"
axr_init_output execution_visibility "script:check-execution-visibility.sh"

# ---------------------------------------------------------------------------
# execution_visibility.3 — Errors route to a single searchable place
# ---------------------------------------------------------------------------
score_execution_visibility_3() {
    local name
    name="$(axr_criterion_name execution_visibility.3)"

    local signals=()

    # SDK init in source
    if command -v grep >/dev/null 2>&1; then
        if grep -rE '(Sentry\.init|sentry\.init|sentry_sdk\.init|Rollbar\.init|bugsnag\.start|datadog\.init)' \
            --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' --include='*.go' \
            --include='*.tsx' --include='*.jsx' \
            . 2>/dev/null \
            | grep -v -E '(^|/)\.git/|(^|/)node_modules/|(^|/)\.venv/|(^|/)venv/|(^|/)\.axr/' \
            | head -1 | grep -q .; then
            signals+=("SDK init found in source")
        fi
    fi

    # Env-var markers
    local env_files=(.env.example .env.sample .env .env.test)
    local envsig=""
    local f
    for f in "${env_files[@]}"; do
        [ -f "$f" ] || continue
        if grep -qE '(SENTRY_DSN|ROLLBAR_TOKEN|BUGSNAG_API_KEY|DATADOG_API_KEY|HONEYCOMB_API_KEY|OTEL_EXPORTER)' "$f" 2>/dev/null; then
            envsig="${envsig}${f},"
        fi
    done
    envsig="${envsig%,}"
    [ -n "$envsig" ] && signals+=("env-var markers: $envsig")

    # Log shipping config
    local ship=""
    for f in logdna.yml papertrail.yml loki.yml loki-config.yml; do
        [ -f "$f" ] && ship="${ship}${f},"
    done
    ship="${ship%,}"
    [ -n "$ship" ] && signals+=("log shipping: $ship")

    local n="${#signals[@]}"
    local score=0
    if [ "$n" -eq 0 ]; then
        score=0
    elif [ "$n" -ge 2 ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "execution_visibility.3" "$name" script 0 "no error-tracking signals"
    else
        axr_emit_criterion "execution_visibility.3" "$name" script "$score" "$n signal(s) found" \
            "${signals[@]}"
    fi
}

# ---------------------------------------------------------------------------
# execution_visibility.5 — Test failures preserve logs/artifacts
# ---------------------------------------------------------------------------
score_execution_visibility_5() {
    local name
    name="$(axr_criterion_name execution_visibility.5)"

    if [ ! -d .github/workflows ]; then
        axr_emit_criterion "execution_visibility.5" "$name" script 0 "no workflows directory"
        return
    fi

    local has_upload=0 has_failure_cond=0
    if find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
        | xargs -0 grep -lE 'actions/upload-artifact' 2>/dev/null | head -1 | grep -q .; then
        has_upload=1
    fi
    if find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
        | xargs -0 grep -lE 'if:[[:space:]]*(failure|always)\(\)' 2>/dev/null | head -1 | grep -q .; then
        has_failure_cond=1
    fi

    local ev=()
    [ "$has_upload" = "1" ] && ev+=("upload-artifact action used")
    [ "$has_failure_cond" = "1" ] && ev+=("if: failure()/always() condition present")

    local score=0
    if [ "$has_upload" = "0" ]; then
        score=0
    elif [ "$has_failure_cond" = "1" ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "execution_visibility.5" "$name" script 0 "no artifact upload in workflows"
    else
        axr_emit_criterion "execution_visibility.5" "$name" script "$score" "CI artifact handling" \
            "${ev[@]}"
    fi
}

axr_defer_criterion "execution_visibility.1" "$(axr_criterion_name execution_visibility.1)" "deferred to Phase 3 judgment subagent"
axr_defer_criterion "execution_visibility.2" "$(axr_criterion_name execution_visibility.2)" "deferred to Phase 3 judgment subagent"
score_execution_visibility_3
axr_defer_criterion "execution_visibility.4" "$(axr_criterion_name execution_visibility.4)" "deferred to Phase 3 judgment subagent"
score_execution_visibility_5

axr_finalize_output
