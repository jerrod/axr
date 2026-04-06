#!/usr/bin/env bash
# scripts/aggregate.sh — reads per-dimension JSONs from input-dir, computes
# weighted scores/band/blockers per the rubric, writes .axr/latest.{json,md}
# and archives prior latest.json to history/<iso>.json.
#

# Usage: aggregate.sh [--merge-agents <agent-dir>] <input-dir> <output-dir>
#

# When --merge-agents <agent-dir> is present (must precede positional args),
# each agent-*.json under <agent-dir> is parsed as a JSON array of criterion
# objects. Each criterion is overlaid onto the matching mechanical dimension

# JSON (derived from id prefix) into a temp merged dir; the aggregation loop
# then reads from the merged dir. <input-dir> is never mutated.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
die() { printf 'aggregate.sh: %s\n' "$*" >&2; exit 1; }

# Unified cleanup trap — collects temp dirs to remove on EXIT.
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT
AGENT_DIR=""

# --patch-dimension mode: delegate entirely to patch-dimension.sh.
if [ $# -ge 1 ] && [ "$1" = "--patch-dimension" ]; then
    [ $# -eq 4 ] || die "usage: aggregate.sh --patch-dimension <dim-id> <dim-json> <latest-json>"
    exec "$SCRIPT_DIR/patch-dimension.sh" "$2" "$3" "$4"
fi

if [ $# -ge 1 ] && [ "$1" = "--merge-agents" ]; then
    [ $# -ge 2 ] || die "usage: aggregate.sh [--merge-agents <agent-dir>] <input-dir> <output-dir>"
    AGENT_DIR="$2"
    shift 2
    [ -d "$AGENT_DIR" ] || die "agent dir not found: $AGENT_DIR"
fi
[ $# -eq 2 ] || die "usage: aggregate.sh [--merge-agents <agent-dir>] <input-dir> <output-dir>"
INPUT_DIR="$1"
OUTPUT_DIR="$2"
[ -d "$INPUT_DIR" ] || die "input dir not found: $INPUT_DIR"
[ -f "$_AXR_RUBRIC_PATH" ] || die "rubric not found: $_AXR_RUBRIC_PATH"
mkdir -p "$OUTPUT_DIR"
TEMPLATE_PATH="$_AXR_PLUGIN_ROOT/templates/report.md.template"
[ -f "$TEMPLATE_PATH" ] || die "template not found: $TEMPLATE_PATH"

# Read PREVIOUS run data BEFORE archival.
PREV_TOTAL=""
PREV_DATE=""

if [ -f "$OUTPUT_DIR/latest.json" ]; then
    PREV_TOTAL="$(jq -r '.total_score // empty' "$OUTPUT_DIR/latest.json" 2>/dev/null || echo "")"
    PREV_DATE="$(jq -r '.scored_at // empty' "$OUTPUT_DIR/latest.json" 2>/dev/null || echo "")"
fi

# Rubric metadata.
RUBRIC_VERSION="$(jq -r '.rubric_version' "$_AXR_RUBRIC_PATH")"
SCORED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
REPO_NAME="unknown"

if REMOTE_URL="$(git config --get remote.origin.url 2>/dev/null)"; then
    REPO_NAME="$(basename "$REMOTE_URL" .git)"
elif [ -d .git ]; then
    REPO_NAME="$(basename "$PWD")"
else
    REPO_NAME="$(basename "$PWD")"
fi

# Strip template placeholder syntax — REPO_NAME can carry attacker-
# controlled content from git remote URL (see security review round 2).
REPO_NAME="$(printf '%s' "$REPO_NAME" | tr -d '{}')"

# Collect dimension ids (used by merge and by the aggregation loop).
DIM_IDS=()
while IFS= read -r id; do
    DIM_IDS+=("$id")
done < <(jq -r '.dimensions[].id' "$_AXR_RUBRIC_PATH")
# --merge-agents: overlay agent-draft scores onto a merged temp dir.

# Never mutates $INPUT_DIR. When no agent dir supplied, EFFECTIVE_INPUT_DIR
# equals INPUT_DIR and no merging happens.

EFFECTIVE_INPUT_DIR="$INPUT_DIR"

if [ -n "$AGENT_DIR" ]; then
    MERGE_TMP="$(mktemp -d)"
    chmod 700 "$MERGE_TMP"
    _CLEANUP_DIRS+=("$MERGE_TMP")
    EFFECTIVE_INPUT_DIR="$MERGE_TMP"
    "$SCRIPT_DIR/merge-agents.sh" "$AGENT_DIR" "$INPUT_DIR" "$MERGE_TMP" "${DIM_IDS[@]}"
fi

# Aggregate per-dimension data. Build dimensions object + accumulate totals.
DIMENSIONS_JSON='{}'
TOTAL_WEIGHTED=0
BLOCKERS_JSON='[]'
for dim_id in "${DIM_IDS[@]}"; do
    input_file="$EFFECTIVE_INPUT_DIR/$dim_id.json"
    [ -f "$input_file" ] || die "missing dimension JSON: $input_file"
    jq empty "$input_file" 2>/dev/null || die "invalid JSON: $input_file"
    weight="$(jq -r --arg id "$dim_id" '.dimensions[] | select(.id == $id) | .weight' "$_AXR_RUBRIC_PATH")"
    dim_name="$(jq -r --arg id "$dim_id" '.dimensions[] | select(.id == $id) | .name' "$_AXR_RUBRIC_PATH")"
    # Build resolved criteria: default deferred criteria to score 1 unless
    # they've already been overlaid by an agent (reviewer == "agent-draft"
    # AND defaulted_from_deferred == false from the merge step).
    # In merge mode, agent-overlaid criteria have defaulted_from_deferred
    # explicitly set to false and reviewer to "agent-draft". Preserve them.
    # Note: jq's // operator treats false as absent, so we use has() instead.
    resolved_criteria="$(jq -c '
        [.criteria[] |
         if (.reviewer == "agent-draft" and (has("defaulted_from_deferred") and .defaulted_from_deferred == false)) then
            .
         elif (.deferred == true) then
            . + {score: 1, defaulted_from_deferred: true}
         else
            . + {defaulted_from_deferred: false}
         end]
    ' "$input_file")"
    raw_score="$(jq '[.[] | .score] | add // 0' <<<"$resolved_criteria")"
    # weighted = raw / 20 * weight — use awk for float math.
    weighted="$(awk -v r="$raw_score" -v w="$weight" 'BEGIN { printf "%.6f", (r/20.0)*w }')"
    TOTAL_WEIGHTED="$(awk -v a="$TOTAL_WEIGHTED" -v b="$weighted" 'BEGIN { printf "%.6f", a+b }')"
    dim_obj="$(jq -n \
        --arg name "$dim_name" \
        --argjson weight "$weight" \
        --argjson raw_score "$raw_score" \
        --argjson weighted_score "$weighted" \
        --argjson criteria "$resolved_criteria" \
        '{name: $name, weight: $weight, raw_score: $raw_score, max_raw: 20, weighted_score: $weighted_score, criteria: $criteria}')"
    DIMENSIONS_JSON="$(jq -c --arg id "$dim_id" --argjson obj "$dim_obj" \
        '. + {($id): $obj}' <<<"$DIMENSIONS_JSON")"
    # Blocker candidates: score <= 1 AND NOT defaulted_from_deferred.
    # Defaulted judgment criteria score 1 as a placeholder — they're not
    # assessed yet, so they shouldn't dominate the blockers list. Real
    # mechanical scores of 0-1 are the actionable blockers.
    blocker_add="$(jq -c --arg dim_id "$dim_id" --argjson weight "$weight" '
        [.[] | select(.score <= 1 and (.defaulted_from_deferred != true))
             | {dim_id: $dim_id, dim_weight: $weight, id: .id, name: .name, score: .score}]
    ' <<<"$resolved_criteria")"
    BLOCKERS_JSON="$(jq -c --argjson add "$blocker_add" '. + $add' <<<"$BLOCKERS_JSON")"
done

TOTAL_SCORE="$(printf "%.0f" "$TOTAL_WEIGHTED")"

# Clamp in case of floating drift.

if [ "$TOTAL_SCORE" -lt 0 ]; then TOTAL_SCORE=0; fi

if [ "$TOTAL_SCORE" -gt 100 ]; then TOTAL_SCORE=100; fi

# Band lookup.

BAND_JSON="$(jq -c --argjson score "$TOTAL_SCORE" '
    .score_bands[] | select(.min <= $score and $score <= .max) | {label, description}
' "$_AXR_RUBRIC_PATH" | head -n1)"
[ -n "$BAND_JSON" ] || BAND_JSON='{"label":"Unknown","description":"score outside band range"}'

# Top 3 blockers, sorted by dim weight DESC, then criterion id ASC.

TOP_BLOCKERS="$(jq -c '
    sort_by(-(.dim_weight), .id) | .[0:3]
    | map({id: .id, name: .name, score: .score, dim_id: .dim_id, label: "\(.name) (\(.id))"})
' <<<"$BLOCKERS_JSON")"

# Trend.

if [ -n "$PREV_TOTAL" ] && [ "$PREV_TOTAL" != "null" ]; then
    # Normalize to integer in case a prior run stored a float-serialized
    # total_score; bash $(( )) silently treats non-integer strings as 0.
    PREV_TOTAL="$(printf '%.0f' "$PREV_TOTAL")"
    DELTA=$((TOTAL_SCORE - PREV_TOTAL))
    TREND_JSON="$(jq -nc --argjson prev "$PREV_TOTAL" --argjson delta "$DELTA" --arg date "$PREV_DATE" \
        '{previous_score: $prev, delta: $delta, previous_date: $date}')"
else
    TREND_JSON="null"
fi

# Archive previous latest.json BEFORE writing new one.

if [ -f "$OUTPUT_DIR/latest.json" ]; then
    mkdir -p "$OUTPUT_DIR/history"
    archive_name="$(date -u +"%Y-%m-%dT%H-%M-%SZ").json"
    cp "$OUTPUT_DIR/latest.json" "$OUTPUT_DIR/history/$archive_name"
fi

# Compose final JSON.

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
printf '%s\n' "$FINAL_JSON" | jq --indent 2 . > "$OUTPUT_DIR/latest.json"

# Render markdown report (sourced script reads all shell variables from this scope).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=render-report.sh
source "$SCRIPT_DIR/render-report.sh"
printf 'aggregate.sh: wrote %s/latest.json and %s/latest.md\n' "$OUTPUT_DIR" "$OUTPUT_DIR" >&2
