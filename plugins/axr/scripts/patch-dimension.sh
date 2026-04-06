#!/usr/bin/env bash
# scripts/patch-dimension.sh — replace one dimension's criteria in an existing
# latest.json and recompute totals/band/blockers.
#
# Usage: patch-dimension.sh <dim-id> <dim-json-path> <latest-json-path>
#
# Delegated from aggregate.sh --patch-dimension. Not intended for standalone use.
# Archives prior latest.json to history/, rewrites latest.json and latest.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

die() { printf 'patch-dimension.sh: %s\n' "$*" >&2; exit 1; }

# Unified cleanup trap.
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

[ $# -eq 3 ] || die "usage: patch-dimension.sh <dim-id> <dim-json-path> <latest-json-path>"
DIM_ID="$1"
DIM_JSON_PATH="$2"
LATEST_JSON_PATH="$3"

# Validate dim-id format.
[[ "$DIM_ID" =~ ^[a-z]+$ ]] || die "invalid dimension id: $DIM_ID"

# Validate dim-id exists in rubric.
jq -e --arg id "$DIM_ID" '.dimensions[] | select(.id == $id)' "$_AXR_RUBRIC_PATH" >/dev/null 2>&1 \
    || die "unknown dimension id: $DIM_ID"

# Validate files.
[ -f "$DIM_JSON_PATH" ]    || die "dimension JSON not found: $DIM_JSON_PATH"
[ -f "$LATEST_JSON_PATH" ] || die "latest.json not found: $LATEST_JSON_PATH"
jq empty "$DIM_JSON_PATH"    2>/dev/null || die "invalid JSON: $DIM_JSON_PATH"
jq empty "$LATEST_JSON_PATH" 2>/dev/null || die "invalid JSON: $LATEST_JSON_PATH"

# Read the fresh dimension's criteria from the checker output.
FRESH_CRITERIA="$(jq -c '.criteria' "$DIM_JSON_PATH")"

# Read existing latest.json.
EXISTING="$(cat "$LATEST_JSON_PATH")"

# Resolve criteria: default deferred to score 1 (same logic as aggregate.sh).
RESOLVED_CRITERIA="$(jq -c '
    [.[] |
     if (.reviewer == "agent-draft" and (has("defaulted_from_deferred") and .defaulted_from_deferred == false)) then
        .
     elif (.deferred == true) then
        . + {score: 1, defaulted_from_deferred: true}
     else
        . + {defaulted_from_deferred: false}
     end]
' <<<"$FRESH_CRITERIA")"

# Look up the dimension's weight and name from rubric.
WEIGHT="$(jq -r --arg id "$DIM_ID" '.dimensions[] | select(.id == $id) | .weight' "$_AXR_RUBRIC_PATH")"
DIM_NAME="$(jq -r --arg id "$DIM_ID" '.dimensions[] | select(.id == $id) | .name' "$_AXR_RUBRIC_PATH")"

# Compute raw_score and weighted_score for the patched dimension.
RAW_SCORE="$(jq '[.[] | .score] | add // 0' <<<"$RESOLVED_CRITERIA")"
MAX_RAW="$(jq --arg id "$DIM_ID" '.dimensions[] | select(.id==$id) | (.criteria | length) * 4' "$_AXR_RUBRIC_PATH")"
WEIGHTED="$(awk -v r="$RAW_SCORE" -v m="$MAX_RAW" -v w="$WEIGHT" 'BEGIN { printf "%.6f", (r/m)*w }')"

# Build the patched dimension object.
PATCHED_DIM="$(jq -n \
    --arg name "$DIM_NAME" \
    --argjson weight "$WEIGHT" \
    --argjson raw_score "$RAW_SCORE" \
    --argjson max_raw "$MAX_RAW" \
    --argjson weighted_score "$WEIGHTED" \
    --argjson criteria "$RESOLVED_CRITERIA" \
    '{name: $name, weight: $weight, raw_score: $raw_score, max_raw: $max_raw, weighted_score: $weighted_score, criteria: $criteria}')"

# Overlay the patched dimension into the existing dimensions object.
DIMENSIONS_JSON="$(jq -c --arg id "$DIM_ID" --argjson obj "$PATCHED_DIM" \
    '.dimensions + {($id): $obj}' <<<"$EXISTING")"

# Recompute total_score from all dimensions.
TOTAL_WEIGHTED="$(jq -r '[to_entries[].value.weighted_score] | add // 0' <<<"$DIMENSIONS_JSON")"
TOTAL_SCORE="$(printf "%.0f" "$TOTAL_WEIGHTED")"
if [ "$TOTAL_SCORE" -lt 0 ]; then TOTAL_SCORE=0; fi
if [ "$TOTAL_SCORE" -gt 100 ]; then TOTAL_SCORE=100; fi

# Recompute band.
BAND_JSON="$(jq -c --argjson score "$TOTAL_SCORE" '
    .score_bands[] | select(.min <= $score and $score <= .max) | {label, description}
' "$_AXR_RUBRIC_PATH" | head -n1)"
[ -n "$BAND_JSON" ] || BAND_JSON='{"label":"Unknown","description":"score outside band range"}'

# Recompute blockers from ALL dimensions (not just patched).
BLOCKERS_JSON="$(jq -c '
    [to_entries[] |
     .key as $dim_id | .value.weight as $weight |
     .value.criteria[] |
     select(.score <= 1 and (.defaulted_from_deferred != true)) |
     {dim_id: $dim_id, dim_weight: $weight, id: .id, name: .name, score: .score}]
' <<<"$DIMENSIONS_JSON")"

TOP_BLOCKERS="$(jq -c '
    sort_by(-(.dim_weight), .id) | .[0:3]
    | map({id: .id, name: .name, score: .score, dim_id: .dim_id, label: "\(.name) (\(.id))"})
' <<<"$BLOCKERS_JSON")"

# Metadata from existing latest.json.
# Read rubric_version from the RUBRIC (not latest.json) so upgrades propagate.
RUBRIC_VERSION="$(jq -r '.rubric_version' "$_AXR_RUBRIC_PATH")"
REPO_NAME="$(jq -r '.repo' <<<"$EXISTING" | tr -d '{}')"
SCORED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Trend: compare to OLD total_score.
PREV_TOTAL="$(jq -r '.total_score // empty' <<<"$EXISTING" 2>/dev/null || echo "")"
PREV_DATE="$(jq -r '.scored_at // empty' <<<"$EXISTING" 2>/dev/null || echo "")"

if [ -n "$PREV_TOTAL" ] && [ "$PREV_TOTAL" != "null" ]; then
    PREV_TOTAL="$(printf '%.0f' "$PREV_TOTAL" 2>/dev/null | grep -Eo '^[0-9]+$' || echo 0)"
    DELTA=$((TOTAL_SCORE - PREV_TOTAL))
    TREND_JSON="$(jq -nc --argjson prev "$PREV_TOTAL" --argjson delta "$DELTA" --arg date "$PREV_DATE" \
        '{previous_score: $prev, delta: $delta, previous_date: $date}')"
else
    TREND_JSON="null"
fi

# Derive OUTPUT_DIR from LATEST_JSON_PATH.
OUTPUT_DIR="$(dirname "$LATEST_JSON_PATH")"

# Archive prior latest.json.
mkdir -p "$OUTPUT_DIR/history"
ARCHIVE_NAME="$(date -u +"%Y-%m-%dT%H-%M-%SZ").json"
cp "$LATEST_JSON_PATH" "$OUTPUT_DIR/history/$ARCHIVE_NAME"

# Write updated latest.json.
FINAL_JSON="$(jq -n \
    --arg rubric_version "$RUBRIC_VERSION" \
    --arg scored_at "$SCORED_AT" \
    --arg repo "$REPO_NAME" \
    --argjson total_score "$TOTAL_SCORE" \
    --argjson band "$BAND_JSON" \
    --argjson dimensions "$DIMENSIONS_JSON" \
    --argjson blockers "$TOP_BLOCKERS" \
    --argjson trend "$TREND_JSON" \
    '{
        rubric_version: $rubric_version,
        scored_at: $scored_at,
        repo: $repo,
        total_score: $total_score,
        band: $band,
        dimensions: $dimensions,
        blockers: $blockers,
        trend: $trend
    }')"
printf '%s\n' "$FINAL_JSON" | jq --indent 2 . > "$LATEST_JSON_PATH"

# Render markdown report.
TEMPLATE_PATH="$_AXR_PLUGIN_ROOT/templates/report.md.template"
[ -f "$TEMPLATE_PATH" ] || die "template not found: $TEMPLATE_PATH"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=render-report.sh
source "$SCRIPT_DIR/render-report.sh"

printf 'patch-dimension.sh: patched %s in %s\n' "$DIM_ID" "$LATEST_JSON_PATH" >&2
