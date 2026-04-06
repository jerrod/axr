#!/usr/bin/env bash
# scripts/check-legibility.sh — deterministic checker for the legibility
# dimension of the axr rubric.
#
# Scores four mechanical criteria (.1–.4). Defers .5 to judgment.
# Emits a single JSON object to stdout conforming to the schema documented in
# docs/plugin-brief.md.
#
# CWD must be the target repo root. Criterion names are looked up from the
# rubric at runtime via axr_criterion_name — no hardcoded duplication.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/tooling-helpers.sh
source "$SCRIPT_DIR/lib/tooling-helpers.sh"

axr_package_scope "$@"
axr_init_output legibility "script:check-legibility.sh"

# ---------------------------------------------------------------------------
# legibility.context-window-fit — Median source file LOC.
# ---------------------------------------------------------------------------
score_legibility_1() {
    local name
    name="$(axr_criterion_name legibility.context-window-fit)"

    local excludes=(-not -path '*/node_modules/*' -not -path '*/.git/*'
        -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/target/*'
        -not -path '*/venv/*' -not -path '*/__pycache__/*' -not -path '*/.next/*')

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find -P . -maxdepth 5 -type f -not -type l \
        \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' \
           -o -name '*.go' -o -name '*.rb' -o -name '*.kt' -o -name '*.java' \
           -o -name '*.sh' -o -name '*.rs' \) \
        "${excludes[@]}" 2>/dev/null | sort)

    if [ "${#files[@]}" -eq 0 ]; then
        axr_emit_criterion "legibility.context-window-fit" "$name" script 1 \
            "no source files found" "0 source files detected"
        return
    fi

    local counts=()
    local f
    for f in "${files[@]}"; do
        local lc
        lc="$(wc -l < "$f" | tr -d ' ')"
        counts+=("$lc")
    done

    # Sort numerically for median.
    local sorted
    sorted="$(printf '%s\n' "${counts[@]}" | sort -n)"
    local n="${#counts[@]}"
    local mid=$(( n / 2 ))
    local median
    median="$(sed -n "$((mid + 1))p" <<< "$sorted")"

    # Check for god-files (>1000 LOC).
    local god_count=0
    local c
    for c in "${counts[@]}"; do
        [ "$c" -gt 1000 ] && god_count=$((god_count + 1))
    done

    local evidence="$n source files, median $median LOC"
    [ "$god_count" -gt 0 ] && evidence="$evidence, $god_count files >1000 LOC"

    if [ "$median" -ge 500 ]; then
        axr_emit_criterion "legibility.context-window-fit" "$name" script 0 \
            "most files exceed 500 LOC" "$evidence"
    elif [ "$god_count" -gt 0 ]; then
        axr_emit_criterion "legibility.context-window-fit" "$name" script 1 \
            "median <500 but god-files exist" "$evidence"
    elif [ "$median" -lt 200 ]; then
        axr_emit_criterion "legibility.context-window-fit" "$name" script 3 \
            "median under 200 LOC" "$evidence"
    else
        axr_emit_criterion "legibility.context-window-fit" "$name" script 2 \
            "median under 300 LOC" "$evidence"
    fi
}

# ---------------------------------------------------------------------------
# legibility.tiered-context — Context tooling beyond root README.
# ---------------------------------------------------------------------------
score_legibility_2() {
    local name
    name="$(axr_criterion_name legibility.tiered-context)"

    local signals=0
    local found=()

    # .claude/context-map.md
    if [ -f .claude/context-map.md ]; then
        signals=$((signals + 1))
        found+=(".claude/context-map.md")
    fi

    # repomix config
    local rp
    for rp in .repomix.json repomix.config.json; do
        if [ -f "$rp" ]; then
            signals=$((signals + 1))
            found+=("$rp")
            break
        fi
    done

    # llm-tree config or output
    if compgen -G "*.llm-tree*" >/dev/null 2>&1 || compgen -G ".llm-tree*" >/dev/null 2>&1; then
        signals=$((signals + 1))
        found+=("llm-tree config/output")
    fi

    # Per-module .claude/ dirs (beyond root)
    local sub_claude
    sub_claude="$(find -P . -mindepth 2 -maxdepth 4 -type d -name '.claude' \
        -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -n5)"
    if [ -n "$sub_claude" ]; then
        signals=$((signals + 1))
        found+=("per-module .claude dirs")
    fi

    local evidence
    if [ "${#found[@]}" -gt 0 ]; then
        evidence="$(printf '%s, ' "${found[@]}" | sed 's/, $//')"
    else
        evidence="no context tooling detected"
    fi

    if [ "$signals" -eq 0 ]; then
        axr_emit_criterion "legibility.tiered-context" "$name" script 0 \
            "no context tooling found" "$evidence"
    elif [ "$signals" -eq 1 ]; then
        axr_emit_criterion "legibility.tiered-context" "$name" script 1 \
            "one context signal" "$evidence"
    elif [ "$signals" -eq 2 ]; then
        axr_emit_criterion "legibility.tiered-context" "$name" script 2 \
            "two context signals" "$evidence"
    else
        axr_emit_criterion "legibility.tiered-context" "$name" script 3 \
            "three or more context signals" "$evidence"
    fi
}

# ---------------------------------------------------------------------------
# legibility.instruction-consistency — Instruction file coherence.
# ---------------------------------------------------------------------------
score_legibility_3() {
    local name
    name="$(axr_criterion_name legibility.instruction-consistency)"

    local instruction_files=()
    local candidates=(CLAUDE.md AGENTS.md .cursorrules .github/copilot-instructions.md)
    local c
    for c in "${candidates[@]}"; do
        [ -f "$c" ] && instruction_files+=("$c")
    done

    local count="${#instruction_files[@]}"

    if [ "$count" -eq 0 ]; then
        axr_emit_criterion "legibility.instruction-consistency" "$name" script 0 \
            "no instruction files found" "checked: ${candidates[*]}"
        return
    fi

    local file_list
    file_list="$(printf '%s, ' "${instruction_files[@]}" | sed 's/, $//')"

    if [ "$count" -eq 1 ]; then
        axr_emit_criterion "legibility.instruction-consistency" "$name" script 2 \
            "single authoritative instruction file" "$file_list"
        return
    fi

    # Multiple files — check for cross-references.
    local cross_refs=0
    local f other base
    for f in "${instruction_files[@]}"; do
        for other in "${instruction_files[@]}"; do
            [ "$f" = "$other" ] && continue
            base="$(basename "$other")"
            if grep -ql "$base" "$f" 2>/dev/null; then
                cross_refs=$((cross_refs + 1))
                break
            fi
        done
    done

    if [ "$cross_refs" -gt 0 ]; then
        axr_emit_criterion "legibility.instruction-consistency" "$name" script 3 \
            "multiple instruction files with cross-references" \
            "$file_list ($cross_refs files reference others)"
    else
        axr_emit_criterion "legibility.instruction-consistency" "$name" script 1 \
            "multiple instruction files without cross-references" "$file_list"
    fi
}

# ---------------------------------------------------------------------------
# legibility.convention-enforced — Documented conventions backed by linting.
# ---------------------------------------------------------------------------
score_legibility_4() {
    local name
    name="$(axr_criterion_name legibility.convention-enforced)"

    local has_conventions=0
    if [ -f CLAUDE.md ]; then
        if grep -qiE 'convention|rule|standard|must|always|never' CLAUDE.md 2>/dev/null; then
            has_conventions=1
        fi
    fi

    local lint_configs
    lint_configs="$(list_lint_configs)"
    local has_lint=0
    [ -n "$lint_configs" ] && has_lint=1

    local lint_list=""
    [ -n "$lint_configs" ] && lint_list="$(echo "$lint_configs" | tr '\n' ', ' | sed 's/,$//')"

    if [ "$has_conventions" -eq 0 ] && [ "$has_lint" -eq 0 ]; then
        axr_emit_criterion "legibility.convention-enforced" "$name" script 0 \
            "no conventions documented or enforced" "no CLAUDE.md conventions, no lint config"
    elif [ "$has_conventions" -eq 1 ] && [ "$has_lint" -eq 0 ]; then
        axr_emit_criterion "legibility.convention-enforced" "$name" script 1 \
            "conventions documented but not enforced" "CLAUDE.md has convention keywords, no lint config"
    elif [ "$has_conventions" -eq 0 ] && [ "$has_lint" -eq 1 ]; then
        axr_emit_criterion "legibility.convention-enforced" "$name" script 2 \
            "standard linting without documented conventions" "lint config: $lint_list"
    else
        axr_emit_criterion "legibility.convention-enforced" "$name" script 3 \
            "conventions documented and enforced by linting" \
            "CLAUDE.md has convention keywords" "lint config: $lint_list"
    fi
}

# ---------------------------------------------------------------------------
# Run scoring functions, defer judgment, finalize.
# ---------------------------------------------------------------------------
score_legibility_1
score_legibility_2
score_legibility_3
score_legibility_4
axr_defer_criterion "legibility.decision-coverage" "$(axr_criterion_name legibility.decision-coverage)" "Deferred to judgment subagent (legibility-reviewer)"

axr_finalize_output
