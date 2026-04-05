#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for rq-axr dimension checkers.
#
# Sourced by each scripts/check-<dimension>.sh. Provides helpers to assemble
# per-criterion JSON output conforming to the schema documented in
# docs/plugin-brief.md. All shell globals are prefixed _AXR_.
#
# Usage:
#   source scripts/lib/common.sh
#   axr_init_output docs_context script:check-docs-context.sh
#   axr_emit_criterion "docs_context.1" 3 "..." "evidence one" "evidence two"
#   axr_defer_criterion "docs_context.3" "deferred to judgment"
#   axr_finalize_output   # prints the assembled JSON to stdout
#
# Intentionally does NOT set -e. Callers decide their own error discipline.

set -u

# Shell globals (reset on axr_init_output).
_AXR_DIMENSION_ID=""
_AXR_REVIEWER=""
_AXR_STACK_JSON="[]"
_AXR_CRITERIA_JSON="[]"

# ---------------------------------------------------------------------------
# axr_repo_root — echo the repo root, falling back to $PWD.
# ---------------------------------------------------------------------------
axr_repo_root() {
    local root
    if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        printf '%s\n' "$root"
    else
        printf '%s\n' "$PWD"
    fi
}

# ---------------------------------------------------------------------------
# axr_detect_stack — print a JSON array of stack tags detected from markers
# in $PWD. Recognised tags: python, node, kotlin, ruby, rust, go, markdown.
# ---------------------------------------------------------------------------
axr_detect_stack() {
    local tags=()
    if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ] || [ -f Pipfile ]; then
        tags+=("python")
    fi
    if [ -f package.json ]; then
        tags+=("node")
    fi
    if [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f settings.gradle.kts ]; then
        tags+=("kotlin")
    fi
    if [ -f Gemfile ] || [ -f "$(printf '%s' "*.gemspec")" ] 2>/dev/null; then
        if [ -f Gemfile ] || ls ./*.gemspec >/dev/null 2>&1; then
            tags+=("ruby")
        fi
    fi
    if [ -f Cargo.toml ]; then
        tags+=("rust")
    fi
    if [ -f go.mod ]; then
        tags+=("go")
    fi
    # Markdown is a weak default when the repo is primarily docs.
    if [ -f README.md ] || [ -f CLAUDE.md ] || [ -f AGENTS.md ]; then
        tags+=("markdown")
    fi

    if [ ${#tags[@]} -eq 0 ]; then
        printf '[]\n'
        return 0
    fi
    # Build JSON array via jq.
    printf '%s\n' "${tags[@]}" | jq -R . | jq -sc .
}

# ---------------------------------------------------------------------------
# axr_init_output <dimension_id> <reviewer>
# ---------------------------------------------------------------------------
axr_init_output() {
    _AXR_DIMENSION_ID="$1"
    _AXR_REVIEWER="$2"
    _AXR_STACK_JSON="$(axr_detect_stack)"
    _AXR_CRITERIA_JSON="[]"
}

# ---------------------------------------------------------------------------
# axr_emit_criterion <id> <score> <notes> [evidence...]
# ---------------------------------------------------------------------------
axr_emit_criterion() {
    local id="$1"; local score="$2"; local notes="$3"
    shift 3
    local evidence_json
    if [ "$#" -eq 0 ]; then
        evidence_json="[]"
    else
        evidence_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
    fi
    _AXR_CRITERIA_JSON="$(jq -c \
        --arg id "$id" \
        --argjson score "$score" \
        --arg notes "$notes" \
        --argjson evidence "$evidence_json" \
        '. + [{id:$id, score:$score, evidence:$evidence, notes:$notes, reviewer:"script"}]' \
        <<<"$_AXR_CRITERIA_JSON")"
}

# ---------------------------------------------------------------------------
# axr_defer_criterion <id> [notes]
# ---------------------------------------------------------------------------
axr_defer_criterion() {
    local id="$1"
    local notes="${2:-Deferred to judgment subagent}"
    _AXR_CRITERIA_JSON="$(jq -c \
        --arg id "$id" \
        --arg notes "$notes" \
        '. + [{id:$id, score:null, deferred:true, reviewer:"judgment", notes:$notes}]' \
        <<<"$_AXR_CRITERIA_JSON")"
}

# ---------------------------------------------------------------------------
# axr_finalize_output — print the assembled JSON object.
# ---------------------------------------------------------------------------
axr_finalize_output() {
    jq -n \
        --arg dimension_id "$_AXR_DIMENSION_ID" \
        --arg reviewer "$_AXR_REVIEWER" \
        --argjson stack "$_AXR_STACK_JSON" \
        --argjson criteria "$_AXR_CRITERIA_JSON" \
        '{dimension_id:$dimension_id, stack:$stack, reviewer:$reviewer, criteria:$criteria}'
}
