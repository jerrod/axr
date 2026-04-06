#!/usr/bin/env bash
# scripts/check-safety-rails.sh — deterministic checker for safety_rails dim.
# Scores 3 mechanical criteria (.3, .4, .5). Defers .1 and .2 to judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

axr_package_scope "$@"
axr_init_output safety_rails "script:check-safety-rails.sh"

# ---------------------------------------------------------------------------
# safety_rails.3 — Secrets not in repo
# ---------------------------------------------------------------------------
score_safety_rails_3() {
    local name
    name="$(axr_criterion_name safety_rails.3)"

    if [ ! -f .gitignore ]; then
        axr_emit_criterion "safety_rails.3" "$name" script 0 ".gitignore missing"
        return
    fi

    local patterns=(".env" ".env.*" "*.key" "*.pem" "credentials.json" "secrets.yaml")
    local covered=0 matches=""
    local p
    for p in "${patterns[@]}"; do
        if grep -qxF "$p" .gitignore 2>/dev/null || grep -qE "^${p//./\\.}$" .gitignore 2>/dev/null; then
            covered=$((covered + 1))
            matches="${matches}${p},"
        fi
    done
    matches="${matches%,}"

    local env_covered=0
    if grep -qE '^\.env(\*|\.?\*)?$' .gitignore 2>/dev/null; then
        env_covered=1
    fi

    local scan_cfg=""
    for f in .gitleaks.toml .trufflehog.yml .secrets.baseline; do
        [ -f "$f" ] && scan_cfg="${scan_cfg}${f},"
    done
    scan_cfg="${scan_cfg%,}"
    if [ -z "$scan_cfg" ] && [ -d .github/workflows ]; then
        if find -P .github/workflows -maxdepth 1 -type f -not -type l \
            \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
            | xargs -0 grep -lE 'gitleaks|trufflehog|detect-secrets' 2>/dev/null | head -1 \
            | grep -q .; then
            scan_cfg="workflow scanning step"
        fi
    fi

    local env_example=""
    for f in .env.example .env.sample .env.dist; do
        [ -f "$f" ] && { env_example="$f"; break; }
    done

    local ev=()
    [ -n "$matches" ] && ev+=(".gitignore patterns: $matches")
    [ -n "$env_example" ] && ev+=("env template: $env_example")
    [ -n "$scan_cfg" ] && ev+=("secret scanning: $scan_cfg")

    local score=0
    if [ "$env_covered" = "0" ]; then
        score=0
    elif [ -n "$env_example" ] && [ -n "$scan_cfg" ]; then
        score=3
    else
        score=2
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "safety_rails.3" "$name" script 0 ".env not covered in .gitignore"
    else
        axr_emit_criterion "safety_rails.3" "$name" script "$score" "secrets hygiene" "${ev[@]}"
    fi
}

# ---------------------------------------------------------------------------
# safety_rails.4 — Branch protection on main
# ---------------------------------------------------------------------------
score_safety_rails_4() {
    local name
    name="$(axr_criterion_name safety_rails.4)"

    if ! command -v gh >/dev/null 2>&1; then
        axr_emit_criterion "safety_rails.4" "$name" script 1 "branch protection state unknown" \
            "gh CLI not available"
        return
    fi

    local slug
    if ! slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
        axr_emit_criterion "safety_rails.4" "$name" script 1 "branch protection state unknown" \
            "no GitHub remote detected or gh not authenticated"
        return
    fi

    if ! printf '%s' "$slug" | grep -Eq '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
        local safe_slug
        safe_slug="$(printf '%s' "$slug" | head -c 100 | tr -cd 'A-Za-z0-9./_-')"
        axr_emit_criterion "safety_rails.4" "$name" script 1 "branch protection state unknown" \
            "could not derive repo slug (sanitized: $safe_slug)"
        return
    fi

    local prot=""
    if prot="$(gh api "repos/$slug/branches/main/protection" 2>/dev/null)"; then
        :
    elif prot="$(gh api "repos/$slug/branches/master/protection" 2>/dev/null)"; then
        :
    else
        prot=""
    fi
    # Ensure single-line JSON (guard against concatenated fallback output)
    prot="$(printf '%s' "$prot" | tr -d '\n' || true)"

    if [ -z "$prot" ] || [ "$prot" = "null" ] || ! printf '%s' "$prot" | jq -e . >/dev/null 2>&1; then
        axr_emit_criterion "safety_rails.4" "$name" script 0 "no branch protection configured" \
            "$slug: no protection on main/master"
        return
    fi

    local reviews status_checks admin_enforced
    reviews="$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' <<<"$prot" 2>/dev/null || echo 0)"
    status_checks="$(jq -r '.required_status_checks.strict // false' <<<"$prot" 2>/dev/null || echo false)"
    admin_enforced="$(jq -r '.enforce_admins.enabled // false' <<<"$prot" 2>/dev/null || echo false)"

    local score=1
    if [ "$reviews" -ge 2 ] && [ "$status_checks" = "true" ] && [ "$admin_enforced" = "true" ]; then
        score=4
    elif [ "$reviews" -ge 1 ] && [ "$status_checks" = "true" ]; then
        score=3
    elif [ "$reviews" -ge 1 ]; then
        score=2
    fi

    axr_emit_criterion "safety_rails.4" "$name" script "$score" "branch protection on $slug" \
        "reviews=$reviews" "strict_status_checks=$status_checks" "admin_enforced=$admin_enforced"
}

# ---------------------------------------------------------------------------
# safety_rails.5 — Agent boundaries documented
# ---------------------------------------------------------------------------
score_safety_rails_5() {
    local name
    name="$(axr_criterion_name safety_rails.5)"

    local doc=""
    for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md .agents/AGENTS.md; do
        [ -f "$f" ] && { doc="$f"; break; }
    done

    local has_boundary=0
    if [ -n "$doc" ]; then
        if grep -iEq '^#{2,3} .*(agent.*(boundar|permission|rule|policy)|allowed.*tool)' "$doc" 2>/dev/null; then
            has_boundary=1
        fi
    fi

    local has_settings=0 settings_file=""
    for f in .claude/settings.json .claude/settings.local.json; do
        if [ -f "$f" ] && jq -e 'has("permissions")' "$f" >/dev/null 2>&1; then
            has_settings=1
            settings_file="$f"
            break
        fi
    done

    local ev=()
    [ -n "$doc" ] && ev+=("agent doc: $doc")
    [ "$has_boundary" = "1" ] && ev+=("boundary section found in $doc")
    [ "$has_settings" = "1" ] && ev+=("permissions in $settings_file")

    local score=0
    if [ -z "$doc" ] && [ "$has_settings" = "0" ]; then
        score=0
    elif [ "$has_boundary" = "1" ] && [ "$has_settings" = "1" ]; then
        score=3
    elif [ "$has_boundary" = "1" ] || [ "$has_settings" = "1" ]; then
        score=2
    else
        score=1
    fi

    if [ "$score" -eq 0 ]; then
        axr_emit_criterion "safety_rails.5" "$name" script 0 "no agent context doc or settings.json"
    elif [ "$score" -eq 1 ]; then
        axr_emit_criterion "safety_rails.5" "$name" script 1 "agent doc present but no boundary section" \
            "${ev[@]}"
    else
        axr_emit_criterion "safety_rails.5" "$name" script "$score" "agent boundaries documented" \
            "${ev[@]}"
    fi
}

axr_defer_criterion "safety_rails.1" "$(axr_criterion_name safety_rails.1)" "deferred to Phase 3 judgment subagent"
axr_defer_criterion "safety_rails.2" "$(axr_criterion_name safety_rails.2)" "deferred to Phase 3 judgment subagent"
score_safety_rails_3
score_safety_rails_4
score_safety_rails_5

axr_finalize_output
