#!/usr/bin/env bash
# scripts/lib/workflow-helpers.sh — GitHub Actions workflow parsers shared
# across dimension checkers (check-tooling, check-tests-ci,
# check-execution-visibility, check-safety-rails).
#
# Sourced by checker scripts that inspect .github/workflows/*.yml files.
# Pure functions — take no shell-global state, output to stdout.

# ---------------------------------------------------------------------------
# extract_workflow_run_lines — print the command body of every `run:` step
# across all .github/workflows/*.yml files to stdout. Prefers `yq` if
# available; otherwise uses an awk-based parser that handles block-scalar
# continuations (| and > with optional chomp/indent modifiers).
# ---------------------------------------------------------------------------
extract_workflow_run_lines() {
    local files=()
    while IFS= read -r line; do
        files+=("$line")
    done < <(find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
    [ "${#files[@]}" -eq 0 ] && return 0

    if command -v yq >/dev/null 2>&1; then
        local f
        for f in "${files[@]}"; do
            yq e '.. | select(has("run")) | .run' "$f" 2>/dev/null || true
        done
        return 0
    fi

    # awk fallback: extract values after "run:" keys, including block-scalar
    # (| or >) continuations. Normalize to single lines.
    local f
    for f in "${files[@]}"; do
        awk '
            BEGIN { in_block=0; base_indent=-1 }
            {
                line=$0
                if (in_block) {
                    match(line, /^[[:space:]]*/)
                    lead=RLENGTH
                    if (line ~ /^[[:space:]]*$/) { print ""; next }
                    if (base_indent < 0) base_indent=lead
                    if (lead >= base_indent) { print substr(line, base_indent+1); next }
                    # Block ended — fall through so this line can still be
                    # evaluated as a new run: directive.
                    in_block=0; base_indent=-1
                }
                if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>][-+]?[[:space:]]*$/)) {
                    in_block=1; base_indent=-1; next
                }
                if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]+/)) {
                    val=substr(line, RSTART+RLENGTH)
                    gsub(/^["'\'']/, "", val)
                    gsub(/["'\'']$/, "", val)
                    print val
                }
            }
        ' "$f"
    done
}

# ---------------------------------------------------------------------------
# workflow_files — print paths of all .github/workflows/*.yml files, sorted.
# Safe when the directory does not exist (prints nothing).
# ---------------------------------------------------------------------------
workflow_files() {
    find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
}
