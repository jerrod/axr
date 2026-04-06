#!/usr/bin/env bash
# scripts/lib/monorepo-helpers.sh — monorepo detection, package listing, scoping.
# Sourced by common.sh. Globals prefixed _AXR_, functions prefixed axr_.
_AXR_PACKAGE_PATH=""

# axr_detect_monorepo — echo monorepo type or empty string.
axr_detect_monorepo() {
    local root
    root="$(axr_repo_root)"
    if [ -f "$root/lerna.json" ]; then printf 'lerna\n'; return 0; fi
    if [ -f "$root/nx.json" ]; then printf 'nx\n'; return 0; fi
    if [ -f "$root/turbo.json" ]; then printf 'turbo\n'; return 0; fi
    if [ -f "$root/pnpm-workspace.yaml" ]; then printf 'pnpm-workspace\n'; return 0; fi
    if [ -f "$root/settings.gradle.kts" ] \
       && grep -q 'include' "$root/settings.gradle.kts" 2>/dev/null; then
        printf 'gradle-multi\n'; return 0
    fi
    if [ -f "$root/Cargo.toml" ] \
       && grep -q '\[workspace\]' "$root/Cargo.toml" 2>/dev/null; then
        printf 'cargo-workspace\n'; return 0
    fi
    printf '\n'
}

# axr_list_packages — list package roots (relative to repo root), one per line.
axr_list_packages() {
    local root type
    root="$(axr_repo_root)"
    type="$(axr_detect_monorepo)"
    case "$type" in
        lerna)           _axr_list_lerna "$root" ;;
        nx|turbo|pnpm-workspace) _axr_list_workspaces "$root" "$type" ;;
        gradle-multi)    _axr_list_gradle "$root" ;;
        cargo-workspace) _axr_list_cargo "$root" ;;
        *)               return 0 ;;
    esac
}

_axr_list_lerna() {
    local root="$1" globs
    globs="$(jq -r '.packages[]' "$root/lerna.json" 2>/dev/null)" || return 0
    _axr_expand_js_globs "$root" "$globs"
}

_axr_list_workspaces() {
    local root="$1" type="$2" globs=""
    if [ -f "$root/package.json" ]; then
        globs="$(jq -r '.workspaces // .workspaces.packages // empty | .[]' \
            "$root/package.json" 2>/dev/null)"
    fi
    if [ -z "$globs" ] && [ "$type" = "pnpm-workspace" ]; then
        globs="$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
            "$root/pnpm-workspace.yaml" 2>/dev/null)"
    fi
    [ -z "$globs" ] && return 0
    _axr_expand_js_globs "$root" "$globs"
}

_axr_expand_js_globs() {
    local root="$1" globs="$2" glob d rel
    while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        for d in $root/$glob; do
            [ -d "$d" ] || continue
            [ -f "$d/package.json" ] || continue
            rel="${d#"$root"/}"
            printf '%s\n' "$rel"
        done
    done <<< "$globs"
}

_axr_list_gradle() {
    local root="$1"
    sed -n 's/.*include(\"\(.*\)\").*/\1/p' "$root/settings.gradle.kts" \
        | sed 's/:/\//g' \
        | while IFS= read -r rel; do
            [ -d "$root/$rel" ] && printf '%s\n' "$rel"
          done
}

_axr_list_cargo() {
    local root="$1" in_members=0 globs="" line val
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*members ]]; then in_members=1; continue; fi
        if [ "$in_members" = "1" ]; then
            if [[ "$line" =~ ^\] ]]; then break; fi
            val="$(printf '%s' "$line" | sed 's/.*"\(.*\)".*/\1/')"
            [ -n "$val" ] && globs="${globs}${val}"$'\n'
        fi
    done < "$root/Cargo.toml"
    local glob d rel
    while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        for d in $root/$glob; do
            [ -d "$d" ] || continue
            rel="${d#"$root"/}"
            printf '%s\n' "$rel"
        done
    done <<< "$globs"
}

# axr_package_scope — parse --package <path> from args, cd into package dir.
axr_package_scope() {
    local root
    root="$(axr_repo_root)"
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--package" ] && [ "$#" -ge 2 ]; then
            local pkg_path="$2"
            if [ ! -d "$root/$pkg_path" ]; then
                printf 'axr_package_scope: %s not found under %s\n' \
                    "$pkg_path" "$root" >&2
                return 1
            fi
            cd "$root/$pkg_path" || return 1
            _AXR_PACKAGE_PATH="$pkg_path"
            return 0
        fi
        shift
    done
}
