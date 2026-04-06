#!/usr/bin/env bash
# scripts/check-style-validation.sh — deterministic checker for the
# style dimension.
# Scores 5 mechanical criteria (.1 through .5). No judgment criteria.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/workflow-helpers.sh
source "$SCRIPT_DIR/lib/workflow-helpers.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/tooling-helpers.sh
source "$SCRIPT_DIR/lib/tooling-helpers.sh"

axr_package_scope "$@"
axr_init_output style "script:check-style.sh"

STACK_JSON="$(axr_detect_stack)"
score_style_1() {
    local name
    name="$(axr_criterion_name style.type-checker)"
    local has_node=0 has_python=0 has_compiled=0 has_php=0
    axr_has_stack_tag node && has_node=1
    axr_has_stack_tag python && has_python=1
    axr_has_stack_tag php && has_php=1
    { axr_has_stack_tag java || axr_has_stack_tag csharp || axr_has_stack_tag swift; } && has_compiled=1
    if [ "$has_node" = "0" ] && [ "$has_python" = "0" ] && [ "$has_compiled" = "0" ] && [ "$has_php" = "0" ]; then
        axr_emit_criterion "style.type-checker" "$name" script 0 \
            "no type-checkable language — no type-checker signal for agents" \
            "stack: $STACK_JSON (no supported language detected)"
        return
    fi
    local scores=() evidence=()
    if [ "$has_node" = "1" ]; then
        if [ -f tsconfig.json ]; then
            if jq -e '.compilerOptions.strict == true' tsconfig.json >/dev/null 2>&1; then
                scores+=(3); evidence+=("tsconfig.json with compilerOptions.strict=true")
            else
                scores+=(2); evidence+=("tsconfig.json present without strict mode")
            fi
        else
            local dts_count
            dts_count="$(find -P . -maxdepth 4 -type f -not -type l -name '*.d.ts' \
                -not -path './node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
            if [ "$dts_count" -gt 0 ]; then
                scores+=(1); evidence+=("no tsconfig.json but $dts_count .d.ts files found")
            else
                scores+=(0); evidence+=("node stack but no tsconfig.json or .d.ts files")
            fi
        fi
    fi
    if [ "$has_python" = "1" ]; then
        local cfg
        cfg="$(list_type_check_configs | grep -vE 'tsconfig|phpstan|psalm' | head -1)"
        if [ -z "$cfg" ]; then
            scores+=(0); evidence+=("python stack but no mypy/pyright config found")
        elif grep -qE '(strict[[:space:]]*=[[:space:]]*(true|True))|"strict"[[:space:]]*:[[:space:]]*true|strictMode' "$cfg" 2>/dev/null; then
            scores+=(3); evidence+=("$cfg with strict mode")
        else
            scores+=(2); evidence+=("$cfg present without strict mode")
        fi
    fi
    if [ "$has_compiled" = "1" ]; then
        local sa_configs
        sa_configs="$(list_lint_configs | grep -E 'checkstyle|pmd|spotbugs' | head -1)"
        if [ -n "$sa_configs" ]; then
            scores+=(3); evidence+=("compiled language with static analysis ($sa_configs)")
        else
            scores+=(2); evidence+=("compiled language — compiler provides type checking")
        fi
    fi
    if [ "$has_php" = "1" ]; then
        local php_tc
        php_tc="$(list_type_check_configs | grep -E 'phpstan|psalm' | head -1)"
        if [ -n "$php_tc" ]; then
            scores+=(2); evidence+=("PHP type checker config: $php_tc")
        else
            scores+=(0); evidence+=("PHP stack but no phpstan/psalm config found")
        fi
    fi
    local final=${scores[0]}
    local s; for s in "${scores[@]}"; do
        [ "$s" -lt "$final" ] && final=$s
    done
    axr_emit_criterion "style.type-checker" "$name" script "$final" \
        "type checker config evaluation" "${evidence[@]}"
}
score_style_2() {
    local name
    name="$(axr_criterion_name style.lint-format)"
    local lint_found="" format_found=""
    lint_found="$(list_lint_configs | head -1)"
    if [ -z "$lint_found" ] && [ -f .editorconfig ] && grep -qiE 'ktlint' .editorconfig 2>/dev/null; then
        lint_found=".editorconfig:ktlint"
    fi
    format_found="$(list_format_configs | head -1)"
    local ci_match=0 ci_tool=""
    local run_lines
    run_lines="$(extract_workflow_run_lines 2>/dev/null || true)"
    if [ -n "$run_lines" ]; then
        if printf '%s\n' "$run_lines" | grep -qE '\b(eslint|biome|ruff|pylint|rubocop|golangci|clippy|ktlint|prettier|black|isort|gofmt|checkstyle|pmd|spotbugs|phpcs|php-cs-fixer|phpstan|swiftlint|swiftformat|dotnet format)\b'; then
            ci_match=1
            ci_tool="$(printf '%s\n' "$run_lines" | grep -oE '\b(eslint|biome|ruff|pylint|rubocop|golangci|clippy|ktlint|prettier|black|isort|gofmt|checkstyle|pmd|spotbugs|phpcs|php-cs-fixer|phpstan|swiftlint|swiftformat|dotnet format)\b' | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')"
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
        axr_emit_criterion "style.lint-format" "$name" script 0 "no lint or format config found"
    else
        axr_emit_criterion "style.lint-format" "$name" script "$score" "lint/format config evaluation" "${ev[@]}"
    fi
}
score_style_3() {
    local name
    name="$(axr_criterion_name style.format-enforced)"
    local local_enforce=0 ci_enforce=0
    local ev=()
    # Check pre-commit hooks for formatter
    if [ -f .pre-commit-config.yaml ] || [ -f .pre-commit-config.yml ]; then
        local pcf=".pre-commit-config.yaml"
        [ -f .pre-commit-config.yml ] && pcf=".pre-commit-config.yml"
        if grep -qiE '\b(prettier|black|gofmt|ktfmt|autopep8|yapf|rustfmt|clang-format)\b' "$pcf" 2>/dev/null; then
            local_enforce=1
            ev+=("pre-commit hook with formatter in $pcf")
        fi
    fi
    # Check husky hooks for formatter
    if [ -d .husky ] && [ "$local_enforce" = "0" ]; then
        if find -P .husky -maxdepth 1 -type f -not -type l -print0 2>/dev/null \
            | xargs -0 grep -liE '\b(prettier|black|gofmt|ktfmt|lint-staged)\b' 2>/dev/null | head -1 \
            | grep -q .; then
            local_enforce=1
            ev+=("husky hook with formatter")
        fi
    fi
    # Check CI for format enforcement
    local run_lines
    run_lines="$(extract_workflow_run_lines 2>/dev/null || true)"
    if [ -n "$run_lines" ]; then
        if printf '%s\n' "$run_lines" | grep -qiE 'format-check|prettier --check|black --check|gofmt -l|rustfmt.*--check|clang-format.*--dry-run'; then
            ci_enforce=1
            ev+=("CI step with format check")
        fi
    fi
    # Check package.json / Makefile for format-check target
    if [ "$ci_enforce" = "0" ]; then
        if [ -f package.json ] && jq -e '.scripts["format-check"] // .scripts["format:check"]' package.json >/dev/null 2>&1; then
            ev+=("package.json format-check script")
            # Only counts as CI if we also find it in workflow run lines
        fi
        if [ -f Makefile ] && grep -qE '^format-check:' Makefile 2>/dev/null; then
            ev+=("Makefile format-check target")
        fi
    fi
    local score=0
    if [ "$local_enforce" = "1" ] && [ "$ci_enforce" = "1" ]; then
        score=3
    elif [ "$local_enforce" = "1" ]; then
        score=2
    elif [ "$ci_enforce" = "1" ]; then
        score=2
    fi
    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "style.format-enforced" "$name" script 0 "no formatting enforcement found"
    else
        axr_emit_criterion "style.format-enforced" "$name" script "$score" "format enforcement evaluation" "${ev[@]}"
    fi
}
score_style_4() {
    local name
    name="$(axr_criterion_name style.static-analysis)"
    local local_found=0 ci_found=0
    local ev=()
    # Semgrep
    if [ -f .semgrep.yml ] || [ -f .semgrep.yaml ] || [ -f .semgrepignore ]; then
        local_found=1
        ev+=("semgrep config present")
    fi
    # CodeQL
    if [ -d .github/codeql ]; then
        local_found=1
        ev+=(".github/codeql/ directory present")
    fi
    # SonarQube/SonarCloud
    if [ -f sonar-project.properties ]; then
        local_found=1; ev+=("sonar-project.properties present")
    fi
    # Java static analysis
    if [ -f checkstyle.xml ] || [ -f spotbugs.xml ] || [ -f pmd.xml ]; then
        local_found=1; ev+=("Java static analysis config present")
    fi
    # PHP static analysis
    if [ -f phpstan.neon ] || [ -f phpstan.neon.dist ] || [ -f psalm.xml ] || [ -f psalm.xml.dist ]; then
        local_found=1; ev+=("PHP static analysis config present")
    fi
    # Check CI for static analysis steps
    local run_lines
    run_lines="$(extract_workflow_run_lines 2>/dev/null || true)"
    if [ -n "$run_lines" ]; then
        if printf '%s\n' "$run_lines" | grep -qiE '\b(semgrep|codeql|sonar|cargo clippy|spotbugs|checkstyle|phpstan|psalm|dotnet format)\b'; then
            ci_found=1
            ev+=("CI step with static analysis tool")
        fi
    fi
    # Check workflow files for CodeQL action
    if [ -d .github/workflows ] && [ "$ci_found" = "0" ]; then
        if find -P .github/workflows -maxdepth 1 -type f -not -type l \
            \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
            | xargs -0 grep -lE 'github/codeql-action|sonarsource/sonarcloud' 2>/dev/null | head -1 \
            | grep -q .; then
            ci_found=1
            ev+=("CI workflow with CodeQL or SonarCloud action")
        fi
    fi
    local score=0
    if [ "$ci_found" = "1" ]; then
        score=3
    elif [ "$local_found" = "1" ]; then
        score=2
    fi
    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "style.static-analysis" "$name" script 0 "no static analysis beyond linting"
    else
        axr_emit_criterion "style.static-analysis" "$name" script "$score" "static analysis evaluation" "${ev[@]}"
    fi
}
score_style_5() {
    local name
    name="$(axr_criterion_name style.editor-config)"
    local has_editorconfig=0 has_ide=0
    local ev=()
    if [ -f .editorconfig ]; then
        has_editorconfig=1
        ev+=(".editorconfig present")
    fi
    if [ -f .vscode/settings.json ]; then
        has_ide=1
        ev+=(".vscode/settings.json present")
    fi
    if [ -f .vscode/extensions.json ]; then
        has_ide=1
        ev+=(".vscode/extensions.json present")
    fi
    if [ -d .idea ] && [ -n "$(find -P .idea -maxdepth 1 -type f -not -type l -name '*.xml' 2>/dev/null | head -1)" ]; then
        has_ide=1
        ev+=(".idea/ config present")
    fi
    if [ -d .zed ]; then
        has_ide=1
        ev+=(".zed/ config present")
    fi
    local score=0
    if [ "$has_editorconfig" = "1" ] && [ "$has_ide" = "1" ]; then
        score=3
    elif [ "$has_editorconfig" = "1" ]; then
        score=2
    elif [ "$has_ide" = "1" ]; then
        score=2
    fi
    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "style.editor-config" "$name" script 0 "no editor/IDE config shared"
    else
        axr_emit_criterion "style.editor-config" "$name" script "$score" "editor config evaluation" "${ev[@]}"
    fi
}

score_style_1
score_style_2
score_style_3
score_style_4
score_style_5

axr_finalize_output
