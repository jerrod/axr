#!/usr/bin/env bash
# _journal_cmds.sh — Extended journal subcommands
#
# Source after _lib.sh from journal.sh:
#   source "${SCRIPT_DIR}/_lib.sh"
#   source "${SCRIPT_DIR}/_journal_cmds.sh"

# --- Chain (Downward Arrow) ---

cmd_chain() {
  local category="${1:?Usage: journal.sh chain <category>}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"

  if [[ ! -f "${journal_file}" ]]; then
    echo "No journal entries found."
    return 0
  fi

  JF="${journal_file}" CAT="${category}" python3 -c "
import json, os
from datetime import datetime, timezone, timedelta
from collections import defaultdict

journal_file = os.environ['JF']
category = os.environ['CAT']

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

# Group entries into sessions (entries within 2 hours of each other)
cat_entries = [e for e in entries if e.get('category') == category]
if not cat_entries:
    print(f'No entries found for category: {category}')
    exit(0)

sessions = []
current_session = []
for e in cat_entries:
    ts_str = e.get('ts', '')
    if not ts_str:
        continue
    ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    if current_session:
        last_ts_str = current_session[-1].get('ts', '')
        last_ts = datetime.fromisoformat(last_ts_str.replace('Z', '+00:00'))
        if (ts - last_ts).total_seconds() > 7200:
            sessions.append(current_session)
            current_session = []
    current_session.append(e)
if current_session:
    sessions.append(current_session)

print(f'DOWNWARD ARROW: {category} — {len(cat_entries)} incidents across {len(sessions)} session(s)')
print()
for i, session in enumerate(sessions[-5:], 1):
    first_ts = session[0].get('ts', '?')[:16]
    print(f'Session {i} ({first_ts}):')
    for e in session:
        belief = e.get('belief', e.get('phrase', '?'))
        event = e.get('activating_event', e.get('trigger', '?'))
        consequence = e.get('consequence', '?')
        print(f'  Event: {event}')
        print(f'  Belief: \"{belief}\"')
        print(f'  Consequence: {consequence}')
        print()
"
}

# --- ABC Analysis ---

cmd_abc() {
  local group_by="event"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --group-by=*) group_by="${1#--group-by=}" ;;
      *) group_by="$1" ;;
    esac
    shift
  done

  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  if [[ ! -f "${journal_file}" ]]; then
    echo "No journal entries found."
    return 0
  fi

  JF="${journal_file}" GB="${group_by}" python3 -c "
import json, os
from collections import defaultdict, Counter

journal_file = os.environ['JF']
group_by = os.environ['GB']

field_map = {
    'event': 'activating_event',
    'belief': 'belief',
    'consequence': 'consequence',
}
field = field_map.get(group_by, 'activating_event')

groups = defaultdict(Counter)
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = entry.get(field, '')
        if not key:
            continue
        cat = entry.get('category', entry.get('type', 'unknown'))
        groups[key][cat] += 1

if not groups:
    print(f'No ABC entries found (grouped by {group_by}).')
else:
    print(f'ABC Analysis — grouped by {group_by}:')
    for key, cats in sorted(groups.items(), key=lambda x: -sum(x[1].values())):
        total = sum(cats.values())
        top = cats.most_common(3)
        top_str = ', '.join(f'{c}: {n}' for c, n in top)
        print(f'  \"{key}\" ({total} total): {top_str}')
"
}

# --- Exemplar Lookup ---

cmd_exemplar() {
  local category="${1:?Usage: journal.sh exemplar <category>}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"
  local plugin_root="${SCRIPT_DIR}/.."

  # Tier 1: Journal activation entries
  if [[ -f "${journal_file}" ]]; then
    local result
    result=$(JF="${journal_file}" CAT="${category}" python3 -c "
import json, os

journal_file = os.environ['JF']
category = os.environ['CAT']

activations = []
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get('type') == 'activation' and entry.get('category', '') == category:
            activations.append(entry)
        elif entry.get('type') == 'outcome' and entry.get('category', '') == category:
            if entry.get('predicted') == entry.get('actual'):
                activations.append(entry)

if activations:
    last = activations[-1]
    trigger = last.get('trigger', last.get('detail', 'correct behavior'))
    print(f'From your history: {trigger}')
" 2>/dev/null || true)
    if [[ -n "$result" ]]; then
      printf '%s' "$result"
      return 0
    fi
  fi

  # Tier 2: Exposure deck
  local deck_file="${plugin_root}/references/exposure-deck.md"
  if [[ -f "$deck_file" ]]; then
    local result
    result=$(CAT="${category}" DF="${deck_file}" python3 -c "
import os, re

category = os.environ['CAT']
deck_file = os.environ['DF']

cat_to_card = {
    'ownership-avoidance': 'Minimization',
    'premature-closure': 'Premature Closure',
    'scope-deflection': 'Scope Shrinking',
    'learned-helplessness': 'Impossible Bug',
    'effort-avoidance': 'Optimistic Estimate',
}
search_term = cat_to_card.get(category, category)

with open(deck_file) as f:
    content = f.read()

pattern = r'\*\*Correct response:\*\*\s*(.+?)(?:\n\n|\*\*Practice)'
matches = re.findall(pattern, content, re.DOTALL)
for match in matches:
    clean = match.strip().replace('\n', ' ')
    if search_term.lower() in content[:content.index(clean)].split('##')[-1].lower():
        print(f'From exposure deck: {clean[:120]}')
        break
" 2>/dev/null || true)
    if [[ -n "$result" ]]; then
      printf '%s' "$result"
      return 0
    fi
  fi

  # Tier 3: Custom exemplars file
  local custom_file="${plugin_root}/references/exemplars.md"
  if [[ -f "$custom_file" ]]; then
    local result
    result=$(CAT="${category}" CF="${custom_file}" python3 -c "
import os, re

category = os.environ['CAT']
custom_file = os.environ['CF']

with open(custom_file) as f:
    content = f.read()

# Find section matching category
sections = re.split(r'^## ', content, flags=re.MULTILINE)
for section in sections:
    if category.replace('-', ' ') in section.lower() or category in section.lower():
        lines = [l.strip() for l in section.strip().split('\n') if l.strip().startswith('- ')]
        if lines:
            print(f'Custom: {lines[-1].lstrip(\"- \")}')
            break
" 2>/dev/null || true)
    if [[ -n "$result" ]]; then
      printf '%s' "$result"
      return 0
    fi
  fi

  # No exemplar found
  printf ''
}
