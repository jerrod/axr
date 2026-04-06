#!/usr/bin/env bash
# scripts/check-patterns.sh — deterministic checker for patterns.
# Scores 2 mechanical criteria (.1, .4). Defers .2, .3, .5 to judgment.

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

axr_package_scope "$@"
axr_init_output patterns "script:check-patterns.sh"

# ---------------------------------------------------------------------------
# patterns.duplication-scanning — Duplication scanning configured
# ---------------------------------------------------------------------------
score_patterns_1() {
    local name
    name="$(axr_criterion_name patterns.duplication-scanning)"

    local has_local=0 has_ci=0
    local ev=()

    # Local config files
    if [ -f .jscpd.json ]; then
        has_local=1
        ev+=(".jscpd.json present")
    fi
    if [ -f .cpd-config.xml ]; then
        has_local=1
        ev+=(".cpd-config.xml present")
    fi
    if [ -f sonar-project.properties ]; then
        if grep -qE '(sonar\.cpd|duplicat)' sonar-project.properties 2>/dev/null; then
            has_local=1
            ev+=("sonar-project.properties with duplication settings")
        fi
    fi

    # CI workflow steps referencing jscpd or cpd
    if [ -d .github/workflows ]; then
        local ci_match=""
        ci_match="$(extract_workflow_run_lines | grep -iE '(jscpd|cpd|duplication)' | head -3)" || true
        if [ -n "$ci_match" ]; then
            has_ci=1
            ev+=("CI step references duplication tool")
        fi
    fi

    local score=0
    if [ "$has_ci" = "1" ]; then
        score=3
    elif [ "$has_local" = "1" ]; then
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "patterns.duplication-scanning" "$name" script 0 \
            "no duplication scanning config found"
    else
        axr_emit_criterion "patterns.duplication-scanning" "$name" script "$score" \
            "duplication scanning configured" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# patterns.import-depth — Shallow import depth
# ---------------------------------------------------------------------------
score_patterns_4() {
    local name
    name="$(axr_criterion_name patterns.import-depth)"

    local total_depth=0
    local count=0

    # Python: from a.b.c.d import X → depth = number of dots
    local py_imports=""
    py_imports="$(find -P . -type f -not -type l -name '*.py' \
        -not -path './node_modules/*' -not -path './.git/*' \
        -not -path './.venv/*' -not -path './venv/*' \
        -not -path './.axr/*' 2>/dev/null \
        | head -200 \
        | xargs grep -hE '^from [a-zA-Z0-9_.]+' 2>/dev/null \
        | sed -n 's/^from \([a-zA-Z0-9_.]*\).*/\1/p' \
        | head -500)" || true

    if [ -n "$py_imports" ]; then
        while IFS= read -r mod; do
            local dots
            dots="$(printf '%s' "$mod" | tr -cd '.' | wc -c | tr -d ' ')"
            total_depth=$((total_depth + dots))
            count=$((count + 1))
        done <<< "$py_imports"
    fi

    # Node: require('../../../..') or from '../../../..'
    local node_imports=""
    node_imports="$(find -P . -type f -not -type l \
        \( -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.mjs' \) \
        -not -path './node_modules/*' -not -path './.git/*' \
        -not -path './dist/*' -not -path './build/*' \
        -not -path './.axr/*' 2>/dev/null \
        | head -200 \
        | xargs grep -hEo "(require|from)\s*\(?['\"](\.\./[^'\"]*)['\"]" 2>/dev/null \
        | grep -oE '\.\./[^"'"'"']*' \
        | head -500)" || true

    if [ -n "$node_imports" ]; then
        while IFS= read -r imp; do
            local hops
            hops="$(printf '%s' "$imp" | grep -o '\.\.' | wc -l | tr -d ' ')"
            total_depth=$((total_depth + hops))
            count=$((count + 1))
        done <<< "$node_imports"
    fi

    # Go: import "github.com/org/repo/pkg/sub/deep" — count / segments after domain
    local go_imports=""
    go_imports="$(find -P . -type f -not -type l -name '*.go' \
        -not -path './vendor/*' -not -path './.git/*' \
        -not -path './.axr/*' 2>/dev/null \
        | head -200 \
        | xargs grep -hE '^\s*"[a-zA-Z0-9.]' 2>/dev/null \
        | sed -n 's/.*"\([^"]*\)".*/\1/p' \
        | head -500)" || true

    if [ -n "$go_imports" ]; then
        while IFS= read -r imp; do
            local segs
            segs="$(printf '%s' "$imp" | tr '/' '\n' | wc -l | tr -d ' ')"
            # depth = segments - 1 (the domain itself is 0)
            local depth=$((segs > 1 ? segs - 1 : 0))
            total_depth=$((total_depth + depth))
            count=$((count + 1))
        done <<< "$go_imports"
    fi

    if [ "$count" -eq 0 ]; then
        axr_emit_criterion "patterns.import-depth" "$name" script 2 \
            "no import statements sampled (likely simple project)" \
            "no .py/.js/.ts/.go files with imports found"
        return
    fi

    local avg=$((total_depth / count))
    local ev=("sampled $count imports" "average depth: $avg")

    local score=0
    if [ "$avg" -le 2 ]; then
        score=3
    elif [ "$avg" -le 3 ]; then
        score=2
    elif [ "$avg" -le 5 ]; then
        score=1
    fi

    axr_emit_criterion "patterns.import-depth" "$name" script "$score" \
        "average import depth $avg across $count samples" "${ev[@]}"
}

score_patterns_1
axr_defer_criterion "patterns.single-approach" \
    "$(axr_criterion_name patterns.single-approach)" \
    "Deferred to judgment subagent (patterns-reviewer)"
axr_defer_criterion "patterns.no-competing-patterns" \
    "$(axr_criterion_name patterns.no-competing-patterns)" \
    "Deferred to judgment subagent (patterns-reviewer)"
score_patterns_4
axr_defer_criterion "patterns.error-consistency" \
    "$(axr_criterion_name patterns.error-consistency)" \
    "Deferred to judgment subagent (patterns-reviewer)"

axr_finalize_output
