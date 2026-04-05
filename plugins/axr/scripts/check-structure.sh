#!/usr/bin/env bash
# scripts/check-structure.sh — deterministic checker for structure dimension.
# Scores 2 mechanical criteria (.2, .5). Defers .1, .3, .4 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_init_output structure "script:check-structure.sh"

STACK_JSON="$(axr_detect_stack)"
has_tag() {
    jq -e --arg t "$1" 'any(.[]; . == $t)' <<<"$STACK_JSON" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# structure.2 — No circular dependencies
# ---------------------------------------------------------------------------
score_structure_2() {
    local name
    name="$(axr_criterion_name structure.2)"

    local attempts=()

    if has_tag node; then
        attempts+=("node: attempted npx madge")
        if command -v npx >/dev/null 2>&1 && npx --yes madge --version >/dev/null 2>&1; then
            local entry=""
            for e in src lib; do
                [ -d "$e" ] && { entry="$e"; break; }
            done
            if [ -z "$entry" ] && [ -f package.json ]; then
                entry="$(jq -r '.main // empty' package.json 2>/dev/null)"
            fi
            if [ -n "$entry" ] && [ -e "$entry" ]; then
                local out
                out="$(npx --yes madge --circular "$entry" 2>/dev/null || true)"
                local cycles
                cycles="$(printf '%s\n' "$out" | grep -cE '^[0-9]+\)' || true)"
                score_by_cycles "$name" "$cycles" "$entry"
                return
            fi
        fi
    fi

    if has_tag python; then
        attempts+=("python: pydeps/pylint not attempted (tool unavailable)")
    fi
    if has_tag go; then
        attempts+=("go: cycle detection not implemented for go stack")
    fi

    axr_emit_criterion "structure.2" "$name" script 1 "tool unavailable — circular deps not checked" \
        "${attempts[@]:-no stack-specific tool available}"
}

score_by_cycles() {
    local name="$1" cycles="$2" entry="$3"
    if [ "$cycles" -eq 0 ]; then
        axr_emit_criterion "structure.2" "$name" script 3 "zero cycles detected" \
            "madge found 0 cycles in $entry"
    elif [ "$cycles" -le 2 ]; then
        axr_emit_criterion "structure.2" "$name" script 3 "$cycles cycle(s) detected" \
            "madge found $cycles cycle(s) in $entry"
    elif [ "$cycles" -le 5 ]; then
        axr_emit_criterion "structure.2" "$name" script 2 "$cycles cycle(s) detected" \
            "madge found $cycles cycle(s) in $entry"
    else
        axr_emit_criterion "structure.2" "$name" script 1 "$cycles cycle(s) detected" \
            "madge found $cycles cycle(s) in $entry"
    fi
}

# ---------------------------------------------------------------------------
# structure.5 — Dead code removed
# ---------------------------------------------------------------------------
score_structure_5() {
    local name
    name="$(axr_criterion_name structure.5)"

    # Count blocks of 5+ consecutive commented-out code-like lines.
    local blocks=0
    while IFS= read -r f; do
        local b
        b="$(awk '
            BEGIN { run=0; blocks=0 }
            /^[[:space:]]*[#\/]+[[:space:]]+(def |function |class |if |for |let |var |const |return |import )/ {
                run++
                if (run == 5) blocks++
                next
            }
            { run=0 }
            END { print blocks+0 }
        ' "$f" 2>/dev/null || echo 0)"
        blocks=$((blocks + b))
    done < <(find -P . -type f -not -type l \
        \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' \
           -o -name '*.rb' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.kt' \) \
        -not -path './node_modules/*' -not -path './.git/*' -not -path './.venv/*' \
        -not -path './venv/*' -not -path './.axr/*' -not -path './target/*' \
        -not -path './dist/*' -not -path './build/*' 2>/dev/null)

    local large_files=""
    while IFS= read -r f; do
        local lc
        lc="$(wc -l <"$f" 2>/dev/null | tr -d ' ')"
        if [ "$lc" -gt 1000 ]; then
            large_files="${large_files}${f}($lc),"
        fi
    done < <(find -P . -type f -not -type l \
        \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.rb' -o -name '*.go' \) \
        -not -path './node_modules/*' -not -path './.git/*' -not -path './.venv/*' \
        -not -path './.axr/*' 2>/dev/null | head -100)
    large_files="${large_files%,}"

    local ev=("$blocks commented-out code block(s) (5+ consecutive lines)")
    [ -n "$large_files" ] && ev+=("large files: $large_files")

    local score=4
    if [ "$blocks" -ge 11 ]; then score=1
    elif [ "$blocks" -ge 4 ]; then score=2
    elif [ "$blocks" -ge 1 ]; then score=3
    fi

    axr_emit_criterion "structure.5" "$name" script "$score" "dead-code evaluation" "${ev[@]}"
}

axr_defer_criterion "structure.1" "$(axr_criterion_name structure.1)" "deferred to Phase 3 judgment subagent"
score_structure_2
axr_defer_criterion "structure.3" "$(axr_criterion_name structure.3)" "deferred to Phase 3 judgment subagent"
axr_defer_criterion "structure.4" "$(axr_criterion_name structure.4)" "deferred to Phase 3 judgment subagent"
score_structure_5

axr_finalize_output
