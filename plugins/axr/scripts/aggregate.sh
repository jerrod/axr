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
# Strip template placeholder syntax — REPO_NAME can carry attacker-
# controlled content from git remote URL (see security review round 2).
REPO_NAME="$(printf '%s' "$REPO_NAME" | tr -d '{}')"

# ---------------------------------------------------------------------------
# Collect dimension ids (used by merge and by the aggregation loop).
# ---------------------------------------------------------------------------
DIM_IDS=()
while IFS= read -r id; do
    DIM_IDS+=("$id")
done < <(jq -r '.dimensions[].id' "$_AXR_RUBRIC_PATH")

# ---------------------------------------------------------------------------
# --merge-agents: overlay agent-draft scores onto a merged temp dir.
# Never mutates $INPUT_DIR. When no agent dir supplied, EFFECTIVE_INPUT_DIR
# equals INPUT_DIR and no merging happens.
# ---------------------------------------------------------------------------
EFFECTIVE_INPUT_DIR="$INPUT_DIR"
MERGE_TMP=""
if [ -n "$AGENT_DIR" ]; then
    MERGE_TMP="$(mktemp -d)"
    chmod 700 "$MERGE_TMP"
    _CLEANUP_DIRS+=("$MERGE_TMP")
    mkdir -p "$MERGE_TMP/merged"
    EFFECTIVE_INPUT_DIR="$MERGE_TMP/merged"

    # Seed merged dir from input dimension JSONs.
    for dim_id in "${DIM_IDS[@]}"; do
        src="$INPUT_DIR/$dim_id.json"
        [ -f "$src" ] || die "missing dimension JSON: $src"
        cp "$src" "$EFFECTIVE_INPUT_DIR/$dim_id.json"
    done

    # Overlay each agent-*.json criterion onto its matching dimension JSON.
    # Agent files are a top-level JSON array of criterion objects.
    shopt -s nullglob
    agent_files=("$AGENT_DIR"/agent-*.json)
    shopt -u nullglob
    for af in "${agent_files[@]}"; do
        jq empty "$af" 2>/dev/null || die "invalid JSON: $af"
        # Each element: {id, name, score, evidence, notes, reviewer}
        crit_count="$(jq 'length' "$af")"
        i=0
        while [ "$i" -lt "$crit_count" ]; do
            crit_json="$(jq -c ".[$i]" "$af")"
            crit_id="$(jq -r '.id' <<<"$crit_json")"
            crit_score="$(jq -r '.score' <<<"$crit_json")"
            [ -n "$crit_id" ] && [ "$crit_id" != "null" ] || die "agent criterion missing id in $af (index $i)"
            case "$crit_score" in
                0|1|2|3) : ;;
                *) die "agent criterion $crit_id has invalid score=$crit_score (must be 0-3, agents never emit 4) in $af" ;;
            esac
            # Derive dimension from id prefix (e.g., docs_context.3 -> docs_context).
            dim_from_id="${crit_id%.*}"
            merged_file="$EFFECTIVE_INPUT_DIR/$dim_from_id.json"
            [ -f "$merged_file" ] || die "agent criterion $crit_id maps to unknown dimension '$dim_from_id' in $af"
            # Verify the id exists in that dimension's criteria array.
            matches="$(jq --arg id "$crit_id" '[.criteria[] | select(.id == $id)] | length' "$merged_file")"
            [ "$matches" = "1" ] || die "agent criterion $crit_id not found in $merged_file (matches=$matches) in $af"
            jq -c --argjson ac "$crit_json" '
                .criteria |= map(
                    if .id == ($ac.id) then
                        .score = $ac.score
                        | .evidence = $ac.evidence
                        | .notes = $ac.notes
                        | .reviewer = $ac.reviewer
                        | .defaulted_from_deferred = false
                    else . end
                )
            ' "$merged_file" > "$merged_file.new" && mv "$merged_file.new" "$merged_file"
            i=$((i + 1))
        done
    done
fi

# ---------------------------------------------------------------------------
# Aggregate per-dimension data. Build dimensions object + accumulate totals.
# ---------------------------------------------------------------------------
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
    # Normalize to integer in case a prior run stored a float-serialized
    # total_score; bash $(( )) silently treats non-integer strings as 0.
    PREV_TOTAL="$(printf '%.0f' "$PREV_TOTAL")"
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
chmod 700 "$RENDER_TMP"
_CLEANUP_DIRS+=("$RENDER_TMP")

# Write a template token value, stripping { and } so no token value can
# inject a {{placeholder}} that the awk substitution pass would expand.
# This is defense-in-depth: dimension JSON .name fields, prev_date from
# prior latest.json, and REPO_NAME from git remote URL all flow through
# here and could otherwise carry attacker-influenced placeholder syntax.
write_token() {
    printf '%s' "$2" | tr -d '{}' > "$RENDER_TMP/$1"
}

write_token repo "$REPO_NAME"
write_token total_score "$TOTAL_SCORE"
write_token band_label "$BAND_LABEL"
write_token band_description "$BAND_DESC"
write_token rubric_version "$RUBRIC_VERSION"
write_token scored_at "$SCORED_AT"
write_token trend_section "$TREND_SECTION"
write_token dimension_table "$DIM_TABLE"
write_token blockers "$BLOCKER_LIST"
# Build agent-draft section: list all criteria with reviewer=="agent-draft",
# grouped by dimension.
AGENT_DRAFT_LIST="$(jq -r --argjson dims "$DIMENSIONS_JSON" -n '
    [$dims | to_entries[] |
     {dim: .key, items: [.value.criteria[] | select(.reviewer == "agent-draft") | {id, name, score}]}
     | select(.items | length > 0)] |
    if length == 0 then ""
    else
        ["## Agent-Draft Criteria (needs human confirmation)", "",
         "Scored by judgment subagents -- review before treating as final.", ""] +
        [.[] |
         "**\(.dim)** (\(.items | length) items)",
         (.items[] | "- `\(.id)` -- \(.name) · score \(.score)"),
         ""] |
        join("\n")
    end
')"
write_token agent_draft_section "$AGENT_DRAFT_LIST"
write_token next_improvements "$BLOCKER_LIST"

awk -v d="$RENDER_TMP" '
    BEGIN {
        tokens["repo"]=1; tokens["total_score"]=1; tokens["band_label"]=1
        tokens["band_description"]=1; tokens["rubric_version"]=1
        tokens["scored_at"]=1; tokens["trend_section"]=1
        tokens["dimension_table"]=1; tokens["blockers"]=1
        tokens["next_improvements"]=1; tokens["agent_draft_section"]=1
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
            # Fixed-string index+substr substitution: advances past each
            # replacement so substituted text is never re-scanned (safe
            # from infinite-loop injection). index() also sidesteps awks
            # ERE interpretation of { and } as interval metacharacters.
            plen=length(placeholder)
            out=""
            remaining=line
            while ((idx=index(remaining, placeholder)) > 0) {
                out = out substr(remaining, 1, idx-1) vals[k]
                remaining = substr(remaining, idx + plen)
            }
            line = out remaining
        }
        print line
    }
' "$TEMPLATE_PATH" > "$OUTPUT_DIR/latest.md"

printf 'aggregate.sh: wrote %s/latest.json and %s/latest.md\n' "$OUTPUT_DIR" "$OUTPUT_DIR" >&2
