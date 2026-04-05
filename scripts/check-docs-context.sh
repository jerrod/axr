#!/usr/bin/env bash
# scripts/check-docs-context.sh — deterministic checker for the docs_context
# dimension of the axr rubric.
#
# Scores three mechanical criteria (.1, .2, .4). Defers .3 and .5 to judgment.
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
# shellcheck source=lib/markdown-helpers.sh
source "$SCRIPT_DIR/lib/markdown-helpers.sh"

axr_init_output docs_context "script:check-docs-context.sh"

# ---------------------------------------------------------------------------
# docs_context.1 — Root CLAUDE.md / AGENTS.md with agent-oriented sections.
# ---------------------------------------------------------------------------
score_docs_context_1() {
    local name
    name="$(axr_criterion_name docs_context.1)"

    local candidates=(CLAUDE.md AGENTS.md .claude/CLAUDE.md .agents/AGENTS.md)
    local found=""
    local p
    for p in "${candidates[@]}"; do
        if [ -f "$p" ]; then
            found="$p"
            break
        fi
    done

    if [ -z "$found" ]; then
        axr_emit_criterion "docs_context.1" "$name" script 0 "no agent-context file found"
        return
    fi

    local bytes
    bytes="$(wc -c <"$found" | tr -d ' ')"
    if [ "$bytes" -lt 500 ]; then
        axr_emit_criterion "docs_context.1" "$name" script 1 "below 500-byte threshold" \
            "$found ($bytes bytes, below 500-byte threshold)"
        return
    fi

    # sections is included in evidence strings only (not used for scoring).
    local sections
    sections="$(grep -cE '^#{2,3} ' "$found" || true)"

    local keyword_re='architecture|convention|gotcha|sharp edge|rule|workflow|testing|tooling|environment'
    local matched
    matched="$(grep -iE "^#{2,3} .*($keyword_re)" "$found" \
               | sed -E 's/^#+ +//' | tr '\n' '|' | sed 's/|$//' || true)"
    matched="$(sanitize_evidence "$matched")"
    local matched_count=0
    if [ -n "$matched" ]; then
        matched_count="$(awk -F'|' '{print NF}' <<<"$matched")"
    fi

    if [ "$matched_count" -eq 0 ]; then
        axr_emit_criterion "docs_context.1" "$name" script 2 "no agent-oriented sections matched" \
            "$found ($bytes bytes, $sections sections, no agent-oriented sections)"
    elif [ "$matched_count" -le 2 ]; then
        axr_emit_criterion "docs_context.1" "$name" script 2 "partial agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    else
        axr_emit_criterion "docs_context.1" "$name" script 3 "strong agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.2 — README setup section with ≤5 commands.
# ---------------------------------------------------------------------------
score_docs_context_2() {
    local name
    name="$(axr_criterion_name docs_context.2)"

    if [ ! -f README.md ]; then
        axr_emit_criterion "docs_context.2" "$name" script 0 "README.md missing"
        return
    fi

    if ! grep -iEq '^## .*(setup|getting started|quickstart|install|development)' README.md; then
        axr_emit_criterion "docs_context.2" "$name" script 1 "no setup section in README" \
            "README.md present but no setup section found"
        return
    fi

    local n
    n="$(count_setup_commands README.md)"
    if [ "$n" -eq 0 ]; then
        axr_emit_criterion "docs_context.2" "$name" script 1 "setup section has no commands" \
            "README.md setup section: 0 commands"
    elif [ "$n" -le 5 ]; then
        axr_emit_criterion "docs_context.2" "$name" script 3 "setup section within budget" \
            "README.md setup section: $n commands"
    elif [ "$n" -le 10 ]; then
        axr_emit_criterion "docs_context.2" "$name" script 2 "setup section exceeds 5" \
            "README.md setup section: $n commands (exceeds 5)"
    else
        axr_emit_criterion "docs_context.2" "$name" script 1 "setup section significantly exceeds 5" \
            "README.md setup section: $n commands (significantly exceeds 5)"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.4 — ADRs / decision log.
# ---------------------------------------------------------------------------
score_docs_context_4() {
    local name
    name="$(axr_criterion_name docs_context.4)"

    local adr_dirs=(docs/adr docs/adrs docs/decisions docs/architecture/decisions adr decisions architecture/decisions)
    local adr_files=(DECISIONS.md docs/DECISIONS.md)

    local found_dir=""
    local d
    for d in "${adr_dirs[@]}"; do
        if [ -d "$d" ]; then
            found_dir="$d"
            break
        fi
    done

    local found_file=""
    local f
    for f in "${adr_files[@]}"; do
        if [ -f "$f" ]; then
            found_file="$f"
            break
        fi
    done

    if [ -z "$found_dir" ] && [ -z "$found_file" ]; then
        axr_emit_criterion "docs_context.4" "$name" script 0 "no decision log found"
        return
    fi

    if [ -n "$found_dir" ]; then
        # Capture file list ONCE, sorted for determinism, excluding symlinks.
        local adr_list=()
        while IFS= read -r line; do
            adr_list+=("$line")
        done < <(find -P "$found_dir" -maxdepth 1 -type f -not -type l -name '*.md' | sort)

        local md_count="${#adr_list[@]}"
        local sample=""
        if [ "$md_count" -gt 0 ]; then
            sample="$(printf '%s\n' "${adr_list[@]}" | head -n3 | tr '\n' '|' | sed 's/|$//')"
            sample="$(sanitize_evidence "$sample")"
        fi

        if [ "$md_count" -eq 0 ]; then
            axr_emit_criterion "docs_context.4" "$name" script 0 "ADR directory exists but is empty" \
                "$found_dir (0 ADR files)"
        elif [ "$md_count" -le 2 ]; then
            axr_emit_criterion "docs_context.4" "$name" script 2 "sparse ADR directory" \
                "$found_dir ($md_count ADR files)" "sample: $sample"
        elif [ "$md_count" -le 9 ]; then
            axr_emit_criterion "docs_context.4" "$name" script 3 "established ADR directory" \
                "$found_dir ($md_count ADR files)" "sample: $sample"
        else
            # Check every ADR has Consequences or Context heading.
            local full_structure=1
            local adr
            for adr in "${adr_list[@]}"; do
                if ! grep -Eq '^#+ +(Consequences|Context)' "$adr"; then
                    full_structure=0
                    break
                fi
            done
            if [ "$full_structure" = "1" ]; then
                axr_emit_criterion "docs_context.4" "$name" script 4 "mature ADR directory with full structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample" \
                    "all ADRs include Consequences or Context heading"
            else
                axr_emit_criterion "docs_context.4" "$name" script 3 "large ADR directory, inconsistent structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample"
            fi
        fi
        return
    fi

    # Single-file decision log path — count H2 entries outside fences.
    local entries
    entries="$(count_h2_outside_fences "$found_file")"
    local sample_titles
    sample_titles="$(first_three_titles_joined "$found_file")"
    if [ "$entries" -lt 3 ]; then
        axr_emit_criterion "docs_context.4" "$name" script 1 "decision log has <3 entries" \
            "$found_file ($entries entries)" "sample: $sample_titles"
    else
        axr_emit_criterion "docs_context.4" "$name" script 2 "single-file decision log with 3+ entries" \
            "$found_file ($entries entries)" "sample: $sample_titles"
    fi
}

# ---------------------------------------------------------------------------
# Run all four scoring steps, then emit JSON.
# ---------------------------------------------------------------------------
score_docs_context_1
score_docs_context_2
axr_defer_criterion "docs_context.3" "$(axr_criterion_name docs_context.3)" "Deferred to judgment subagent (docs-reviewer)"
score_docs_context_4
axr_defer_criterion "docs_context.5" "$(axr_criterion_name docs_context.5)" "Deferred to judgment subagent (docs-reviewer)"

axr_finalize_output
