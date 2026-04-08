#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# affirmation.sh — SessionStart command hook
#
# Reads journal history and generates a personalized affirmation
# based on distortion patterns, trends, and streaks.
# Enhanced with:
#   - Relapse prevention: detailed risk profiles with coping strategies
#   - Downward arrow auto-trigger: root cause analysis at 15+ incidents
#   - Prediction accuracy trends
#   - Streak tracking
#
# Output: SessionStart JSON with additionalContext

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_queries.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"

ensure_therapist_dir

JOURNAL_FILE="${THERAPIST_DIR}/journal.jsonl"
STREAK_FILE="${THERAPIST_DIR}/streak.json"

# --- Update streak data ---

update_streak() {
  if [[ ! -f "$JOURNAL_FILE" ]]; then
    printf '{"consecutive_clean_sessions":1}' >"$STREAK_FILE"
    return
  fi

  JF="$JOURNAL_FILE" SF="$STREAK_FILE" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
streak_file = os.environ['SF']
now = datetime.now(timezone.utc)
yesterday = now - timedelta(days=1)

# Count distortion entries in last 24 hours
distortion_types = {'rationalization', 'quality-failure', 'frustration-pattern', 'socratic-code'}
recent_distortions = 0
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') in distortion_types:
                ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
                if ts >= yesterday:
                    recent_distortions += 1
        except (json.JSONDecodeError, ValueError):
            continue

# Update streak
streak_data = {'consecutive_clean_sessions': 0}
if os.path.exists(streak_file):
    try:
        with open(streak_file) as f:
            streak_data = json.loads(f.read())
    except (json.JSONDecodeError, IOError):
        pass

if recent_distortions == 0:
    streak_data['consecutive_clean_sessions'] = streak_data.get('consecutive_clean_sessions', 0) + 1
else:
    streak_data['consecutive_clean_sessions'] = 0

with open(streak_file, 'w') as f:
    json.dump(streak_data, f)
"
}

# --- Generate base affirmation ---

generate_affirmation() {
  if [[ ! -f "$JOURNAL_FILE" ]]; then
    echo "Fresh session. Remember your standards — they exist because they work."
    return
  fi

  JF="$JOURNAL_FILE" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta
from collections import Counter

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
week_ago = now - timedelta(days=7)
two_weeks_ago = now - timedelta(days=14)

recent = Counter()
prior = Counter()
all_entries = []

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            ts_str = entry.get('ts', '')
            if not ts_str:
                continue
            ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
            all_entries.append((ts, entry))
            if ts >= week_ago:
                recent[entry.get('type', 'unknown')] += 1
            elif ts >= two_weeks_ago:
                prior[entry.get('type', 'unknown')] += 1
        except (json.JSONDecodeError, ValueError):
            continue

if not all_entries:
    print('Fresh session. Remember your standards — they exist because they work.')
elif sum(recent.values()) == 0:
    last_ts = max(ts for ts, _ in all_entries)
    days = (now - last_ts).days
    print(f'{days} day(s) with zero distortion incidents. The work is working.')
elif sum(recent.values()) < sum(prior.values()):
    top = recent.most_common(1)[0] if recent else ('unknown', 0)
    print(f'{top[0]} incidents dropped from {prior.get(top[0], 0)} to {top[1]} over the past week. Progress.')
elif recent.most_common(1):
    top_type, top_count = recent.most_common(1)[0]
    print(f'{top_type} has fired {top_count} time(s) this week. Consider: am I running tools before claiming results?')
else:
    print('Fresh session. Remember your standards — they exist because they work.')
"
}

# --- Generate prediction accuracy trends ---

generate_prediction_trends() {
  if [[ ! -f "$JOURNAL_FILE" ]]; then
    return
  fi

  local accuracy_data
  accuracy_data=$(journal_prediction_accuracy "" "7d" 2>/dev/null || true)
  if [[ -n "$accuracy_data" ]] && [[ "$accuracy_data" != "no_data" ]]; then
    IFS='|' read -r pct ratio rest <<<"$accuracy_data"
    echo "Prediction accuracy this week: ${pct} (${ratio})."
  fi
}

# --- Downward arrow auto-trigger (15+ incidents in a category) ---

generate_downward_arrow() {
  local counts
  counts=$(journal_category_counts 2>/dev/null || true)

  if [[ -z "$counts" ]]; then
    return
  fi

  while IFS=: read -r cat count; do
    [[ -z "$cat" ]] && continue
    if [[ "$count" -ge 15 ]]; then
      local chain_output
      chain_output=$(bash "${SCRIPT_DIR}/journal.sh" chain "$cat" 2>/dev/null | head -10 || true)
      if [[ -n "$chain_output" ]]; then
        echo "AUTO-DIAGNOSIS: ${cat} has ${count} incidents. Root cause analysis:"
        echo "$chain_output"
      fi
      break
    fi
  done <<<"$counts"
}

# --- Risk profile ---

generate_risk_profile() {
  local risk_output
  risk_output=$(journal_risk_profile 2>/dev/null || true)

  if [[ -n "$risk_output" ]] && [[ "$risk_output" != "No significant risk patterns"* ]]; then
    echo "$risk_output"
  fi
}

# --- Main ---

update_streak

AFFIRMATION=$(generate_affirmation)
PRED_TRENDS=$(generate_prediction_trends 2>/dev/null || true)
DOWNWARD=$(generate_downward_arrow 2>/dev/null || true)
RISK=$(generate_risk_profile 2>/dev/null || true)

MSG="THERAPIST SESSION NOTE: ${AFFIRMATION}"

if [[ -n "$PRED_TRENDS" ]]; then
  MSG+=$'\n'"${PRED_TRENDS}"
fi

if [[ -n "$DOWNWARD" ]]; then
  MSG+=$'\n'"${DOWNWARD}"
fi

if [[ -n "$RISK" ]]; then
  MSG+=$'\n'"${RISK}"
fi

# Read streak for message
if [[ -f "$STREAK_FILE" ]]; then
  STREAK=$(jq -r '.consecutive_clean_sessions // 0' "$STREAK_FILE" 2>/dev/null || echo "0")
  if [[ "$STREAK" -gt 1 ]]; then
    MSG+=$'\n'"Clean streak: ${STREAK} consecutive session(s)."
  fi
fi

jq -n --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
