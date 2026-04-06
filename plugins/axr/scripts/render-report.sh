#!/usr/bin/env bash
# scripts/render-report.sh — render .axr/latest.md from template.
# Sourced (not invoked) by aggregate.sh — all shell variables from the
# aggregator are available directly (DIMENSIONS_JSON, TOTAL_SCORE, BAND_JSON,
# REPO_NAME, RUBRIC_VERSION, SCORED_AT, TREND_JSON, TOP_BLOCKERS,
# TEMPLATE_PATH, OUTPUT_DIR, _CLEANUP_DIRS).

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
write_token() { printf '%s' "$2" | tr -d '{}' > "$RENDER_TMP/$1"; }
write_token repo "$REPO_NAME"
write_token total_score "$TOTAL_SCORE"
write_token band_label "$BAND_LABEL"
write_token band_description "$BAND_DESC"
write_token rubric_version "$RUBRIC_VERSION"
write_token scored_at "$SCORED_AT"
write_token trend_section "$TREND_SECTION"
write_token dimension_table "$DIM_TABLE"
write_token blockers "$BLOCKER_LIST"
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
