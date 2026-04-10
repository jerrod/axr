#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# journal.sh — Therapy journal for tracking distortion incidents
#
# Usage:
#   journal.sh log <type> <trigger> <correction> [--phrase=X] [--source=Y] ...
#   journal.sh recent [N]    — show last N entries (default 10)
#   journal.sh stats         — distortion frequency and counts
#   journal.sh streak        — days since last incident per type
#   journal.sh chain <cat>   — downward arrow: session-grouped timeline
#   journal.sh abc [--group-by=event|belief|consequence]
#   journal.sh exemplar <cat> — three-tier exemplar lookup
#   journal.sh risk-profile  — risk assessment from journal data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_analytics.sh"
source "${SCRIPT_DIR}/_journal_cmds.sh"

# --- Subcommands ---

cmd_log() {
  if [[ $# -lt 3 ]]; then
    echo "Usage: journal.sh log <type> <trigger> <correction> [--key=value ...]" >&2
    exit 1
  fi

  local type="$1" trigger="$2" correction="$3"
  shift 3

  journal_log "$type" "$trigger" "$correction" "$@"
  echo "Logged: ${type} — ${trigger}"
}

cmd_recent() {
  local count="${1:-10}"
  local journal_file="${THERAPIST_DIR}/journal.jsonl"

  if [[ ! -f "${journal_file}" ]]; then
    echo "No journal entries found."
    return 0
  fi

  JF="${journal_file}" N="${count}" python3 -c "
import json, os

journal_file = os.environ['JF']
n = int(os.environ['N'])
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

for entry in entries[-n:]:
    ts = entry.get('ts', '?')
    dtype = entry.get('type', '?')
    trigger = entry.get('trigger', '?')
    correction = entry.get('correction', '?')
    source = entry.get('source', '')
    phrase = entry.get('phrase', '')
    parts = [f'[{ts}] {dtype}']
    if phrase:
        parts.append(f'phrase=\"{phrase}\"')
    parts.append(f'trigger=\"{trigger}\"')
    parts.append(f'correction=\"{correction}\"')
    if source:
        parts.append(f'(via {source})')
    print(' | '.join(parts))
"
}

cmd_stats() {
  journal_stats
}

cmd_streak() {
  local journal_file="${THERAPIST_DIR}/journal.jsonl"

  if [[ ! -f "${journal_file}" ]]; then
    echo "No journal entries — clean streak from the start."
    return 0
  fi

  JF="${journal_file}" python3 -c "
import json, os
from datetime import datetime, timezone

journal_file = os.environ['JF']
last_seen = {}
with open(journal_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            dtype = entry.get('type', 'unknown')
            ts_str = entry.get('ts', '')
            if ts_str:
                ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                if dtype not in last_seen or ts > last_seen[dtype]:
                    last_seen[dtype] = ts
        except (json.JSONDecodeError, ValueError):
            continue

if not last_seen:
    print('No distortions recorded — clean streak from the start.')
else:
    now = datetime.now(timezone.utc)
    print('Days since last incident:')
    for dtype, ts in sorted(last_seen.items(), key=lambda x: x[1]):
        days = (now - ts).days
        print(f'  {dtype}: {days} day(s)')
"
}

cmd_risk_profile() {
  journal_risk_profile
}

# --- Dispatch ---

cmd="${1:-help}"
shift || true

case "$cmd" in
  log) cmd_log "$@" ;;
  recent) cmd_recent "$@" ;;
  stats) cmd_stats ;;
  streak) cmd_streak ;;
  chain) cmd_chain "$@" ;;
  abc) cmd_abc "$@" ;;
  exemplar) cmd_exemplar "$@" ;;
  risk-profile) cmd_risk_profile ;;
  help | --help | -h)
    echo "Usage: journal.sh <command> [args]"
    echo ""
    echo "  log <type> <trigger> <correction> [--phrase=X] [--source=Y] ..."
    echo "  recent [N]         Show last N entries (default 10)"
    echo "  stats              Distortion frequency counts"
    echo "  streak             Days since last incident per type"
    echo "  chain <category>   Downward arrow session timeline"
    echo "  abc [--group-by=X] ABC analysis (event|belief|consequence)"
    echo "  exemplar <cat>     Three-tier exemplar lookup"
    echo "  risk-profile       Risk assessment from journal patterns"
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    echo "Usage: journal.sh <command> [args]" >&2
    exit 1
    ;;
esac
