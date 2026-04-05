#!/usr/bin/env bash
# scripts/lib/markdown-helpers.sh — fence-aware markdown parsing helpers for
# AXR dimension checker scripts.
#
# Parsers here know how to read headings, fenced code blocks, and setup
# sections from README/CLAUDE/DECISIONS files while respecting triple-backtick
# fences. Extracted from check-docs-context.sh so that future dimension
# checkers (docs_context is unlikely to be the only markdown-reading checker)
# can reuse the same logic.
#
# All functions are pure — they take a filename and emit text or integers to
# stdout. They do not source common.sh and do not emit AXR JSON.

# ---------------------------------------------------------------------------
# sanitize_evidence <string> — strip NUL + non-printable ASCII control chars
# from text extracted from target-repo files before embedding in evidence.
# Preserves tab (0x09), newline (0x0A), carriage return (0x0D).
# Also strips { and } so target-repo content cannot inject {{template_token}}
# strings that would trigger infinite substitution loops in aggregate.sh's
# report renderer.
# ---------------------------------------------------------------------------
sanitize_evidence() {
    printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037{}'
}

# ---------------------------------------------------------------------------
# count_h2_outside_fences <file> — count lines matching `^## ` that are NOT
# inside a fenced code block. Prints the count to stdout.
# ---------------------------------------------------------------------------
count_h2_outside_fences() {
    local file="$1"
    awk '
        BEGIN { in_fence=0; count=0 }
        /^[[:space:]]*```/ { in_fence = !in_fence; next }
        in_fence { next }
        /^## / { count++ }
        END { print count }
    ' "$file"
}

# ---------------------------------------------------------------------------
# titles_h2_outside_fences <file> [<limit>] — print the first N H2 headings
# that appear outside fenced code blocks. Default limit: 3.
# ---------------------------------------------------------------------------
titles_h2_outside_fences() {
    local file="$1"
    local limit="${2:-3}"
    awk -v limit="$limit" '
        BEGIN { in_fence=0; seen=0 }
        /^[[:space:]]*```/ { in_fence = !in_fence; next }
        in_fence { next }
        /^## / {
            sub(/^## +/, "")
            print
            seen++
            if (seen >= limit) exit
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# count_setup_commands <file> — count shell commands in a README setup
# section. Returns the count to stdout.
#
# Fence handling:
#   - Shell fences (```bash|sh|shell|console|zsh) contribute their non-blank
#     body lines to the command count.
#   - Non-shell fences (bare ``` or ```text, ```output, etc.) are skipped —
#     lines inside them are NOT counted even if prefixed with $ or >.
#   - Outside any fence, lines matching `^[[:space:]]*[$>] ` are counted.
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
            # Skip any line that starts with #. This covers both bash
            # comments (# install deps) and markdown headings that wandered
            # into a fence (## heading). Trailing-comment lines like
            # `npm install # note` still count because they do not start
            # with #.
            if (line ~ /^#/) next
            count++
            next
        }
        in_nonshell_fence == 1 { next }
        /^[[:space:]]*[\$>] / { count++ }
        END { print count }
    ' "$file"
}

# ---------------------------------------------------------------------------
# first_three_titles_joined <file> — pipe-joined sanitized titles from
# titles_h2_outside_fences, for compact evidence strings.
# ---------------------------------------------------------------------------
first_three_titles_joined() {
    local file="$1"
    local raw
    raw="$(titles_h2_outside_fences "$file" 3 | tr '\n' '|' | sed 's/|$//' || true)"
    sanitize_evidence "$raw"
}
