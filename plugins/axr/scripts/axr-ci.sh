#!/usr/bin/env bash
# scripts/axr-ci.sh — CI fast-path: mechanical-only scoring with optional
# monorepo fan-out and configurable band threshold.
#
# Usage: axr-ci.sh [--config <path>]
#
# Config (.axr/config.json):
#   { "ci_minimum_band": "Agent-Assisted", "ci_fail_on_blockers": true }
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

die() { printf 'axr-ci.sh: %s\n' "$*" >&2; exit 1; }

_CLEANUP_DIRS=()
trap 'rm -rf "${_CLEANUP_DIRS[@]}"' EXIT

PACKAGE_SCOPED_DIMS=(tests docs style tooling)
GLOBAL_DIMS=(safety structure change visibility workflow)

CONFIG_FILE=".axr/config.json"
MIN_BAND="Agent-Hostile"
FAIL_ON_BLOCKERS=false

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) [ -n "${2:-}" ] || die "--config requires a path"
                      CONFIG_FILE="$2"; shift 2 ;;
            *)        die "unknown arg: $1" ;;
        esac
    done
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    MIN_BAND="$(jq -r '.ci_minimum_band // "Agent-Hostile"' "$CONFIG_FILE")"
    FAIL_ON_BLOCKERS="$(jq -r '.ci_fail_on_blockers // false' "$CONFIG_FILE")"
}

band_min_score() {
    local band="$1"
    jq -r --arg b "$band" \
        '.score_bands[] | select(.label == $b) | .min // 0' \
        "$_AXR_RUBRIC_PATH"
}

run_checker() {
    local dim="$1" pkg_flag="${2:-}"
    local script_path="$SCRIPT_DIR/check-${dim//_/-}.sh"
    [ -x "$script_path" ] || die "checker not found: $script_path"
    if [ -n "$pkg_flag" ]; then
        "$script_path" --package "$pkg_flag"
    else
        "$script_path"
    fi
}

run_all() {
    local tmp_dir="$1" mono_type="$2"
    shift 2
    local packages=("$@")

    # Global dims: always at repo root
    for dim in "${GLOBAL_DIMS[@]}"; do
        run_checker "$dim" > "$tmp_dir/$dim.json" 2>"$tmp_dir/$dim.stderr" &
    done

    if [ -n "$mono_type" ] && [ ${#packages[@]} -gt 0 ]; then
        for dim in "${PACKAGE_SCOPED_DIMS[@]}"; do
            local pkg_dir="$tmp_dir/pkg-$dim"
            mkdir -p "$pkg_dir"
            for pkg in "${packages[@]}"; do
                local safe_name="${pkg//\//_}"
                run_checker "$dim" "$pkg" \
                    > "$pkg_dir/$safe_name.json" \
                    2>"$pkg_dir/$safe_name.stderr" &
            done
        done
    else
        for dim in "${PACKAGE_SCOPED_DIMS[@]}"; do
            run_checker "$dim" > "$tmp_dir/$dim.json" 2>"$tmp_dir/$dim.stderr" &
        done
    fi

    wait
}

merge_package_scores() {
    local tmp_dir="$1" mono_type="$2"
    [ -n "$mono_type" ] || return 0

    for dim in "${PACKAGE_SCOPED_DIMS[@]}"; do
        local pkg_dir="$tmp_dir/pkg-$dim"
        [ -d "$pkg_dir" ] || continue

        local pkg_jsons=()
        for f in "$pkg_dir"/*.json; do
            [ -f "$f" ] && jq empty "$f" 2>/dev/null && pkg_jsons+=("$f")
        done
        [ ${#pkg_jsons[@]} -gt 0 ] || continue

        # Envelope (stack, reviewer) from first valid package JSON
        local first_envelope
        first_envelope="$(jq -c '{stack, reviewer}' "${pkg_jsons[0]}")"

        # Average non-null scores; deferred criteria pass through unaveraged
        jq -n \
            --arg dim_id "$dim" \
            --argjson env "$first_envelope" \
            --slurpfile pkgs <(cat "${pkg_jsons[@]}" | jq -c '.criteria[]') '
            ($pkgs | group_by(.id) | map(
                if .[0].score == null then
                    .[0]
                else {
                    id: .[0].id,
                    name: .[0].name,
                    score: ([.[] | select(.score != null) | .score]
                            | if length > 0
                              then (add / length + 0.5 | floor)
                              else 0 end),
                    evidence: [.[].evidence[]?] | unique,
                    notes: ([.[] | select(.score != null)]
                            | length | tostring) + " packages scored",
                    reviewer: .[0].reviewer
                }
                end
            )) as $merged |
            {
                dimension_id: $dim_id,
                stack: $env.stack,
                reviewer: $env.reviewer,
                criteria: $merged
            }
        ' > "$tmp_dir/$dim.json"
        rm -rf "$pkg_dir"
    done
}

main() {
    parse_args "$@"
    load_config

    local tmp_dir mono_type packages=()
    tmp_dir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmp_dir")
    mkdir -p .axr/history

    mono_type="$(axr_detect_monorepo)"
    if [ -n "$mono_type" ]; then
        mapfile -t packages < <(axr_list_packages)
        echo "Monorepo detected ($mono_type): ${#packages[@]} packages" >&2
    fi

    run_all "$tmp_dir" "$mono_type" "${packages[@]}"
    merge_package_scores "$tmp_dir" "$mono_type"

    # Validate all dimension JSONs before aggregation
    for f in "$tmp_dir"/*.json; do
        jq empty "$f" 2>/dev/null || die "invalid JSON: $f"
    done

    "$SCRIPT_DIR/aggregate.sh" "$tmp_dir" .axr

    local score band blockers
    score="$(jq '.total_score' .axr/latest.json)"
    band="$(jq -r '.band.label' .axr/latest.json)"
    blockers="$(jq '[.blockers[]?] | length' .axr/latest.json)"

    echo "AXR CI: $score/100 · $band"

    local min_score exit_code=0
    min_score="$(band_min_score "$MIN_BAND")"
    [ -n "$min_score" ] && [ "$min_score" != "null" ] || min_score=0

    if [ "$score" -lt "$min_score" ]; then
        echo "FAIL: score $score below $MIN_BAND (min $min_score)" >&2
        exit_code=1
    fi
    if [ "$FAIL_ON_BLOCKERS" = "true" ] && [ "$blockers" -gt 0 ]; then
        echo "FAIL: $blockers blocker(s) found" >&2
        exit_code=1
    fi

    exit "$exit_code"
}

main "$@"
