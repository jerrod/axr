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
#   axr_emit_criterion "docs_context.1" "Root CLAUDE.md" script 3 "..." "ev1"
#   axr_defer_criterion "docs_context.3" "Local READMEs" "deferred to judgment"
#   axr_finalize_output   # prints the assembled JSON to stdout
#
# The reviewer field ("script", "agent-draft", etc.) is an explicit positional
# argument on every axr_emit_criterion call — no shell-global state, no
# leakage between criteria. Judgment subagents pass "agent-draft" at each
# call site.
#
# Intentionally does NOT set -e. Callers decide their own error discipline.

set -u

# Shell globals (reset on axr_init_output).
_AXR_DIMENSION_ID=""
_AXR_REVIEWER=""
_AXR_STACK_JSON="[]"
_AXR_CRITERIA_JSON="[]"

# Plugin root = scripts/lib/../../ = two levels up from this file. Used to
# locate rubric/rubric.v1.json regardless of target repo CWD.
_AXR_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_AXR_RUBRIC_PATH="$_AXR_PLUGIN_ROOT/rubric/rubric.v1.json"
_AXR_RUBRIC_NAMES_LOADED=0
declare -gA _AXR_CRITERION_NAME_BY_ID

# ---------------------------------------------------------------------------
# axr_repo_root — echo the TARGET repo root (the repo being scored), falling
# back to $PWD. For the PLUGIN root, see $_AXR_PLUGIN_ROOT.
#
# Note: a parallel cd_repo_root helper exists in scripts/lib/shell-helpers.sh
# for bin/ gate scripts that do not source common.sh. If detection strategy
# changes, update both.
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
# axr_criterion_name <criterion_id> — return the canonical criterion name
# from the rubric.
#
# Caching contract: the rubric is read from $_AXR_RUBRIC_PATH once per shell
# session and cached in _AXR_CRITERION_NAME_BY_ID. If the rubric file changes
# on disk during a single session, callers must unset _AXR_RUBRIC_NAMES_LOADED
# to force reload. In practice the rubric is write-once per run, so the
# cache is safe for Phase 1 checker scripts that load common.sh once and exit.
#
# Exits non-zero if the rubric is missing or the id is not found.
# ---------------------------------------------------------------------------
axr_criterion_name() {
    local id="$1"
    if [ "$_AXR_RUBRIC_NAMES_LOADED" != "1" ]; then
        if [ ! -f "$_AXR_RUBRIC_PATH" ]; then
            printf 'axr_criterion_name: rubric not found at %s\n' "$_AXR_RUBRIC_PATH" >&2
            return 1
        fi
        local k v
        while IFS=$'\t' read -r k v; do
            _AXR_CRITERION_NAME_BY_ID["$k"]="$v"
        done < <(jq -r '.dimensions[].criteria[] | [.id, .name] | @tsv' "$_AXR_RUBRIC_PATH")
        _AXR_RUBRIC_NAMES_LOADED=1
    fi
    local name="${_AXR_CRITERION_NAME_BY_ID[$id]:-}"
    if [ -z "$name" ]; then
        printf 'axr_criterion_name: no criterion with id=%s in rubric\n' "$id" >&2
        return 1
    fi
    printf '%s\n' "$name"
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
# axr_emit_criterion <id> <name> <reviewer> <score> <notes> [evidence...]
#
# reviewer is an explicit positional arg — typically "script" for mechanical
# checkers and "agent-draft" for judgment subagent emissions. No shell-global
# state: each call carries its own reviewer.
# ---------------------------------------------------------------------------
axr_emit_criterion() {
    local id="$1"
    local name="$2"
    local reviewer="$3"
    local score="$4"
    local notes="$5"
    shift 5
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
        --arg reviewer "$reviewer" \
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
