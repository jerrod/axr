#!/usr/bin/env bash
# scripts/check-change-surface.sh — deterministic checker for change_surface.
# Scores 2 mechanical criteria (.3, .5). Defers .1, .2, .4 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_init_output change_surface "script:check-change-surface.sh"

# ---------------------------------------------------------------------------
# change_surface.3 — Integration points documented
# ---------------------------------------------------------------------------
score_change_surface_3() {
    local name
    name="$(axr_criterion_name change_surface.3)"

    local types_found=()
    local ev=()

    local openapi=""
    for f in openapi.yaml openapi.yml openapi.json swagger.json swagger.yaml; do
        [ -f "$f" ] && { openapi="$f"; break; }
    done
    if [ -z "$openapi" ] && [ -d docs/openapi ]; then openapi="docs/openapi/"; fi
    if [ -z "$openapi" ] && [ -d api ]; then
        if find -P api -maxdepth 2 -type f -not -type l \
            \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | head -1 | grep -q .; then
            openapi="api/"
        fi
    fi
    if [ -n "$openapi" ]; then types_found+=("openapi"); ev+=("openapi: $openapi"); fi

    local proto_count
    proto_count="$(find -P . -type f -not -type l -name '*.proto' \
        -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$proto_count" -gt 0 ]; then
        types_found+=("proto")
        ev+=("$proto_count .proto file(s)")
    fi

    local graphql=""
    if [ -f schema.graphql ]; then graphql="schema.graphql"; fi
    if [ -z "$graphql" ]; then
        local gql_count
        gql_count="$(find -P . -type f -not -type l \( -name '*.graphql' -o -name '*.gql' \) \
            -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
        [ "$gql_count" -gt 0 ] && graphql="$gql_count graphql files"
    fi
    if [ -n "$graphql" ]; then types_found+=("graphql"); ev+=("graphql: $graphql"); fi

    local asyncapi=""
    for f in asyncapi.yaml asyncapi.yml asyncapi.json; do
        [ -f "$f" ] && { asyncapi="$f"; break; }
    done
    if [ -n "$asyncapi" ]; then types_found+=("asyncapi"); ev+=("asyncapi: $asyncapi"); fi

    local avro_count
    avro_count="$(find -P . -type f -not -type l -name '*.avsc' \
        -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$avro_count" -gt 0 ]; then types_found+=("avro"); ev+=("$avro_count .avsc files"); fi

    local schemas_dir=""
    if [ -d schemas ]; then
        local sc
        sc="$(find -P schemas -type f -not -type l \
            \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$sc" -gt 1 ]; then schemas_dir="schemas/ ($sc files)"; fi
    fi
    if [ -n "$schemas_dir" ]; then ev+=("organized schemas: $schemas_dir"); fi

    local contracts_dir=""
    if [ -d contracts ]; then
        local cc
        cc="$(find -P contracts -type f -not -type l 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$cc" -gt 0 ]; then contracts_dir="contracts/ ($cc files)"; fi
    fi
    if [ -n "$contracts_dir" ]; then types_found+=("contracts"); ev+=("contracts: $contracts_dir"); fi

    local n="${#types_found[@]}"
    local score=0
    if [ "$n" -eq 0 ]; then
        score=0
    elif [ "$n" -ge 2 ] || [ -n "$schemas_dir" ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "change_surface.3" "$name" script 0 "no API/contract spec files found"
    else
        axr_emit_criterion "change_surface.3" "$name" script "$score" "$n spec type(s) found" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# change_surface.5 — Context packing
# ---------------------------------------------------------------------------
score_change_surface_5() {
    local name
    name="$(axr_criterion_name change_surface.5)"

    local configs=""
    for f in repomix.config.json repomix.toml code2prompt.toml aider.conf.yml; do
        [ -f "$f" ] && configs="${configs}${f},"
    done
    configs="${configs%,}"
    if [ -z "$configs" ] && [ -d .llm ]; then configs=".llm/"; fi

    local scripts_found=""
    for d in scripts bin; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            scripts_found="${scripts_found}${f},"
        done < <(find -P "$d" -maxdepth 2 -type f -not -type l \
            \( -name '*context*' -o -name '*pack*' -o -name '*bundle*' -o -name '*repo-tree*' \) \
            2>/dev/null | head -3)
    done
    scripts_found="${scripts_found%,}"

    local ev=()
    [ -n "$configs" ] && ev+=("config: $configs")
    [ -n "$scripts_found" ] && ev+=("scripts: $scripts_found")

    local score=0
    if [ -z "$configs" ] && [ -z "$scripts_found" ]; then
        score=0
    elif [ -n "$configs" ] && [ -n "$scripts_found" ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "change_surface.5" "$name" script 0 "no context packing tools configured"
    else
        axr_emit_criterion "change_surface.5" "$name" script "$score" "context packing signals" "${ev[@]}"
    fi
}

axr_defer_criterion "change_surface.1" "$(axr_criterion_name change_surface.1)" "deferred to Phase 3 judgment subagent"
axr_defer_criterion "change_surface.2" "$(axr_criterion_name change_surface.2)" "deferred to Phase 3 judgment subagent"
score_change_surface_3
axr_defer_criterion "change_surface.4" "$(axr_criterion_name change_surface.4)" "deferred to Phase 3 judgment subagent"
score_change_surface_5

axr_finalize_output
