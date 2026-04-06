#!/usr/bin/env bash
# scripts/merge-agents.sh — overlay agent-draft scores onto mechanical
# dimension JSONs. Creates merged copies; never mutates originals.
#
# Usage: merge-agents.sh <agent-dir> <input-dir> <output-dir> <dim_id...>
#
# <agent-dir>: directory containing agent-*.json files (each a JSON array
#              of criterion objects with id/name/score/evidence/notes/reviewer)
# <input-dir>: directory with mechanical <dim_id>.json files (the originals)
# <output-dir>: where merged <dim_id>.json copies are written (must exist)
# <dim_id...>: one or more dimension ids (e.g., docs_context tests_ci ...)
#
# Validation (dies on first failure):
#   - Agent criterion id must match ^[a-z_]+\.[0-9]+$ (prevents path traversal)
#   - Agent score must be 0-3 (agents never emit 4)
#   - Agent reviewer must be exactly "agent-draft"
#   - Agent criterion id must exist in the target dimension's criteria array

set -euo pipefail

die() { printf 'merge-agents.sh: %s\n' "$1" >&2; exit 1; }

AGENT_DIR="$1"; shift
INPUT_DIR="$1"; shift
OUTPUT_DIR="$1"; shift
DIM_IDS=("$@")

[ -d "$AGENT_DIR" ] || die "agent dir not found: $AGENT_DIR"
[ -d "$INPUT_DIR" ] || die "input dir not found: $INPUT_DIR"
[ -d "$OUTPUT_DIR" ] || die "output dir not found: $OUTPUT_DIR"

# Seed output dir from input dimension JSONs.
for dim_id in "${DIM_IDS[@]}"; do
    src="$INPUT_DIR/$dim_id.json"
    [ -f "$src" ] || die "missing dimension JSON: $src"
    cp "$src" "$OUTPUT_DIR/$dim_id.json"
done

# Overlay each agent-*.json criterion onto its matching dimension JSON.
shopt -s nullglob
agent_files=("$AGENT_DIR"/agent-*.json)
shopt -u nullglob
for af in "${agent_files[@]}"; do
    jq empty "$af" 2>/dev/null || die "invalid JSON: $af"
    crit_count="$(jq 'length' "$af")"
    i=0
    while [ "$i" -lt "$crit_count" ]; do
        crit_json="$(jq -c ".[$i]" "$af")"
        crit_id="$(jq -r '.id' <<<"$crit_json")"
        crit_score="$(jq -r '.score' <<<"$crit_json")"
        [ -n "$crit_id" ] && [ "$crit_id" != "null" ] || die "agent criterion missing id in $af (index $i)"
        # Validate id format — prevents path traversal.
        [[ "$crit_id" =~ ^[a-z_]+\.[0-9]+$ ]] || die "agent criterion id '$crit_id' does not match format in $af (index $i)"
        case "$crit_score" in
            0|1|2|3) : ;;
            *) die "agent criterion $crit_id has invalid score=$crit_score (must be 0-3) in $af" ;;
        esac
        # Validate reviewer field.
        crit_reviewer="$(jq -r '.reviewer' <<<"$crit_json")"
        [ "$crit_reviewer" = "agent-draft" ] || die "agent criterion $crit_id has reviewer=$crit_reviewer (must be agent-draft) in $af"
        # Validate evidence is a JSON array.
        ev_type="$(jq 'if .evidence | type == "array" then "ok" else "bad" end' <<<"$crit_json")"
        [ "$ev_type" = '"ok"' ] || die "agent criterion $crit_id evidence must be a JSON array in $af"
        # Validate notes is a string (not array/object) and ≤500 chars.
        notes_type="$(jq -r '.notes | type' <<<"$crit_json")"
        [ "$notes_type" = "string" ] || die "agent criterion $crit_id notes must be a string (got $notes_type) in $af"
        notes_len="$(jq -r '.notes | length' <<<"$crit_json")"
        [ "$notes_len" -le 500 ] || die "agent criterion $crit_id notes exceeds 500 chars ($notes_len) in $af"
        # Derive dimension from id prefix.
        dim_from_id="${crit_id%.*}"
        merged_file="$OUTPUT_DIR/$dim_from_id.json"
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
