#!/usr/bin/env bash
# _lib_queries.sh — Journal query functions for therapist scripts
#
# Source after _lib.sh:
#   source "${SCRIPT_DIR}/_lib.sh"
#   source "${SCRIPT_DIR}/_lib_queries.sh"

# --- Category Counts ---
# Returns category:count lines from journal entries

journal_category_counts() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    return 0
  fi

  JF="${journal_file}" python3 -c "
import json, os
from collections import Counter

journal_file = os.environ['JF']
counts = Counter()
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            cat = entry.get('category', '')
            if cat:
                counts[cat] += 1
        except json.JSONDecodeError:
            continue

for cat, count in counts.most_common():
    print(f'{cat}:{count}')
"
}

# --- Open Predictions ---
# Returns unresolved prediction entries as JSON lines

journal_open_predictions() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    return 0
  fi

  JF="${journal_file}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
now = datetime.now(timezone.utc)
one_hour_ago = now - timedelta(hours=1)

with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') != 'prediction':
                continue
            if entry.get('resolved', False):
                continue
            ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
            if ts < one_hour_ago:
                continue
            print(json.dumps(entry))
        except (json.JSONDecodeError, ValueError, KeyError):
            continue
"
}

# --- Prediction Accuracy ---
# Returns accuracy stats: percentage, total, correct, and last 3 examples

journal_prediction_accuracy() {
  local category="${1:-}"
  local since="${2:-7d}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    echo "no_data"
    return 0
  fi

  JF="${journal_file}" CAT="${category}" SINCE="${since}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta

journal_file = os.environ['JF']
category_filter = os.environ['CAT']
since_str = os.environ['SINCE']
days = int(since_str.rstrip('d')) if since_str.endswith('d') else 7
cutoff = datetime.now(timezone.utc) - timedelta(days=days)

outcomes = []
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') != 'outcome':
                continue
            ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
            if ts < cutoff:
                continue
            if category_filter and entry.get('category', '') != category_filter:
                continue
            outcomes.append(entry)
        except (json.JSONDecodeError, ValueError):
            continue

if not outcomes:
    print('no_data')
else:
    correct = sum(1 for o in outcomes if o.get('predicted') == o.get('actual'))
    total = len(outcomes)
    pct = int(100 * correct / total) if total else 0
    recent = outcomes[-3:]
    examples = []
    for o in recent:
        pred = o.get('predicted', '?')
        actual = o.get('actual', '?')
        detail = o.get('detail', '')
        mark = 'Y' if pred == actual else 'X'
        examples.append(f'{detail} {mark}')
    print(f'{pct}%|{correct}/{total}|{\"|\".join(examples)}')
"
}

# --- Last Measurement ---
# Returns most recent measurement for a given metric

journal_last_measurement() {
  local metric="${1:?Usage: journal_last_measurement <metric>}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    return 0
  fi

  JF="${journal_file}" M="${metric}" python3 -c "
import json, os

journal_file = os.environ['JF']
metric = os.environ['M']
last = None
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('type') == 'measurement' and entry.get('metric') == metric:
                last = entry
        except json.JSONDecodeError:
            continue

if last:
    print(f'{last.get(\"value\", 0)}|{last.get(\"target\", 0)}|{last.get(\"ts\", \"\")}')
"
}
