#!/usr/bin/env bash
# scripts/aggregate.sh — reads per-dimension JSONs from input-dir, computes
# weighted scores/band/blockers per the rubric, writes .axr/latest.{json,md}
# and archives prior latest.json to history/<iso>.json.
#
# Usage: aggregate.sh <input-dir> <output-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

die() { printf 'aggregate.sh: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: aggregate.sh <input-dir> <output-dir>"
INPUT_DIR="$1"
OUTPUT_DIR="$2"

[ -d "$INPUT_DIR" ] || die "input dir not found: $INPUT_DIR"
[ -f "$_AXR_RUBRIC_PATH" ] || die "rubric not found: $_AXR_RUBRIC_PATH"

mkdir -p "$OUTPUT_DIR"
TEMPLATE_PATH="$_AXR_PLUGIN_ROOT/templates/report.md.template"
[ -f "$TEMPLATE_PATH" ] || die "template not found: $TEMPLATE_PATH"

# ---------------------------------------------------------------------------
# Read PREVIOUS run data BEFORE archival.
# ---------------------------------------------------------------------------
PREV_TOTAL=""
PREV_DATE=""
if [ -f "$OUTPUT_DIR/latest.json" ]; then
    PREV_TOTAL="$(jq -r '.total_score // empty' "$OUTPUT_DIR/latest.json" 2>/dev/null || echo "")"
    PREV_DATE="$(jq -r '.scored_at // empty' "$OUTPUT_DIR/latest.json" 2>/dev/null || echo "")"
fi

# ---------------------------------------------------------------------------
# Rubric metadata.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Aggregate per-dimension data. Build dimensions object + accumulate totals.
# ---------------------------------------------------------------------------
DIMENSIONS_JSON='{}'
TOTAL_WEIGHTED=0
BLOCKERS_JSON='[]'

DIM_IDS=()
while IFS= read -r id; do
    DIM_IDS+=("$id")
done < <(jq -r '.dimensions[].id' "$_AXR_RUBRIC_PATH")

for dim_id in "${DIM_IDS[@]}"; do
    input_file="$INPUT_DIR/$dim_id.json"
    [ -f "$input_file" ] || die "missing dimension JSON: $input_file"
    jq empty "$input_file" 2>/dev/null || die "invalid JSON: $input_file"

    weight="$(jq -r --arg id "$dim_id" '.dimensions[] | select(.id == $id) | .weight' "$_AXR_RUBRIC_PATH")"
    dim_name="$(jq -r --arg id "$dim_id" '.dimensions[] | select(.id == $id) | .name' "$_AXR_RUBRIC_PATH")"

    # Build resolved criteria: defaulted_from_deferred for deferred ones.
    resolved_criteria="$(jq -c '
        [.criteria[] | if (.deferred == true) then
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

    # Blocker candidates: score <= 1
    blocker_add="$(jq -c --arg dim_id "$dim_id" --argjson weight "$weight" '
        [.[] | select(.score <= 1) | {dim_id: $dim_id, dim_weight: $weight, id: .id, name: .name, score: .score}]
    ' <<<"$resolved_criteria")"
    BLOCKERS_JSON="$(jq -c --argjson add "$blocker_add" '. + $add' <<<"$BLOCKERS_JSON")"
done

TOTAL_SCORE="$(printf "%.0f" "$TOTAL_WEIGHTED")"

# Clamp in case of floating drift.
if [ "$TOTAL_SCORE" -lt 0 ]; then TOTAL_SCORE=0; fi
if [ "$TOTAL_SCORE" -gt 100 ]; then TOTAL_SCORE=100; fi

# ---------------------------------------------------------------------------
# Band lookup.
# ---------------------------------------------------------------------------
BAND_JSON="$(jq -c --argjson score "$TOTAL_SCORE" '
    .score_bands[] | select(.min <= $score and $score <= .max) | {label, description}
' "$_AXR_RUBRIC_PATH" | head -n1)"
[ -n "$BAND_JSON" ] || BAND_JSON='{"label":"Unknown","description":"score outside band range"}'

# ---------------------------------------------------------------------------
# Top 3 blockers, sorted by dim weight DESC, then criterion id ASC.
# ---------------------------------------------------------------------------
TOP_BLOCKERS="$(jq -c '
    sort_by(-(.dim_weight), .id) | .[0:3]
    | map({id: .id, name: .name, score: .score, dim_id: .dim_id, label: "\(.name) (\(.id))"})
' <<<"$BLOCKERS_JSON")"

# ---------------------------------------------------------------------------
# Trend.
# ---------------------------------------------------------------------------
if [ -n "$PREV_TOTAL" ] && [ "$PREV_TOTAL" != "null" ]; then
    DELTA=$((TOTAL_SCORE - PREV_TOTAL))
    TREND_JSON="$(jq -nc --argjson prev "$PREV_TOTAL" --argjson delta "$DELTA" --arg date "$PREV_DATE" \
        '{previous_score: $prev, delta: $delta, previous_date: $date}')"
else
    TREND_JSON="null"
fi

# ---------------------------------------------------------------------------
# Archive previous latest.json BEFORE writing new one.
# ---------------------------------------------------------------------------
if [ -f "$OUTPUT_DIR/latest.json" ]; then
    mkdir -p "$OUTPUT_DIR/history"
    archive_name="$(date -u +"%Y-%m-%dT%H-%M-%SZ").json"
    cp "$OUTPUT_DIR/latest.json" "$OUTPUT_DIR/history/$archive_name"
fi

# ---------------------------------------------------------------------------
# Compose final JSON.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Render markdown report.
# ---------------------------------------------------------------------------
BAND_LABEL="$(jq -r '.label' <<<"$BAND_JSON")"
BAND_DESC="$(jq -r '.description' <<<"$BAND_JSON")"

DIM_TABLE_HEAD='| Dimension | Raw / Max | Weight | Weighted |
|---|---|---|---|'
DIM_TABLE_BODY="$(jq -r --argjson dims "$DIMENSIONS_JSON" -n '
    $dims | to_entries[] |
    "| \(.key) — \(.value.name) | \(.value.raw_score)/\(.value.max_raw) | \(.value.weight) | \(.value.weighted_score | . * 100 | round / 100) |"
')"
DIM_TABLE="${DIM_TABLE_HEAD}
${DIM_TABLE_BODY}"

if [ "$(jq 'length' <<<"$TOP_BLOCKERS")" -eq 0 ]; then
    BLOCKER_LIST="_No blockers — all scored criteria ≥ 2._"
else
    BLOCKER_LIST="$(jq -r 'to_entries[] | "\(.key + 1). \(.value.label)"' <<<"$TOP_BLOCKERS")"
fi

if [ "$TREND_JSON" = "null" ]; then
    TREND_SECTION="_First scored run — no trend data yet._"
else
    prev="$(jq -r '.previous_score' <<<"$TREND_JSON")"
    delta="$(jq -r '.delta' <<<"$TREND_JSON")"
    prev_date="$(jq -r '.previous_date' <<<"$TREND_JSON")"
    sign=""
    [ "$delta" -ge 0 ] && sign="+"
    TREND_SECTION="**Trend:** previous ${prev}/100 (${prev_date}) · delta: ${sign}${delta}"
fi

# Render template using jq + awk — no python dependency. Write each token's
# value to a temp file, then awk-substitute placeholders with file contents.
RENDER_TMP="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$RENDER_TMP'" EXIT

printf '%s' "$REPO_NAME" > "$RENDER_TMP/repo"
printf '%s' "$TOTAL_SCORE" > "$RENDER_TMP/total_score"
printf '%s' "$BAND_LABEL" > "$RENDER_TMP/band_label"
printf '%s' "$BAND_DESC" > "$RENDER_TMP/band_description"
printf '%s' "$RUBRIC_VERSION" > "$RENDER_TMP/rubric_version"
printf '%s' "$SCORED_AT" > "$RENDER_TMP/scored_at"
printf '%s' "$TREND_SECTION" > "$RENDER_TMP/trend_section"
printf '%s' "$DIM_TABLE" > "$RENDER_TMP/dimension_table"
printf '%s' "$BLOCKER_LIST" > "$RENDER_TMP/blockers"
printf '%s' "$BLOCKER_LIST" > "$RENDER_TMP/next_improvements"

awk -v d="$RENDER_TMP" '
    BEGIN {
        tokens["repo"]=1; tokens["total_score"]=1; tokens["band_label"]=1
        tokens["band_description"]=1; tokens["rubric_version"]=1
        tokens["scored_at"]=1; tokens["trend_section"]=1
        tokens["dimension_table"]=1; tokens["blockers"]=1
        tokens["next_improvements"]=1
        for (k in tokens) {
            val=""
            while ((getline line < (d"/"k)) > 0) {
                if (val == "") val=line
                else val=val "\n" line
            }
            close(d"/"k)
            vals[k]=val
        }
    }
    {
        line=$0
        for (k in tokens) {
            placeholder="{{" k "}}"
            while ((idx=index(line, placeholder)) > 0) {
                line=substr(line,1,idx-1) vals[k] substr(line,idx+length(placeholder))
            }
        }
        print line
    }
' "$TEMPLATE_PATH" > "$OUTPUT_DIR/latest.md"

printf 'aggregate.sh: wrote %s/latest.json and %s/latest.md\n' "$OUTPUT_DIR" "$OUTPUT_DIR" >&2
