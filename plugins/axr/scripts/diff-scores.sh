#!/usr/bin/env bash
# scripts/diff-scores.sh — compare two AXR result JSON files and emit a
# structured diff object to stdout.
#
# Usage: diff-scores.sh <from.json> <to.json>
#
# Both args are paths to AXR result JSON files (.axr/latest.json or
# .axr/history/<ts>.json). Output: a single JSON object with delta,
# band change, per-dimension deltas, criteria flips, and blocker changes.
set -euo pipefail

die() { printf 'diff-scores.sh: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: diff-scores.sh <from.json> <to.json>"
FROM_FILE="$1"
TO_FILE="$2"

[ -f "$FROM_FILE" ] || die "file not found: $FROM_FILE"
[ -f "$TO_FILE" ]   || die "file not found: $TO_FILE"
jq empty "$FROM_FILE" 2>/dev/null || die "invalid JSON: $FROM_FILE"
jq empty "$TO_FILE"   2>/dev/null || die "invalid JSON: $TO_FILE"

# Extract top-level fields from both files.
FROM_SCORE="$(jq '.total_score // 0' "$FROM_FILE")"
TO_SCORE="$(jq '.total_score // 0' "$TO_FILE")"
DELTA=$((TO_SCORE - FROM_SCORE))

FROM_BAND="$(jq -r '.band.label // "Unknown"' "$FROM_FILE")"
TO_BAND="$(jq -r '.band.label // "Unknown"' "$TO_FILE")"

FROM_DATE="$(jq -r '.scored_at // ""' "$FROM_FILE")"
TO_DATE="$(jq -r '.scored_at // ""' "$TO_FILE")"

if [ "$FROM_BAND" = "$TO_BAND" ]; then
    BAND_CHANGED="false"
else
    BAND_CHANGED="true"
fi

# Dimensions changed: compare weighted_score per dimension.
DIMS_CHANGED="$(jq -nc \
    --slurpfile from "$FROM_FILE" \
    --slurpfile to "$TO_FILE" '
    ($from[0].dimensions // {}) as $fd |
    ($to[0].dimensions // {}) as $td |
    ([$fd | keys[]] + [$td | keys[]] | unique) as $all_ids |
    [
        $all_ids[] |
        . as $id |
        ($fd[$id].weighted_score // 0) as $fw |
        ($td[$id].weighted_score // 0) as $tw |
        (($tw - $fw) * 1000 | round / 1000) as $delta |
        select($delta != 0) |
        {
            id: $id,
            name: ($td[$id].name // $fd[$id].name // $id),
            from_weighted: $fw,
            to_weighted: $tw,
            delta: $delta
        }
    ]
')"

# Criteria flipped: compare per-criterion scores across all dimensions.
CRITERIA_FLIPPED="$(jq -nc \
    --slurpfile from "$FROM_FILE" \
    --slurpfile to "$TO_FILE" '
    ($from[0].dimensions // {}) as $fd |
    ($to[0].dimensions // {}) as $td |

    # Build lookup maps: id -> {score, name}
    (reduce ($fd | to_entries[].value.criteria[]?) as $c
        ({}; . + {($c.id): {score: ($c.score // 0), name: $c.name}})) as $fc |
    (reduce ($td | to_entries[].value.criteria[]?) as $c
        ({}; . + {($c.id): {score: ($c.score // 0), name: $c.name}})) as $tc |

    ([$fc | keys[]] + [$tc | keys[]] | unique) as $all_ids |
    [
        $all_ids[] |
        . as $id |
        ($fc[$id].score // 0) as $fs |
        ($tc[$id].score // 0) as $ts |
        select($fs != $ts) |
        {
            id: $id,
            name: ($tc[$id].name // $fc[$id].name // $id),
            from_score: $fs,
            to_score: $ts,
            direction: (if $ts > $fs then "improved" else "regressed" end)
        }
    ]
')"

# Blockers: compare by criterion id.
BLOCKERS_RESOLVED="$(jq -nc \
    --slurpfile from "$FROM_FILE" \
    --slurpfile to "$TO_FILE" '
    ([$from[0].blockers[]? | .id] | sort) as $fids |
    ([$to[0].blockers[]? | .id] | sort) as $tids |
    [$from[0].blockers[]? | select(.id as $bid | $tids | index($bid) | not)
     | .label // "\(.name // .id) (\(.id))"]
')"

BLOCKERS_INTRODUCED="$(jq -nc \
    --slurpfile from "$FROM_FILE" \
    --slurpfile to "$TO_FILE" '
    ([$from[0].blockers[]? | .id] | sort) as $fids |
    ([$to[0].blockers[]? | .id] | sort) as $tids |
    [$to[0].blockers[]? | select(.id as $bid | $fids | index($bid) | not)
     | .label // "\(.name // .id) (\(.id))"]
')"

# Assemble final diff JSON.
jq -n \
    --argjson from_score "$FROM_SCORE" \
    --argjson to_score "$TO_SCORE" \
    --argjson delta "$DELTA" \
    --arg from_band "$FROM_BAND" \
    --arg to_band "$TO_BAND" \
    --argjson band_changed "$BAND_CHANGED" \
    --arg from_date "$FROM_DATE" \
    --arg to_date "$TO_DATE" \
    --argjson dimensions_changed "$DIMS_CHANGED" \
    --argjson criteria_flipped "$CRITERIA_FLIPPED" \
    --argjson blockers_resolved "$BLOCKERS_RESOLVED" \
    --argjson blockers_introduced "$BLOCKERS_INTRODUCED" \
    '{
        from_score: $from_score,
        to_score: $to_score,
        delta: $delta,
        from_band: $from_band,
        to_band: $to_band,
        band_changed: $band_changed,
        from_date: $from_date,
        to_date: $to_date,
        dimensions_changed: $dimensions_changed,
        criteria_flipped: $criteria_flipped,
        blockers_resolved: $blockers_resolved,
        blockers_introduced: $blockers_introduced
    }'
