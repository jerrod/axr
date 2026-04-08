#!/usr/bin/env bash
# _lib_analytics.sh — Journal analytics functions for therapist scripts
#
# Source after _lib.sh:
#   source "${SCRIPT_DIR}/_lib.sh"
#   source "${SCRIPT_DIR}/_lib_analytics.sh"

# --- Resolution Rate ---
# Returns resolution stats for a pattern type

journal_resolution_rate() {
  local pattern="${1:?Usage: journal_resolution_rate <pattern>}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    echo "no_data"
    return 0
  fi

  JF="${journal_file}" P="${pattern}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
pattern = os.environ['P']

entries = []
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

pattern_entries = []
activation_times = []
for e in entries:
    if e.get('type') == pattern or e.get('trigger', '').startswith(pattern):
        pattern_entries.append(e)
    if e.get('type') in ('activation', 'measurement'):
        ts_str = e.get('ts', '')
        if ts_str:
            try:
                activation_times.append(
                    datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                )
            except ValueError:
                pass

if not pattern_entries:
    print('no_data')
else:
    total = len(pattern_entries)
    resolved = 0
    for pe in pattern_entries:
        pe_ts_str = pe.get('ts', '')
        if not pe_ts_str:
            continue
        try:
            pe_ts = datetime.fromisoformat(pe_ts_str.replace('Z', '+00:00'))
        except ValueError:
            continue
        window = pe_ts + timedelta(hours=2)
        if any(pe_ts < at <= window for at in activation_times):
            resolved += 1
    pct = int(100 * resolved / total) if total else 0
    print(f'{pct}%|{resolved}/{total}')
"
}

# --- Cost Summary ---
# Returns cost data for a distortion category

journal_cost_summary() {
  local category="${1:?Usage: journal_cost_summary <category>}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    echo "no_data"
    return 0
  fi

  JF="${journal_file}" CAT="${category}" python3 -c "
import json, os
from collections import Counter

journal_file = os.environ['JF']
category = os.environ['CAT']

blocked_commits = 0
gate_reruns = 0
sessions = set()
predictions_correct = 0
predictions_total = 0

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        cat = entry.get('category', '')
        if cat != category:
            if entry.get('type') == 'outcome' and entry.get('category') == category:
                predictions_total += 1
                if entry.get('predicted') == entry.get('actual'):
                    predictions_correct += 1
            continue
        etype = entry.get('type', '')
        ts = entry.get('ts', '')[:10]
        if ts:
            sessions.add(ts)
        src = entry.get('source', '')
        if src == 'pause':
            blocked_commits += 1
        if etype == 'quality-failure':
            gate_reruns += 1

pred_acc = '0%'
if predictions_total > 0:
    pred_acc = f'{int(100 * predictions_correct / predictions_total)}%'
print(f'{blocked_commits}|{gate_reruns}|{pred_acc}|{len(sessions)}')
"
}

# --- Risk Profile ---
# Correlates activating events with categories, detects fatigue

journal_risk_profile() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    return 0
  fi

  JF="${journal_file}" python3 -c "
import json, os
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
month_ago = now - timedelta(days=30)

event_category = defaultdict(Counter)
category_times = defaultdict(list)
entries = []

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            entries.append(entry)
        except json.JSONDecodeError:
            continue

for entry in entries:
    ts_str = entry.get('ts', '')
    if not ts_str:
        continue
    try:
        ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    except ValueError:
        continue
    if ts < month_ago:
        continue
    cat = entry.get('category', '')
    event = entry.get('activating_event', '')
    if cat and event:
        event_category[event][cat] += 1
    if cat:
        category_times[cat].append(ts)

risks = []

# Risk 1: Event-category correlations
for event, cats in event_category.items():
    total = sum(cats.values())
    if total < 3:
        continue
    top_cat, top_count = cats.most_common(1)[0]
    pct = int(100 * top_count / total)
    if pct >= 60:
        risks.append(
            f'RISK: {top_cat} correlates with \"{event}\" tasks '
            f'({top_count}/{total} = {pct}%).'
            f'\nCOPING: Run verification tools immediately when '
            f'working on {event}. Measure before forming opinions.'
        )

# Risk 2: Fatigue pattern (incidents increase later in sessions)
for cat, times in category_times.items():
    if len(times) < 5:
        continue
    sessions = defaultdict(list)
    for t in times:
        day = t.strftime('%Y-%m-%d')
        sessions[day].append(t)
    late_count = 0
    total_count = 0
    for day, day_times in sessions.items():
        if len(day_times) < 2:
            continue
        first = min(day_times)
        for t in day_times:
            total_count += 1
            if (t - first).total_seconds() > 3600:
                late_count += 1
    if total_count >= 5 and late_count > total_count * 0.5:
        risks.append(
            f'RISK: {cat} incidents increase after 1+ hour in session '
            f'(fatigue pattern: {late_count}/{total_count} late).'
            f'\nCOPING: After 1 hour of work, run grounding.sh to '
            f'measure objective state before continuing.'
        )

if risks:
    for r in risks[:3]:
        print(r)
else:
    print('No significant risk patterns detected in the last 30 days.')
"
}
