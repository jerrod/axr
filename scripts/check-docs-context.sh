#!/usr/bin/env bash
# scripts/check-docs-context.sh — deterministic checker for the docs_context
# dimension of the rq-axr rubric.
#
# Scores three mechanical criteria (.1, .2, .4). Defers .3 and .5 to judgment.
# Emits a single JSON object to stdout conforming to the schema documented in
# docs/plugin-brief.md.
#
# CWD must be the target repo root. The script sources scripts/lib/common.sh
# via CLAUDE_PLUGIN_ROOT (if set) or by resolving its own directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_init_output docs_context "script:check-docs-context.sh"

# ---------------------------------------------------------------------------
# docs_context.1 — Root CLAUDE.md / AGENTS.md with agent-oriented sections.
# ---------------------------------------------------------------------------
score_docs_context_1() {
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
        axr_emit_criterion "docs_context.1" 0 "no agent-context file found"
        return
    fi

    local bytes
    bytes="$(wc -c <"$found" | tr -d ' ')"
    if [ "$bytes" -lt 500 ]; then
        axr_emit_criterion "docs_context.1" 1 "below 500-byte threshold" \
            "$found ($bytes bytes, below 500-byte threshold)"
        return
    fi

    local sections
    sections="$(grep -cE '^#{2,3} ' "$found" || true)"

    local keyword_re='architecture|convention|gotcha|sharp edge|rule|workflow|testing|tooling|environment'
    local matched
    matched="$(grep -iE "^#{2,3} .*($keyword_re)" "$found" \
               | sed -E 's/^#+ +//' | tr '\n' '|' | sed 's/|$//' || true)"
    local matched_count=0
    if [ -n "$matched" ]; then
        matched_count="$(awk -F'|' '{print NF}' <<<"$matched")"
    fi

    if [ "$matched_count" -eq 0 ]; then
        axr_emit_criterion "docs_context.1" 2 "no agent-oriented sections matched" \
            "$found ($bytes bytes, $sections sections, no agent-oriented sections)"
    elif [ "$matched_count" -le 2 ]; then
        axr_emit_criterion "docs_context.1" 2 "partial agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    else
        axr_emit_criterion "docs_context.1" 3 "strong agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.2 — README setup section with ≤5 commands.
# ---------------------------------------------------------------------------
count_setup_commands() {
    local file="$1"
    awk '
        BEGIN { in_setup=0; in_fence=0; count=0 }
        /^## / {
            if (in_setup && !match(tolower($0), /setup|getting started|quickstart|install|development/)) {
                # left the setup section
                exit
            }
            if (match(tolower($0), /setup|getting started|quickstart|install|development/)) {
                in_setup=1
                next
            }
        }
        in_setup == 0 { next }
        /^```/ {
            if (in_fence) { in_fence=0 } else {
                if (match($0, /^```(bash|sh|shell|console|zsh)/)) { in_fence=1 } else { in_fence=0 }
            }
            next
        }
        in_fence == 1 {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line == "") next
            count++
            next
        }
        # outside fences — treat $/> prefixed lines as commands too
        /^[[:space:]]*[\$>] / { count++ }
        END { print count }
    ' "$file"
}

score_docs_context_2() {
    if [ ! -f README.md ]; then
        axr_emit_criterion "docs_context.2" 0 "README.md missing"
        return
    fi

    if ! grep -iEq '^## .*(setup|getting started|quickstart|install|development)' README.md; then
        axr_emit_criterion "docs_context.2" 1 "no setup section in README" \
            "README.md present but no setup section found"
        return
    fi

    local n
    n="$(count_setup_commands README.md)"
    if [ "$n" -eq 0 ]; then
        axr_emit_criterion "docs_context.2" 1 "setup section has no commands" \
            "README.md setup section: 0 commands"
    elif [ "$n" -le 5 ]; then
        axr_emit_criterion "docs_context.2" 3 "setup section within budget" \
            "README.md setup section: $n commands"
    elif [ "$n" -le 10 ]; then
        axr_emit_criterion "docs_context.2" 2 "setup section exceeds 5" \
            "README.md setup section: $n commands (exceeds 5)"
    else
        axr_emit_criterion "docs_context.2" 1 "setup section significantly exceeds 5" \
            "README.md setup section: $n commands (significantly exceeds 5)"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.4 — ADRs / decision log.
# ---------------------------------------------------------------------------
first_three_titles() {
    local file="$1"
    grep -E '^## ' "$file" | head -n3 | sed -E 's/^## +//' | tr '\n' '|' | sed 's/|$//'
}

score_docs_context_4() {
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
        axr_emit_criterion "docs_context.4" 0 "no decision log found"
        return
    fi

    if [ -n "$found_dir" ]; then
        local md_count
        md_count="$(find "$found_dir" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
        local sample=""
        if [ "$md_count" -gt 0 ]; then
            sample="$(find "$found_dir" -maxdepth 1 -type f -name '*.md' | head -n3 | tr '\n' '|' | sed 's/|$//')"
        fi

        if [ "$md_count" -le 2 ]; then
            axr_emit_criterion "docs_context.4" 2 "sparse ADR directory" \
                "$found_dir ($md_count ADR files)" "sample: $sample"
        elif [ "$md_count" -le 9 ]; then
            axr_emit_criterion "docs_context.4" 3 "established ADR directory" \
                "$found_dir ($md_count ADR files)" "sample: $sample"
        else
            # Check every ADR has Consequences or Context heading
            local complete=1
            while IFS= read -r adr; do
                if ! grep -Eq '^#+ +(Consequences|Context)' "$adr"; then
                    complete=0
                    break
                fi
            done < <(find "$found_dir" -maxdepth 1 -type f -name '*.md')
            if [ "$complete" = "1" ]; then
                axr_emit_criterion "docs_context.4" 4 "mature ADR directory with full structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample" \
                    "all ADRs include Consequences or Context heading"
            else
                axr_emit_criterion "docs_context.4" 3 "large ADR directory, inconsistent structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample"
            fi
        fi
        return
    fi

    # Single-file decision log path.
    local entries
    entries="$(grep -cE '^## ' "$found_file" || true)"
    local sample_titles
    sample_titles="$(first_three_titles "$found_file")"
    if [ "$entries" -lt 3 ]; then
        axr_emit_criterion "docs_context.4" 1 "decision log has <3 entries" \
            "$found_file ($entries entries)" "sample: $sample_titles"
    else
        axr_emit_criterion "docs_context.4" 2 "single-file decision log with 3+ entries" \
            "$found_file ($entries entries)" "sample: $sample_titles"
    fi
}

# ---------------------------------------------------------------------------
# Run all four scoring steps, then emit JSON.
# ---------------------------------------------------------------------------
score_docs_context_1
score_docs_context_2
axr_defer_criterion "docs_context.3" "Deferred to judgment subagent (docs-reviewer)"
score_docs_context_4
axr_defer_criterion "docs_context.5" "Deferred to judgment subagent (docs-reviewer)"

axr_finalize_output
