#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# rubber-band.sh — PreToolUse hook for Write|Edit
#
# Scans tool input for prohibited rationalization phrases.
# Implements graduation model based on journal history:
#   Confront (0-4 incidents): blocks + supplies correction + exemplar
#   Question (5-9 incidents): blocks + cost-benefit analysis + exemplar
#   Remind  (10+ incidents):  allows + brief context injection + exemplar
#
# All tiers log predictions (behavioral experiments) and use ABC structure.
#
# Input: JSON on stdin with tool_input.content (Write) or tool_input.new_string (Edit)
# Output: block JSON, context JSON, or silent exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"

# Category mapping: rationalization phrases to distortion categories
declare -A PHRASE_CATEGORIES=(
  ["pre-existing"]="ownership-avoidance"
  ["already broken"]="ownership-avoidance"
  ["close enough"]="premature-closure"
  ["should be fine"]="premature-closure"
  ["out of scope"]="scope-deflection"
  ["can be addressed later"]="scope-deflection"
  ["not fixable"]="learned-helplessness"
)

# Consequence lookup for ABC model
declare -A PHRASE_CONSEQUENCES=(
  ["pre-existing"]="skip fixing violations in touched file"
  ["already broken"]="skip fixing violations in touched file"
  ["close enough"]="declare victory before threshold met"
  ["should be fine"]="skip verification step"
  ["out of scope"]="defer required work"
  ["can be addressed later"]="defer required work"
  ["not fixable"]="abandon investigation prematurely"
)

# Phrase map: pattern -> correction (sorted for deterministic iteration).
# Declared before the project-local phrase loader so that loader can append
# to an already-initialised array rather than having its entries wiped out
# by a later re-initialisation.
declare -a PHRASE_KEYS=(
  "already broken"
  "can be addressed later"
  "close enough"
  "not fixable"
  "out of scope"
  "pre-existing"
  "should be fine"
)
declare -A PHRASES=(
  ["already broken"]="If I touched it, I own it"
  ["can be addressed later"]="Fix it now if the file is in my diff"
  ["close enough"]="Run the tool. Read the number."
  ["not fixable"]="Have I tried 3 approaches? Keep investigating."
  ["out of scope"]="If the user asked for it, it is in scope"
  ["pre-existing"]="I own every file I touch"
  ["should be fine"]="Run verification. Read the output."
)

ensure_therapist_dir

# Load project-local phrases from .claude/therapist-phrases.json if it exists.
# Containment-check the file against the git repo root so a parent-dir or
# symlinked location cannot inject arbitrary correction text into the
# hook's decision JSON. Drop any TSV row whose phrase or correction
# contains an embedded newline (jq @tsv only escapes tabs, not newlines).
PROJ_PHRASES_FILE="${PWD}/.claude/therapist-phrases.json"
# Re-resolve from PWD (the target project), not the plugin's own REPO_ROOT.
_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -f "$PROJ_PHRASES_FILE" && -n "$_repo_root" ]]; then
  # Resolve the FILE itself (follows symlinks), not just its parent dir,
  # so a symlink inside .claude/ pointing outside the repo is caught.
  _phrases_real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$PROJ_PHRASES_FILE" 2>/dev/null || true)
  _repo_real=""
  if cd "$_repo_root" 2>/dev/null; then
    _repo_real=$(pwd -P)
    cd - >/dev/null 2>&1 || true
  fi
  case "$(dirname "$_phrases_real")" in
    "$_repo_real"|"$_repo_real"/*)
      while IFS=$'\t' read -r phrase correction category consequence; do
        [[ -z "$phrase" ]] && continue
        [[ "$phrase" == *$'\n'* ]] && continue
        [[ "$correction" == *$'\n'* ]] && continue
        PHRASE_KEYS+=("$phrase")
        PHRASES["$phrase"]="$correction"
        PHRASE_CATEGORIES["$phrase"]="$category"
        PHRASE_CONSEQUENCES["$phrase"]="$consequence"
      done < <(jq -r '.phrases[]? | [.phrase, .correction, .category, .consequence] | @tsv' "$PROJ_PHRASES_FILE" 2>/dev/null || true)
      ;;
    *)
      printf '[therapist] WARNING: %s resolves outside git repo root (%s) — custom phrases not loaded\n' \
        "$PROJ_PHRASES_FILE" "$_repo_real" >&2
      ;;
  esac
fi
unset _repo_root _phrases_real _repo_real

INPUT=$(cat)

# Extract content from Write or Edit tool input
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# Load category counts from journal for graduation
declare -A CATEGORY_COUNTS=()
while IFS=: read -r cat count; do
  [[ -z "$cat" ]] && continue
  CATEGORY_COUNTS["$cat"]="$count"
done < <(journal_category_counts 2>/dev/null || true)

# Infer activating event from tool context
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // "unknown file"')
EVENT="editing ${FILE_PATH##*/}"

# Collect ALL matches
MATCHED_PHRASES=()
MATCHED_CORRECTIONS=()
MATCHED_CATEGORIES=()

for pattern in "${PHRASE_KEYS[@]}"; do
  if printf '%s' "$CONTENT" | grep -qi -F -- "$pattern"; then
    MATCHED_PHRASES+=("$pattern")
    MATCHED_CORRECTIONS+=("${PHRASES[$pattern]}")
    MATCHED_CATEGORIES+=("${PHRASE_CATEGORIES[$pattern]:-unknown}")
  fi
done

if [[ ${#MATCHED_PHRASES[@]} -eq 0 ]]; then
  exit 0
fi

# Determine graduation tier for the first match's category
FIRST_CATEGORY="${MATCHED_CATEGORIES[0]}"
CATEGORY_COUNT=0
if [[ -v "CATEGORY_COUNTS[$FIRST_CATEGORY]" ]]; then
  CATEGORY_COUNT="${CATEGORY_COUNTS[$FIRST_CATEGORY]}"
fi

# Get exemplar for this category
EXEMPLAR=$(bash "${SCRIPT_DIR}/journal.sh" exemplar "$FIRST_CATEGORY" 2>/dev/null || true)

# Log each match with ABC structure and prediction
for i in "${!MATCHED_PHRASES[@]}"; do
  cur_phrase="${MATCHED_PHRASES[$i]}"
  cur_correction="${MATCHED_CORRECTIONS[$i]}"
  cur_category="${MATCHED_CATEGORIES[$i]}"
  cur_consequence="${PHRASE_CONSEQUENCES[$cur_phrase]:-unknown}"

  # Log the rationalization with ABC fields
  bash "${SCRIPT_DIR}/journal.sh" log \
    "rationalization" \
    "${cur_phrase} detected in content" \
    "${cur_correction}" \
    --phrase="${cur_phrase}" \
    --source=rubber-band \
    --event="${EVENT}" \
    --belief="${cur_phrase}" \
    --consequence="${cur_consequence}" \
    --category="${cur_category}" 2>/dev/null || true

  # Log a prediction (behavioral experiment)
  bash "${SCRIPT_DIR}/journal.sh" log \
    "prediction" \
    "${cur_phrase}" \
    "Agent predicted this would be fine without verification" \
    --source=rubber-band \
    --category="${cur_category}" \
    --predicted="pass" \
    --resolved=false 2>/dev/null || true
done

# --- Graduation Logic ---

if [[ "$CATEGORY_COUNT" -ge 10 ]]; then
  # REMIND tier: allow + inject context
  REMIND="Reminder: ${FIRST_CATEGORY} pattern."
  if [[ -n "$EXEMPLAR" ]]; then
    REMIND+=" ${EXEMPLAR}."
  fi
  REMIND+=" You've done this right before."

  jq -n --arg ctx "$REMIND" '{hookSpecificOutput: {additionalContext: $ctx}}'

elif [[ "$CATEGORY_COUNT" -ge 5 ]]; then
  # QUESTION tier: block + cost-benefit analysis
  COST_DATA=$(journal_cost_summary "$FIRST_CATEGORY" 2>/dev/null || echo "0|0|0%|0")
  IFS='|' read -r blocked_commits gate_reruns pred_accuracy sessions_affected <<<"$COST_DATA"

  REASON="COST-BENEFIT: Keeping '${MATCHED_PHRASES[0]}' has cost you:"
  REASON+=" ${blocked_commits} blocked commit(s),"
  REASON+=" ${gate_reruns} gate re-run(s),"
  REASON+=" prediction accuracy ${pred_accuracy},"
  REASON+=" across ${sessions_affected} session(s)."
  REASON+=" Benefit of verifying: zero rework."
  if [[ -n "$EXEMPLAR" ]]; then
    REASON+=" ${EXEMPLAR}."
  fi
  REASON+=" What's your move?"

  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'

else
  # CONFRONT tier: block + correction (original behavior + exemplar)
  REASON="SNAP: Found ${#MATCHED_PHRASES[@]} rationalization(s):"
  for i in "${!MATCHED_PHRASES[@]}"; do
    REASON+=" [${MATCHED_PHRASES[$i]} -> ${MATCHED_CORRECTIONS[$i]}]"
  done
  REASON+=" Rewrite without the rationalizations."
  if [[ -n "$EXEMPLAR" ]]; then
    REASON+=" ${EXEMPLAR}."
  fi

  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
fi
