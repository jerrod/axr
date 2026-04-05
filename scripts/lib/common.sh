#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for rq-axr dimension checkers.
#
# Sourced by each scripts/check-<dimension>.sh. Provides helpers to assemble
# per-criterion JSON output conforming to the schema documented in
# docs/plugin-brief.md. All shell globals are prefixed _AXR_.
#
# Usage:
#   source scripts/lib/common.sh
#   axr_init_output docs_context "script:check-docs-context.sh"
#   axr_emit_criterion "docs_context.1" "Root CLAUDE.md" 3 "..." "evidence one"
#   axr_defer_criterion "docs_context.3" "Local READMEs" "deferred to judgment"
#   axr_finalize_output   # prints the assembled JSON to stdout
#
# Per-criterion reviewer defaults to "script" for mechanical checkers. Judgment
# subagents that source this lib can override by setting _AXR_CRITERION_REVIEWER
# before calling axr_emit_criterion, e.g.:
#   _AXR_CRITERION_REVIEWER="agent-draft" axr_emit_criterion ...
#
# Intentionally does NOT set -e. Callers decide their own error discipline.

set -u

# Shell globals (reset on axr_init_output).
_AXR_DIMENSION_ID=""
_AXR_REVIEWER=""
_AXR_STACK_JSON="[]"
_AXR_CRITERIA_JSON="[]"
_AXR_CRITERION_REVIEWER="${_AXR_CRITERION_REVIEWER:-script}"

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
# axr_detect_stack — print a JSON array of stack tags detected from marker
# files in the repo root. Recognised tags: python, node, kotlin, ruby, rust,
# go, markdown. The markdown tag is only added when no other tags match (so
# polyglot repos don't carry a weak tag).
# ---------------------------------------------------------------------------
axr_detect_stack() {
    local root
    root="$(axr_repo_root)"
    local tags=()
    if [ -f "$root/pyproject.toml" ] || [ -f "$root/requirements.txt" ] || [ -f "$root/setup.py" ] || [ -f "$root/Pipfile" ]; then
        tags+=("python")
    fi
    if [ -f "$root/package.json" ]; then
        tags+=("node")
    fi
    if [ -f "$root/build.gradle" ] || [ -f "$root/build.gradle.kts" ] || [ -f "$root/settings.gradle.kts" ]; then
        tags+=("kotlin")
    fi
    if [ -f "$root/Gemfile" ] || compgen -G "$root/*.gemspec" >/dev/null 2>&1; then
        tags+=("ruby")
    fi
    if [ -f "$root/Cargo.toml" ]; then
        tags+=("rust")
    fi
    if [ -f "$root/go.mod" ]; then
        tags+=("go")
    fi
    # Markdown is a fallback tag — only when no other stack was detected.
    if [ ${#tags[@]} -eq 0 ] && { [ -f "$root/README.md" ] || [ -f "$root/CLAUDE.md" ] || [ -f "$root/AGENTS.md" ]; }; then
        tags+=("markdown")
    fi

    if [ ${#tags[@]} -eq 0 ]; then
        printf '[]\n'
        return 0
    fi
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
# axr_emit_criterion <id> <name> <score> <notes> [evidence...]
#
# reviewer field defaults to $_AXR_CRITERION_REVIEWER ("script" unless
# overridden by the caller).
# ---------------------------------------------------------------------------
axr_emit_criterion() {
    local id="$1"
    local name="$2"
    local score="$3"
    local notes="$4"
    shift 4
    local evidence_json
    if [ "$#" -eq 0 ]; then
        evidence_json="[]"
    else
        evidence_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
    fi
    _AXR_CRITERIA_JSON="$(jq -c \
        --arg id "$id" \
        --arg name "$name" \
        --argjson score "$score" \
        --arg notes "$notes" \
        --argjson evidence "$evidence_json" \
        --arg reviewer "$_AXR_CRITERION_REVIEWER" \
        '. + [{id:$id, name:$name, score:$score, evidence:$evidence, notes:$notes, reviewer:$reviewer}]' \
        <<<"$_AXR_CRITERIA_JSON")"
}

# ---------------------------------------------------------------------------
# axr_defer_criterion <id> <name> [notes]
# ---------------------------------------------------------------------------
axr_defer_criterion() {
    local id="$1"
    local name="$2"
    local notes="${3:-Deferred to judgment subagent}"
    _AXR_CRITERIA_JSON="$(jq -c \
        --arg id "$id" \
        --arg name "$name" \
        --arg notes "$notes" \
        '. + [{id:$id, name:$name, score:null, evidence:[], notes:$notes, reviewer:"judgment", deferred:true}]' \
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
