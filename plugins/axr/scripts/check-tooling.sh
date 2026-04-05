#!/usr/bin/env bash
# scripts/check-tooling.sh — deterministic checker for the tooling dimension.
# Scores 5 mechanical criteria (.1 through .5). No judgment criteria.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_init_output tooling "script:check-tooling.sh"

STACK_JSON="$(axr_detect_stack)"
has_tag() {
    jq -e --arg t "$1" 'any(.[]; . == $t)' <<<"$STACK_JSON" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# extract_workflow_run_lines — print the command body of every `run:` step
# across all .github/workflows/*.yml files to stdout. awk-based fallback if
# yq is not available.
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
                    # determine leading spaces
                    match(line, /^[[:space:]]*/)
                    lead=RLENGTH
                    if (line ~ /^[[:space:]]*$/) { print ""; next }
                    if (base_indent < 0) base_indent=lead
                    if (lead < base_indent) { in_block=0; base_indent=-1 }
                    else { print substr(line, base_indent+1); next }
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
# tooling.1 — Type checker clean or baselined
# ---------------------------------------------------------------------------
score_tooling_1() {
    local name
    name="$(axr_criterion_name tooling.1)"

    local has_node=0 has_python=0
    has_tag node && has_node=1
    has_tag python && has_python=1

    if [ "$has_node" = "0" ] && [ "$has_python" = "0" ]; then
        axr_emit_criterion "tooling.1" "$name" script 4 "no type-checkable language" \
            "stack: $STACK_JSON"
        return
    fi

    local node_score=-1 py_score=-1
    local evidence=()

    if [ "$has_node" = "1" ]; then
        if [ -f tsconfig.json ]; then
            if jq -e '.compilerOptions.strict == true' tsconfig.json >/dev/null 2>&1; then
                node_score=3
                evidence+=("tsconfig.json with compilerOptions.strict=true")
            else
                node_score=2
                evidence+=("tsconfig.json present without strict mode")
            fi
        else
            local dts_count
            dts_count="$(find -P . -maxdepth 4 -type f -not -type l -name '*.d.ts' \
                -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
            if [ "$dts_count" -gt 0 ]; then
                node_score=1
                evidence+=("no tsconfig.json but $dts_count .d.ts files found")
            else
                node_score=0
                evidence+=("node stack but no tsconfig.json or .d.ts files")
            fi
        fi
    fi

    if [ "$has_python" = "1" ]; then
        local cfg=""
        if [ -f mypy.ini ]; then cfg="mypy.ini"
        elif [ -f .mypy.ini ]; then cfg=".mypy.ini"
        elif [ -f pyrightconfig.json ]; then cfg="pyrightconfig.json"
        elif [ -f pyproject.toml ] && grep -qE '^\[tool\.(mypy|pyright)\]' pyproject.toml 2>/dev/null; then
            cfg="pyproject.toml"
        fi

        if [ -z "$cfg" ]; then
            py_score=0
            evidence+=("python stack but no mypy/pyright config found")
        else
            if grep -qE '(strict[[:space:]]*=[[:space:]]*(true|True))|"strict"[[:space:]]*:[[:space:]]*true|strictMode' "$cfg" 2>/dev/null; then
                py_score=3
                evidence+=("$cfg with strict mode")
            else
                py_score=2
                evidence+=("$cfg present without strict mode")
            fi
        fi
    fi

    local final=-1
    if [ "$node_score" -ge 0 ] && [ "$py_score" -ge 0 ]; then
        final=$(( node_score < py_score ? node_score : py_score ))
    elif [ "$node_score" -ge 0 ]; then
        final=$node_score
    else
        final=$py_score
    fi

    axr_emit_criterion "tooling.1" "$name" script "$final" "type checker config evaluation" \
        "${evidence[@]}"
}

# ---------------------------------------------------------------------------
# tooling.2 — Linter and formatter in local + CI
# ---------------------------------------------------------------------------
score_tooling_2() {
    local name
    name="$(axr_criterion_name tooling.2)"

    local lint_found="" format_found=""
    local lint_configs=(.eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml .eslintrc.yaml
        .eslintrc.cjs biome.json .ruff.toml ruff.toml .rubocop.yml .golangci.yml
        .golangci.yaml .clippy.toml)
    local f
    for f in "${lint_configs[@]}"; do
        if [ -e "$f" ]; then lint_found="$f"; break; fi
    done
    if [ -z "$lint_found" ] && [ -f pyproject.toml ] && grep -qE '^\[tool\.(ruff|pylint)\]' pyproject.toml 2>/dev/null; then
        lint_found="pyproject.toml:[tool.ruff|pylint]"
    fi
    if [ -z "$lint_found" ] && [ -f .editorconfig ] && grep -qiE 'ktlint' .editorconfig 2>/dev/null; then
        lint_found=".editorconfig:ktlint"
    fi

    local fmt_configs=(.prettierrc .prettierrc.js .prettierrc.json .prettierrc.yml
        .prettierrc.yaml .prettierrc.cjs .editorconfig)
    for f in "${fmt_configs[@]}"; do
        if [ -e "$f" ]; then format_found="$f"; break; fi
    done
    if [ -z "$format_found" ] && [ -f pyproject.toml ] && grep -qE '^\[tool\.(black|isort)\]' pyproject.toml 2>/dev/null; then
        format_found="pyproject.toml:[tool.black|isort]"
    fi

    local ci_match=0 ci_tool=""
    local run_lines
    run_lines="$(extract_workflow_run_lines 2>/dev/null || true)"
    if [ -n "$run_lines" ]; then
        if printf '%s\n' "$run_lines" | grep -qE '\b(eslint|biome|ruff|pylint|rubocop|golangci|clippy|ktlint|prettier|black|isort|gofmt)\b'; then
            ci_match=1
            ci_tool="$(printf '%s\n' "$run_lines" | grep -oE '\b(eslint|biome|ruff|pylint|rubocop|golangci|clippy|ktlint|prettier|black|isort|gofmt)\b' | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')"
        fi
    fi

    local ev=()
    [ -n "$lint_found" ] && ev+=("lint config: $lint_found")
    [ -n "$format_found" ] && ev+=("format config: $format_found")
    [ "$ci_match" = "1" ] && ev+=("CI run-step matches: $ci_tool")

    local score=0
    if [ -z "$lint_found" ] && [ -z "$format_found" ]; then
        score=0
    elif [ -n "$lint_found" ] && [ -n "$format_found" ] && [ "$ci_match" = "1" ]; then
        score=3
    elif [ -n "$lint_found" ] && [ -n "$format_found" ]; then
        score=2
    else
        score=1
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tooling.2" "$name" script 0 "no lint or format config found"
    else
        axr_emit_criterion "tooling.2" "$name" script "$score" "lint/format config evaluation" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tooling.3 — Reproducible hermetic build
# ---------------------------------------------------------------------------
score_tooling_3() {
    local name
    name="$(axr_criterion_name tooling.3)"

    local lockfiles=(package-lock.json yarn.lock pnpm-lock.yaml poetry.lock uv.lock
        Pipfile.lock Gemfile.lock Cargo.lock go.sum composer.lock)
    local lockfound=""
    local f
    for f in "${lockfiles[@]}"; do
        if [ -f "$f" ]; then lockfound="${lockfound}${f},"; fi
    done
    lockfound="${lockfound%,}"

    local env_pins=(.tool-versions .nvmrc .python-version .ruby-version rust-toolchain
        rust-toolchain.toml)
    local envfound=""
    for f in "${env_pins[@]}"; do
        if [ -f "$f" ]; then envfound="${envfound}${f},"; fi
    done
    envfound="${envfound%,}"

    local container_found=""
    for f in Dockerfile .devcontainer/devcontainer.json flake.nix shell.nix nix.conf; do
        if [ -e "$f" ]; then container_found="${container_found}${f},"; fi
    done
    container_found="${container_found%,}"

    local ev=()
    [ -n "$lockfound" ] && ev+=("lockfiles: $lockfound")
    [ -n "$envfound" ] && ev+=("env pinning: $envfound")
    [ -n "$container_found" ] && ev+=("containerization: $container_found")

    local score=0
    if [ -z "$lockfound" ]; then
        score=0
    elif [ -n "$envfound" ] || [ -n "$container_found" ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tooling.3" "$name" script 0 "no lockfile found"
    else
        axr_emit_criterion "tooling.3" "$name" script "$score" "reproducibility signals" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tooling.4 — One-command bootstrap
# ---------------------------------------------------------------------------
score_tooling_4() {
    local name
    name="$(axr_criterion_name tooling.4)"

    local found="" executable=0
    local candidates=(bin/setup bin/bootstrap scripts/setup scripts/bootstrap)
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            found="$c"
            [ -x "$c" ] && executable=1
            break
        fi
    done

    if [ -z "$found" ] && [ -f Makefile ]; then
        if grep -qE '^(setup|dev|install|bootstrap):' Makefile 2>/dev/null; then
            found="Makefile:setup|dev|install|bootstrap target"
            executable=1
        fi
    fi
    if [ -z "$found" ] && [ -f package.json ]; then
        if jq -e '.scripts.setup // .scripts.bootstrap' package.json >/dev/null 2>&1; then
            found="package.json:scripts.setup|bootstrap"
            executable=1
        fi
    fi
    if [ -z "$found" ] && [ -f Justfile ]; then
        if grep -qE '^(setup|bootstrap|dev)[[:space:]]*:' Justfile 2>/dev/null; then
            found="Justfile:setup|bootstrap|dev recipe"
            executable=1
        fi
    fi

    if [ -z "$found" ]; then
        axr_emit_criterion "tooling.4" "$name" script 0 "no bootstrap script found"
    elif [ "$executable" = "1" ]; then
        axr_emit_criterion "tooling.4" "$name" script 3 "bootstrap present and executable" "$found"
    else
        axr_emit_criterion "tooling.4" "$name" script 2 "bootstrap present but not executable" "$found"
    fi
}

# ---------------------------------------------------------------------------
# tooling.5 — Pinned dependencies + upgrade path
# ---------------------------------------------------------------------------
score_tooling_5() {
    local name
    name="$(axr_criterion_name tooling.5)"

    local lockfiles=(package-lock.json yarn.lock pnpm-lock.yaml poetry.lock uv.lock
        Pipfile.lock Gemfile.lock Cargo.lock go.sum composer.lock)
    local lock_count=0
    local f
    for f in "${lockfiles[@]}"; do
        [ -f "$f" ] && lock_count=$((lock_count + 1))
    done

    local automation=""
    for f in renovate.json .github/renovate.json .renovaterc .renovaterc.json \
             .github/dependabot.yml .github/dependabot.yaml; do
        if [ -f "$f" ]; then automation="${automation}${f},"; fi
    done
    automation="${automation%,}"

    if [ -z "$automation" ]; then
        local wf_lines
        wf_lines="$(extract_workflow_run_lines 2>/dev/null || true)"
        if [ -n "$wf_lines" ] && printf '%s\n' "$wf_lines" | grep -qiE 'renovate|dependabot'; then
            automation="workflow references renovate/dependabot"
        fi
    fi

    local ev=()
    [ "$lock_count" -gt 0 ] && ev+=("$lock_count lockfile(s) present")
    [ -n "$automation" ] && ev+=("upgrade automation: $automation")

    local score=0
    if [ "$lock_count" -eq 0 ]; then
        score=0
    elif [ -n "$automation" ]; then
        score=3
    else
        score=1
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tooling.5" "$name" script 0 "no lockfile — cannot pin dependencies"
    else
        axr_emit_criterion "tooling.5" "$name" script "$score" "dependency pinning evaluation" "${ev[@]}"
    fi
}

score_tooling_1
score_tooling_2
score_tooling_3
score_tooling_4
score_tooling_5

axr_finalize_output
