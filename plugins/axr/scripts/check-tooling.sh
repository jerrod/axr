#!/usr/bin/env bash
# scripts/check-tooling.sh — deterministic checker for the tooling dimension.
# Scores 5 mechanical criteria (.1 through .5). No judgment criteria.
#
# v2.0 renumbering: old .3→.1, .4→.2, .5→.3; new .4 (devcontainer), .5 (build cache).
# Old .1 and .2 moved to style_validation dimension.

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

axr_init_output tooling "script:check-tooling.sh"

# ---------------------------------------------------------------------------
# tooling.1 — Reproducible hermetic build (was tooling.3)
# ---------------------------------------------------------------------------
score_tooling_1() {
    local name
    name="$(axr_criterion_name tooling.1)"

    local lockfound envfound container_found
    lockfound="$(list_lockfiles | paste -sd, -)"
    envfound="$(list_env_pins | paste -sd, -)"
    container_found="$(list_containerization | paste -sd, -)"

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
        axr_emit_criterion "tooling.1" "$name" script 0 "no lockfile found"
    else
        axr_emit_criterion "tooling.1" "$name" script "$score" "reproducibility signals" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tooling.2 — One-command bootstrap (was tooling.4)
# ---------------------------------------------------------------------------
score_tooling_2() {
    local name
    name="$(axr_criterion_name tooling.2)"

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
        axr_emit_criterion "tooling.2" "$name" script 0 "no bootstrap script found"
    elif [ "$executable" = "1" ]; then
        axr_emit_criterion "tooling.2" "$name" script 3 "bootstrap present and executable" "$found"
    else
        axr_emit_criterion "tooling.2" "$name" script 2 "bootstrap present but not executable" "$found"
    fi
}

# ---------------------------------------------------------------------------
# tooling.3 — Pinned dependencies + upgrade path (was tooling.5)
# ---------------------------------------------------------------------------
score_tooling_3() {
    local name
    name="$(axr_criterion_name tooling.3)"

    local lock_count
    lock_count="$(count_lockfiles)"

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
        axr_emit_criterion "tooling.3" "$name" script 0 "no lockfile — cannot pin dependencies"
    else
        axr_emit_criterion "tooling.3" "$name" script "$score" "dependency pinning evaluation" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tooling.4 — Dev container or codespace support (NEW)
# ---------------------------------------------------------------------------
score_tooling_4() {
    local name
    name="$(axr_criterion_name tooling.4)"

    local devcontainer=0 gitpod=0 codespace=0
    local ev=()

    if [ -f .devcontainer/devcontainer.json ]; then
        devcontainer=2
        ev+=(".devcontainer/devcontainer.json present")
        if [ -f .devcontainer/Dockerfile ]; then
            devcontainer=3
            ev+=(".devcontainer/Dockerfile present")
        fi
    elif [ -f .devcontainer/Dockerfile ]; then
        devcontainer=1
        ev+=(".devcontainer/Dockerfile without devcontainer.json")
    fi

    if [ -f .gitpod.yml ]; then
        gitpod=3
        ev+=(".gitpod.yml present")
    fi

    if [ -d .github ] && find -P .github -maxdepth 3 -type f -not -type l \
        \( -name '*.yml' -o -name '*.yaml' -o -name '*.json' \) -print0 2>/dev/null \
        | xargs -0 grep -lq 'codespace' 2>/dev/null; then
        codespace=2
        ev+=("codespace references in .github/")
    fi

    local score=0
    for s in $devcontainer $gitpod $codespace; do
        [ "$s" -gt "$score" ] && score=$s
    done

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tooling.4" "$name" script 0 "no devcontainer or codespace config"
    else
        axr_emit_criterion "tooling.4" "$name" script "$score" "dev container evaluation" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# tooling.5 — Build cache or incremental feedback (NEW)
# ---------------------------------------------------------------------------
score_tooling_5() {
    local name
    name="$(axr_criterion_name tooling.5)"

    local local_cache=0 ci_cache=0
    local ev=()

    if [ -f turbo.json ]; then
        local_cache=1
        ev+=("turbo.json present")
    fi
    if [ -f nx.json ]; then
        local_cache=1
        ev+=("nx.json present")
    fi
    if [ -f gradle.properties ] && grep -q 'buildCache\|--build-cache' gradle.properties 2>/dev/null; then
        local_cache=1
        ev+=("gradle build cache configured")
    fi
    if [ -f .ccache ] || [ -d .ccache ]; then
        local_cache=1
        ev+=("ccache config present")
    fi

    if [ -d .github/workflows ]; then
        if find -P .github/workflows -maxdepth 1 -type f -not -type l \
            \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
            | xargs -0 grep -lE 'actions/cache|actions/setup-node.*cache|setup-python.*cache' 2>/dev/null | head -1 \
            | grep -q .; then
            ci_cache=1
            ev+=("CI cache steps present (actions/cache or setup-* cache)")
        fi
    fi

    if [ -f .turbo ] || [ -d .turbo ]; then
        ev+=(".turbo cache dir present")
    fi

    local score=0
    if [ "$local_cache" -eq 1 ] && [ "$ci_cache" -eq 1 ]; then
        score=3
    elif [ "$local_cache" -eq 1 ] || [ "$ci_cache" -eq 1 ]; then
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "tooling.5" "$name" script 0 "no build cache or incremental build config"
    else
        axr_emit_criterion "tooling.5" "$name" script "$score" "build cache evaluation" "${ev[@]}"
    fi
}

score_tooling_1
score_tooling_2
score_tooling_3
score_tooling_4
score_tooling_5

axr_finalize_output
