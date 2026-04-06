#!/usr/bin/env bash
# scripts/check-tests-ci.sh — deterministic checker for tests_ci dimension.
# Scores 4 mechanical criteria (.1, .3, .4, .5). Defers .2 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_package_scope "$@"
axr_init_output tests_ci "script:check-tests-ci.sh"

# ---------------------------------------------------------------------------
# Collect test workflow filenames (basename only). A workflow is "test-like"
# if its file body mentions common test runners.
# ---------------------------------------------------------------------------
collect_test_workflows() {
    local files=()
    while IFS= read -r line; do
        files+=("$line")
    done < <(find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
    [ "${#files[@]}" -eq 0 ] && return 0
    local f
    for f in "${files[@]}"; do
        if grep -qiE '\b(test|pytest|jest|vitest|mocha|go test|rspec|cargo test|mvn|gradle|dotnet|phpunit|pest|xcodebuild)\b' "$f" 2>/dev/null; then
            basename "$f"
        fi
    done
}

# ---------------------------------------------------------------------------
# tests_ci.1 — Deterministic test suite under 10 min
# ---------------------------------------------------------------------------
score_tests_ci_1() {
    local name
    name="$(axr_criterion_name tests_ci.1)"

    local workflows=()
    while IFS= read -r w; do
        [ -n "$w" ] && workflows+=("$w")
    done < <(collect_test_workflows)

    # Local test evidence: directories/files that indicate a test suite exists
    local test_evidence=()
    [ -d "src/test" ] && test_evidence+=("src/test/ directory")
    for d in *.Tests *.Test; do
        [ -d "$d" ] && test_evidence+=("$d/ (.NET test project)")
    done
    for f in phpunit.xml phpunit.xml.dist; do
        [ -f "$f" ] && test_evidence+=("$f present")
    done
    [ -d "Tests" ] && test_evidence+=("Tests/ directory (Swift SPM)")

    if [ "${#workflows[@]}" -eq 0 ]; then
        if [ "${#test_evidence[@]}" -gt 0 ]; then
            axr_emit_criterion "tests_ci.1" "$name" script 1 "test suite found but no CI workflows" \
                "${test_evidence[*]}"
        else
            axr_emit_criterion "tests_ci.1" "$name" script 0 "no test workflows in .github/workflows/"
        fi
        return
    fi

    # Attempt gh run list per workflow. If unavailable, score 1.
    local gh_ok=1
    command -v gh >/dev/null 2>&1 || gh_ok=0
    [ "$gh_ok" = "1" ] && ! gh auth status >/dev/null 2>&1 && gh_ok=0

    if [ "$gh_ok" = "0" ]; then
        axr_emit_criterion "tests_ci.1" "$name" script 1 "unknown CI cadence, defaulted to 1 per rubric rule" \
            "gh unavailable or not authenticated; ${#workflows[@]} test workflow(s) detected"
        return
    fi

    local total_dur=0 total_runs=0 passes=0
    local w runs_json
    for w in "${workflows[@]}"; do
        runs_json="$(gh run list --workflow="$w" --limit 10 --json conclusion,createdAt,updatedAt 2>/dev/null || echo '[]')"
        local n
        n="$(jq 'length' <<<"$runs_json" 2>/dev/null || echo 0)"
        [ "$n" -eq 0 ] && continue
        local sum
        sum="$(jq -r '
            [.[] | select(.updatedAt != null and .createdAt != null)
                 | ((.updatedAt | fromdateiso8601) - (.createdAt | fromdateiso8601))]
            | add // 0
        ' <<<"$runs_json" 2>/dev/null || echo 0)"
        local p
        p="$(jq '[.[] | select(.conclusion == "success")] | length' <<<"$runs_json" 2>/dev/null || echo 0)"
        total_dur=$((total_dur + ${sum%.*}))
        total_runs=$((total_runs + n))
        passes=$((passes + p))
    done

    if [ "$total_runs" -lt 3 ]; then
        axr_emit_criterion "tests_ci.1" "$name" script 1 "unknown CI cadence, defaulted to 1 per rubric rule" \
            "insufficient CI run history — $total_runs runs found across ${#workflows[@]} workflow(s)"
        return
    fi

    local avg_dur=$((total_dur / total_runs))
    local pass_pct=$(( (passes * 100) / total_runs ))

    if [ "$avg_dur" -gt 600 ]; then
        axr_emit_criterion "tests_ci.1" "$name" script 2 "avg duration exceeds 10 minutes" \
            "avg ${avg_dur}s across $total_runs runs" "pass rate ${pass_pct}%"
    elif [ "$pass_pct" -ge 90 ]; then
        axr_emit_criterion "tests_ci.1" "$name" script 3 "sub-10min avg with strong pass rate" \
            "avg ${avg_dur}s across $total_runs runs" "pass rate ${pass_pct}%"
    else
        axr_emit_criterion "tests_ci.1" "$name" script 2 "sub-10min avg but weak pass rate" \
            "avg ${avg_dur}s across $total_runs runs" "pass rate ${pass_pct}%"
    fi
}

# ---------------------------------------------------------------------------
# tests_ci.3 — Flaky tests tracked and quarantined
# ---------------------------------------------------------------------------
score_tests_ci_3() {
    local name
    name="$(axr_criterion_name tests_ci.3)"

    local marker_count=0 marker_sample=""
    if command -v grep >/dev/null 2>&1; then
        marker_sample="$(grep -rEn --include='*.py' --include='*.rb' --include='*.js' \
            --include='*.ts' --include='*.tsx' --include='*.jsx' \
            --include='*.go' --include='*.rs' \
            -e '@flaky|pytest\.mark\.flaky|@pytest\.mark\.skip.*flaky|xfail|\.todo\(' \
            . 2>/dev/null \
            | grep -v -E '(^|/)\.git/|(^|/)node_modules/|(^|/)\.venv/|(^|/)venv/|(^|/)\.axr/' \
            | head -5 || true)"
        if [ -n "$marker_sample" ]; then
            marker_count="$(printf '%s\n' "$marker_sample" | wc -l | tr -d ' ')"
        fi
    fi

    local quarantine_dir=""
    for d in tests/quarantine __flaky__ spec/quarantine; do
        if [ -d "$d" ]; then quarantine_dir="$d"; break; fi
    done

    local retry_signal=""
    if [ -d .github/workflows ]; then
        if find -P .github/workflows -maxdepth 1 -type f -not -type l \
            \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
            | xargs -0 grep -lE '\-\-reruns|\-\-retries|retry|nextest.*retries' 2>/dev/null | head -1 \
            | grep -q .; then
            retry_signal="workflow retry config present"
        fi
    fi

    local ev=()
    [ "$marker_count" -gt 0 ] && ev+=("$marker_count flaky marker(s) in source")
    [ -n "$quarantine_dir" ] && ev+=("quarantine dir: $quarantine_dir")
    [ -n "$retry_signal" ] && ev+=("$retry_signal")

    local score=0
    if [ "$marker_count" -eq 0 ] && [ -z "$quarantine_dir" ] && [ -z "$retry_signal" ]; then
        score=0
    elif [ "$marker_count" -gt 0 ] && { [ -n "$quarantine_dir" ] || [ -n "$retry_signal" ]; }; then
        score=3
    elif [ "$marker_count" -gt 0 ]; then
        score=2
    else
        score=1
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tests_ci.3" "$name" script 0 "no flaky tracking signals"
    else
        axr_emit_criterion "tests_ci.3" "$name" script "$score" "flaky tracking signals" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tests_ci.4 — CI failures map to actionable messages
# ---------------------------------------------------------------------------
score_tests_ci_4() {
    local name
    name="$(axr_criterion_name tests_ci.4)"

    if [ ! -d .github/workflows ]; then
        axr_emit_criterion "tests_ci.4" "$name" script 0 "no workflows directory"
        return
    fi

    local has_verbose=0 has_annot=0
    if find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
        | xargs -0 grep -lE '\-v\b|\-\-verbose|\-\-reporter=detailed|\-vv\b' 2>/dev/null | head -1 \
        | grep -q .; then
        has_verbose=1
    fi
    if find -P .github/workflows -maxdepth 1 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
        | xargs -0 grep -lE 'actions/upload-artifact|dorny/test-reporter|publish-unit-test-result' 2>/dev/null | head -1 \
        | grep -q .; then
        has_annot=1
    fi

    local ev=()
    [ "$has_verbose" = "1" ] && ev+=("verbose test output flags present")
    [ "$has_annot" = "1" ] && ev+=("annotation/artifact uploader present")

    local score=0
    if [ "$has_verbose" = "0" ] && [ "$has_annot" = "0" ]; then
        score=1
        axr_emit_criterion "tests_ci.4" "$name" script 1 "workflows exist but no verbosity/annotation"
        return
    elif [ "$has_verbose" = "1" ] && [ "$has_annot" = "1" ]; then
        score=3
    else
        score=2
    fi

    axr_emit_criterion "tests_ci.4" "$name" script "$score" "CI actionability signals" "${ev[@]}"
}

# ---------------------------------------------------------------------------
# tests_ci.5 — Fast-fail pre-commit/pre-push checks
# ---------------------------------------------------------------------------
score_tests_ci_5() {
    local name
    name="$(axr_criterion_name tests_ci.5)"

    local cfg="" hook_count=0 f=""
    if [ -f .pre-commit-config.yaml ] || [ -f .pre-commit-config.yml ]; then
        cfg=".pre-commit-config.yaml"
        f=".pre-commit-config.yaml"
        [ -f .pre-commit-config.yml ] && f=".pre-commit-config.yml"
        hook_count="$(grep -cE '^[[:space:]]+-[[:space:]]+id:' "$f" 2>/dev/null || echo 0)"
    elif [ -f lefthook.yml ] || [ -f .lefthook.yml ]; then
        cfg="lefthook"
        f="lefthook.yml"
        [ -f .lefthook.yml ] && f=".lefthook.yml"
        hook_count="$(grep -cE '^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$' "$f" 2>/dev/null || echo 0)"
    elif [ -d .husky ]; then
        cfg=".husky/"
        hook_count="$(find -P .husky -maxdepth 1 -type f -not -type l 2>/dev/null | wc -l | tr -d ' ')"
    fi

    if [ -z "$cfg" ]; then
        axr_emit_criterion "tests_ci.5" "$name" script 0 "no pre-commit/pre-push config"
        return
    fi

    # Check for fast-fail linting tools in hook config
    local has_lint_tools=0
    if [ -n "$f" ] && grep -qiE '\b(eslint|rubocop|ruff|clippy|golangci-lint|checkstyle|phpcs|swiftlint|dotnet)\b' "$f" 2>/dev/null; then
        has_lint_tools=1
    fi

    local score=1
    if [ "$hook_count" -ge 3 ] || { [ "$hook_count" -ge 1 ] && [ "$has_lint_tools" = "1" ]; }; then
        score=3
    elif [ "$hook_count" -ge 1 ]; then
        score=2
    fi

    local ev=("$cfg with $hook_count hook(s)")
    [ "$has_lint_tools" = "1" ] && ev+=("lint tools detected in hooks")

    axr_emit_criterion "tests_ci.5" "$name" script "$score" "$hook_count hook(s) in $cfg" "${ev[@]}"
}

score_tests_ci_1
axr_defer_criterion "tests_ci.2" "$(axr_criterion_name tests_ci.2)" "deferred to Phase 3 judgment subagent"
score_tests_ci_3
score_tests_ci_4
score_tests_ci_5

axr_finalize_output
