#!/usr/bin/env bash
# scripts/check-docs-context.sh — deterministic checker for the docs_context
# dimension of the rq-axr rubric.
#
# Scores three mechanical criteria (.1, .2, .4). Defers .3 and .5 to judgment.
# Emits a single JSON object to stdout conforming to the schema documented in
# docs/plugin-brief.md.
#
# CWD must be the target repo root. The script sources scripts/lib/common.sh
# via its own directory (resolved from BASH_SOURCE). Criterion names are
# looked up from the rubric at runtime via axr_criterion_name — no hardcoded
# duplication.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_init_output docs_context "script:check-docs-context.sh"

# ---------------------------------------------------------------------------
# sanitize_evidence <string> — strip NUL + non-printable ASCII control chars
# from text extracted from target-repo files before embedding in evidence.
# Preserves tab (0x09), newline (0x0A), carriage return (0x0D).
# ---------------------------------------------------------------------------
sanitize_evidence() {
    printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037'
}

# ---------------------------------------------------------------------------
# count_h2_outside_fences <file> — count lines matching `^## ` that are NOT
# inside a fenced code block. Used for entry counts / title extraction in
# markdown files (avoids counting fenced code-sample headings).
# Prints the count to stdout. If <pattern> is provided as second arg, prints
# matching headings instead of the count.
# ---------------------------------------------------------------------------
count_h2_outside_fences() {
    local file="$1"
    awk '
        BEGIN { in_fence=0; count=0 }
        /^[[:space:]]*```/ { in_fence = !in_fence; next }
        in_fence == 1 { next }
        /^## / { count++ }
        END { print count }
    ' "$file"
}

# titles_h2_outside_fences <file> — print the first N headings outside fences.
titles_h2_outside_fences() {
    local file="$1"
    local limit="${2:-3}"
    awk -v limit="$limit" '
        BEGIN { in_fence=0; seen=0 }
        /^[[:space:]]*```/ { in_fence = !in_fence; next }
        in_fence == 1 { next }
        /^## / {
            sub(/^## +/, "")
            print
            seen++
            if (seen >= limit) exit
        }
    ' "$file"
}

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
        axr_emit_criterion "docs_context.1" "$name" 0 "no agent-context file found"
        return
    fi

    local bytes
    bytes="$(wc -c <"$found" | tr -d ' ')"
    if [ "$bytes" -lt 500 ]; then
        axr_emit_criterion "docs_context.1" "$name" 1 "below 500-byte threshold" \
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
        axr_emit_criterion "docs_context.1" "$name" 2 "no agent-oriented sections matched" \
            "$found ($bytes bytes, $sections sections, no agent-oriented sections)"
    elif [ "$matched_count" -le 2 ]; then
        axr_emit_criterion "docs_context.1" "$name" 2 "partial agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    else
        axr_emit_criterion "docs_context.1" "$name" 3 "strong agent-oriented coverage" \
            "$found ($bytes bytes, $sections sections)" \
            "matched: $matched"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.2 — README setup section with ≤5 commands.
#
# Fence handling:
#   - Shell fences (```bash|sh|shell|console|zsh) contribute their non-blank
#     body lines to the command count.
#   - Non-shell fences (bare ``` or ```text, ```output, etc.) are skipped —
#     lines inside them are NOT counted even if prefixed with $ or >.
#   - Outside any fence, lines matching `^[[:space:]]*[$>] ` are counted as
#     inline commands.
#   - H2 headings inside any fence are treated as fence content (NOT as
#     section boundaries) so fenced code samples containing `## ` do not
#     prematurely exit the setup section.
# ---------------------------------------------------------------------------
count_setup_commands() {
    local file="$1"
    awk '
        BEGIN {
            in_setup=0
            in_shell_fence=0
            in_nonshell_fence=0
            count=0
        }
        /^[[:space:]]*```/ {
            if (in_shell_fence) { in_shell_fence=0; next }
            if (in_nonshell_fence) { in_nonshell_fence=0; next }
            if (match($0, /^[[:space:]]*```(bash|sh|shell|console|zsh)([[:space:]]|$)/)) {
                in_shell_fence=1
            } else {
                in_nonshell_fence=1
            }
            next
        }
        /^## / {
            if (in_shell_fence || in_nonshell_fence) {
                # Fence content — count according to fence-state rules below.
            } else {
                if (in_setup && !match(tolower($0), /setup|getting started|quickstart|install|development/)) {
                    exit
                }
                if (match(tolower($0), /setup|getting started|quickstart|install|development/)) {
                    in_setup=1
                    next
                }
                next
            }
        }
        in_setup == 0 { next }
        in_shell_fence == 1 {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line == "") next
            count++
            next
        }
        in_nonshell_fence == 1 { next }
        /^[[:space:]]*[\$>] / { count++ }
        END { print count }
    ' "$file"
}

score_docs_context_2() {
    local name
    name="$(axr_criterion_name docs_context.2)"

    if [ ! -f README.md ]; then
        axr_emit_criterion "docs_context.2" "$name" 0 "README.md missing"
        return
    fi

    if ! grep -iEq '^## .*(setup|getting started|quickstart|install|development)' README.md; then
        axr_emit_criterion "docs_context.2" "$name" 1 "no setup section in README" \
            "README.md present but no setup section found"
        return
    fi

    local n
    n="$(count_setup_commands README.md)"
    if [ "$n" -eq 0 ]; then
        axr_emit_criterion "docs_context.2" "$name" 1 "setup section has no commands" \
            "README.md setup section: 0 commands"
    elif [ "$n" -le 5 ]; then
        axr_emit_criterion "docs_context.2" "$name" 3 "setup section within budget" \
            "README.md setup section: $n commands"
    elif [ "$n" -le 10 ]; then
        axr_emit_criterion "docs_context.2" "$name" 2 "setup section exceeds 5" \
            "README.md setup section: $n commands (exceeds 5)"
    else
        axr_emit_criterion "docs_context.2" "$name" 1 "setup section significantly exceeds 5" \
            "README.md setup section: $n commands (significantly exceeds 5)"
    fi
}

# ---------------------------------------------------------------------------
# docs_context.4 — ADRs / decision log.
# ---------------------------------------------------------------------------
first_three_titles() {
    local file="$1"
    local raw
    raw="$(titles_h2_outside_fences "$file" 3 | tr '\n' '|' | sed 's/|$//' || true)"
    sanitize_evidence "$raw"
}

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
        axr_emit_criterion "docs_context.4" "$name" 0 "no decision log found"
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
            axr_emit_criterion "docs_context.4" "$name" 0 "ADR directory exists but is empty" \
                "$found_dir (0 ADR files)"
        elif [ "$md_count" -le 2 ]; then
            axr_emit_criterion "docs_context.4" "$name" 2 "sparse ADR directory" \
                "$found_dir ($md_count ADR files)" "sample: $sample"
        elif [ "$md_count" -le 9 ]; then
            axr_emit_criterion "docs_context.4" "$name" 3 "established ADR directory" \
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
                axr_emit_criterion "docs_context.4" "$name" 4 "mature ADR directory with full structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample" \
                    "all ADRs include Consequences or Context heading"
            else
                axr_emit_criterion "docs_context.4" "$name" 3 "large ADR directory, inconsistent structure" \
                    "$found_dir ($md_count ADR files)" "sample: $sample"
            fi
        fi
        return
    fi

    # Single-file decision log path — count H2 entries outside fences.
    local entries
    entries="$(count_h2_outside_fences "$found_file")"
    local sample_titles
    sample_titles="$(first_three_titles "$found_file")"
    if [ "$entries" -lt 3 ]; then
        axr_emit_criterion "docs_context.4" "$name" 1 "decision log has <3 entries" \
            "$found_file ($entries entries)" "sample: $sample_titles"
    else
        axr_emit_criterion "docs_context.4" "$name" 2 "single-file decision log with 3+ entries" \
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
