#!/usr/bin/env bash
# scripts/render-report.sh — render .axr/latest.md from template.
#
# SOURCED (not invoked) by aggregate.sh. Cannot run standalone.
#
# Required variables from parent scope (set by aggregate.sh before sourcing):
#   DIMENSIONS_JSON  — jq object of all dimension data
#   TOTAL_SCORE      — integer 0-100
#   BAND_JSON        — jq object {label, description}
#   REPO_NAME        — string (brace-stripped by aggregate.sh)
#   RUBRIC_VERSION   — string from rubric
#   SCORED_AT        — ISO timestamp
#   TREND_JSON       — jq object or "null"
#   TOP_BLOCKERS     — jq array of blocker objects
#   TEMPLATE_PATH    — path to report.md.template
#   OUTPUT_DIR       — where to write latest.md
#   _CLEANUP_DIRS    — array for trap cleanup (this script appends to it)

BAND_LABEL="$(jq -r '.label' <<<"$BAND_JSON")"
BAND_DESC="$(jq -r '.description' <<<"$BAND_JSON")"
DIM_TABLE_HEAD='| Dimension | Raw / Max | Weight | Weighted |
|---|---|---|---|'
DIM_TABLE_BODY="$(jq -r --argjson dims "$DIMENSIONS_JSON" -n '
    $dims | to_entries[] |
    "| \(.key) — \(.value.name) | \(.value.raw_score)/\(.value.max_raw) | \(.value.weight) | \(.value.weighted_score | . * 100 | round / 100) |"
' 2>/dev/null)"
DIM_TABLE="$(printf '%s\n%s' "$DIM_TABLE_HEAD" "$DIM_TABLE_BODY")"
if [ "$(jq 'length' <<<"$TOP_BLOCKERS")" -eq 0 ]; then
    BLOCKER_LIST="_No blockers — all scored criteria ≥ 2._"
else
    BLOCKER_LIST="$(jq -r 'to_entries[] | "\(.key + 1). \(.value.label)"' <<<"$TOP_BLOCKERS")"
fi
if [ "$TREND_JSON" = "null" ]; then
    TREND_SECTION="_First scored run — no trend data yet._"
else
    # Sanitize trend values to expected formats — defense-in-depth against
    # a tampered prior latest.json injecting content via these fields.
    prev="$(jq -r '.previous_score' <<<"$TREND_JSON" | grep -Eo '^[0-9]+$' || echo "0")"
    delta="$(jq -r '.delta' <<<"$TREND_JSON")"
    prev_date="$(jq -r '.previous_date' <<<"$TREND_JSON" | grep -Eo '^[0-9T:.Z-]+$' || echo "unknown")"
    sign=""
    [[ "$delta" =~ ^-?[0-9]+$ ]] || delta=0
    [ "$delta" -ge 0 ] && sign="+"
    TREND_SECTION="**Trend:** previous ${prev}/100 (${prev_date}) · delta: ${sign}${delta}"
fi
RENDER_TMP="$(mktemp -d)"
chmod 700 "$RENDER_TMP"
_CLEANUP_DIRS+=("$RENDER_TMP")
# Strip only template delimiter sequences {{ and }} (not individual braces)
# so legitimate content with { or } (JSON, code) is preserved while template
# injection via {{placeholder}} is still blocked. The awk renderer uses
# non-recursive index+substr so even if delimiters survived, no infinite loop
# is possible — this is defense-in-depth.
write_token() { printf '%s' "$2" | sed 's/{{//g; s/}}//g' > "$RENDER_TMP/$1"; }
write_token repo "$REPO_NAME"
write_token total_score "$TOTAL_SCORE"
write_token band_label "$BAND_LABEL"
write_token band_description "$BAND_DESC"
write_token rubric_version "$RUBRIC_VERSION"
write_token scored_at "$SCORED_AT"
write_token trend_section "$TREND_SECTION"
write_token dimension_table "$DIM_TABLE"
write_token blockers "$BLOCKER_LIST"
# Count agent-scored vs defaulted judgment criteria for the report.
AGENT_SCORED_COUNT="$(jq -r --argjson dims "$DIMENSIONS_JSON" -n '
    [$dims | to_entries[].value.criteria[] | select(.reviewer == "agent-draft")] | length
')"
DEFAULTED_COUNT="$(jq -r --argjson dims "$DIMENSIONS_JSON" -n '
    [$dims | to_entries[].value.criteria[] | select(.defaulted_from_deferred == true)] | length
')"
AGENT_DRAFT_LIST="$(jq -r --argjson dims "$DIMENSIONS_JSON" \
    --argjson scored "$AGENT_SCORED_COUNT" --argjson defaulted "$DEFAULTED_COUNT" -n '
    [$dims | to_entries[] |
     {dim: .key, items: [.value.criteria[] | select(.reviewer == "agent-draft") | {id, name, score}]}
     | select(.items | length > 0)] |
    if length == 0 then
        if $defaulted > 0 then
            "## Judgment Criteria Status\n\n" +
            "\($defaulted) judgment criteria defaulted to score 1 (no agents scored them).\n" +
            "Run `/axr` with judgment subagents enabled to replace defaults with agent-draft scores."
        else ""
        end
    else
        ["## Agent-Draft Criteria (needs human confirmation)", "",
         "Scored by judgment subagents -- review before treating as final.",
         "\($scored) scored by agents, \($defaulted) still defaulted to 1.", ""] +
        [.[] |
         "**\(.dim)** (\(.items | length) items)",
         (.items[] | "- `\(.id)` -- \(.name) · score \(.score)"),
         ""] |
        join("\n")
    end
')"
write_token agent_draft_section "$AGENT_DRAFT_LIST"

# --- Comprehension Debt Index ---
# Harmonic mean of 4 criterion scores:
#   legibility.context-window-fit, legibility.decision-coverage,
#   docs.decision-log, patterns.single-approach
# Scaled to 0-10 range.

extract_criterion_score() {
    local crit_id="$1"
    jq -r --arg id "$crit_id" --argjson dims "$DIMENSIONS_JSON" -n \
        '[$dims | to_entries[].value.criteria[] | select(.id == $id) | .score][0] // empty'
}

CWF_RAW="$(extract_criterion_score "legibility.context-window-fit")"
DC_RAW="$(extract_criterion_score "legibility.decision-coverage")"
DL_RAW="$(extract_criterion_score "docs.decision-log")"
SA_RAW="$(extract_criterion_score "patterns.single-approach")"

# Floor nulls/empties to 0.5 (deferred = unknown, not absent)
floor_score() {
    local s="${1:-}"
    if [ -z "$s" ] || [ "$s" = "null" ]; then echo "0.5"; else echo "$s"; fi
}

CWF_S="$(floor_score "$CWF_RAW")"
DC_S="$(floor_score "$DC_RAW")"
DL_S="$(floor_score "$DL_RAW")"
SA_S="$(floor_score "$SA_RAW")"

# Weighted harmonic mean, floor each to 0.1 to avoid div/0
# Result in 0-4 range, scaled to 0-10 by multiplying by 2.5
COMP_DEBT_SCORE="$(awk -v a="$CWF_S" -v b="$DC_S" -v c="$DL_S" -v d="$SA_S" 'BEGIN {
    if (a < 0.1) a = 0.1; if (b < 0.1) b = 0.1
    if (c < 0.1) c = 0.1; if (d < 0.1) d = 0.1
    hm = 4.0 / (1/a + 1/b + 1/c + 1/d)
    scaled = hm * 2.5
    printf "%.1f", (scaled > 10 ? 10 : scaled)
}')"

# Map to label
if awk -v s="$COMP_DEBT_SCORE" 'BEGIN { exit (s >= 8) ? 0 : 1 }'; then
    COMP_DEBT_LABEL="Agent-Clear"
elif awk -v s="$COMP_DEBT_SCORE" 'BEGIN { exit (s >= 5) ? 0 : 1 }'; then
    COMP_DEBT_LABEL="Agent-Readable"
elif awk -v s="$COMP_DEBT_SCORE" 'BEGIN { exit (s >= 2) ? 0 : 1 }'; then
    COMP_DEBT_LABEL="Agent-Murky"
else
    COMP_DEBT_LABEL="Agent-Opaque"
fi

write_token comp_debt_score "$COMP_DEBT_SCORE"
write_token comp_debt_label "$COMP_DEBT_LABEL"
write_token cwf_score "${CWF_RAW:-deferred}"
write_token dc_score "${DC_RAW:-deferred}"
write_token dl_score "${DL_RAW:-deferred}"
write_token sa_score "${SA_RAW:-deferred}"

# --- Agent ROI Predictor ---
case "$BAND_LABEL" in
    "Agent-Native")    roi_stmt="Agents productive with light supervision" ;;
    "Agent-Ready")     roi_stmt="~35-40% fewer agent-generated bugs vs Agent-Hazardous (Ox Security)" ;;
    "Agent-Assisted")  roi_stmt="Agents useful for scoped tasks; 12% first-year cost overhead (Codebridge)" ;;
    "Agent-Hazardous") roi_stmt="1.7x more issues, agents create more cleanup than value (Ox Security)" ;;
    *)                 roi_stmt="4x maintenance cost by year 2 (Codebridge); comprehension wall at week 7 (Osmani)" ;;
esac
write_token roi_statement "$roi_stmt"
# next_improvements was previously identical to blockers (dead duplication).
# Removed — the "Top 3 Blockers" section IS the actionable improvement list.
# Phase 4 may add a distinct LLM-generated recommendations section.
write_token next_improvements ""
awk -v d="$RENDER_TMP" '
    BEGIN {
        tokens["repo"]=1; tokens["total_score"]=1; tokens["band_label"]=1
        tokens["band_description"]=1; tokens["rubric_version"]=1
        tokens["scored_at"]=1; tokens["trend_section"]=1
        tokens["dimension_table"]=1; tokens["blockers"]=1
        tokens["next_improvements"]=1; tokens["agent_draft_section"]=1
        tokens["comp_debt_score"]=1; tokens["comp_debt_label"]=1
        tokens["cwf_score"]=1; tokens["dc_score"]=1; tokens["dl_score"]=1; tokens["sa_score"]=1
        tokens["roi_statement"]=1
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
