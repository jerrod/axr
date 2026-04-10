#!/usr/bin/env bash
# Threshold and allow-list helpers sourced by load-config.sh.
# Exposes: get_threshold, resolve_all_thresholds, is_allowed,
#          report_unused_allow_entries, print_allow_hint.
#
# Consumers of these functions should source load-config.sh, NOT this file directly.

# _RQ_SCRIPT_DIR locates sibling Python modules (path_match.py, is_allowed_check.py).
_RQ_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export _RQ_SCRIPT_DIR

# get_threshold <filename> <threshold_key>
# Resolves per-path, then per-extension override. Prints value or "null" (meaning skip).
# Priority: path overrides > extension defaults > global defaults.
get_threshold() {
  local file="$1"
  local key="$2"
  python3 -c "
import json, os, sys
sys.path.insert(0, os.environ['_RQ_SCRIPT_DIR'])
from path_match import path_match
path_config = json.loads(sys.argv[1])
ext_config = json.loads(sys.argv[2])
global_config = json.loads(sys.argv[3])
filepath = sys.argv[4]
key = sys.argv[5]
for pattern, overrides in path_config.items():
    if path_match(filepath, pattern) and key in overrides:
        val = overrides[key]
        print('null' if val is None else val)
        sys.exit(0)
ext = os.path.splitext(filepath)[1].lstrip('.')
if ext in ext_config and key in ext_config[ext]:
    val = ext_config[ext][key]
    print('null' if val is None else val)
else:
    print(global_config.get(key, 'null'))
" "$_RQ_PATH_CONFIG" "$_RQ_EXT_CONFIG" "$_RQ_GLOBAL_CONFIG" "$file" "$key" 2>/dev/null
}

# resolve_all_thresholds <file_list_file> <threshold_key>
# Batch mode: reads file paths from file, outputs path\tvalue pairs.
resolve_all_thresholds() {
  local file_list="$1"
  local key="$2"
  python3 -c "
import json, os, sys
sys.path.insert(0, os.environ['_RQ_SCRIPT_DIR'])
from path_match import path_match
path_config = json.loads(sys.argv[1])
ext_config = json.loads(sys.argv[2])
global_config = json.loads(sys.argv[3])
key = sys.argv[5]
with open(sys.argv[4]) as f:
    for line in f:
        path = line.strip()
        if not path:
            continue
        matched = False
        for pattern, overrides in path_config.items():
            if path_match(path, pattern) and key in overrides:
                val = overrides[key]
                print(f'{path}\tnull' if val is None else f'{path}\t{val}')
                matched = True
                break
        if matched:
            continue
        ext = os.path.splitext(path)[1].lstrip('.')
        if ext in ext_config and key in ext_config[ext]:
            val = ext_config[ext][key]
            threshold = 'null' if val is None else val
            print(f'{path}\t{threshold}')
        else:
            default = global_config.get(key, 'null')
            print(f'{path}\t{default}')
" "$_RQ_PATH_CONFIG" "$_RQ_EXT_CONFIG" "$_RQ_GLOBAL_CONFIG" "$file_list" "$key" 2>/dev/null
}

# is_allowed <gate> <field1=value1> [field2=value2 ...]
# Returns 0 if the violation matches an allow-list entry (skip it).
# Returns 1 if not allowed (report it).
# Usage: is_allowed "dead-code" "file=src/models.py" "name=annotations" "type=unused_import"
is_allowed() {
  local gate="$1"
  shift
  [ -n "${_RQ_ALLOW_CONFIG:-}" ] || return 1
  python3 "$_RQ_SCRIPT_DIR/is_allowed_check.py" "$_RQ_ALLOW_CONFIG" "$gate" "$@" 2>/dev/null
}

# report_unused_allow_entries <gate>
# Reads the gate's tracking JSONL and the full allow config.
# For each entry that didn't match anything, prints a warning to stderr.
# Never fails — warnings are advisory.
report_unused_allow_entries() {
  local gate="$1"
  local proof_dir="${PROOF_DIR:-.quality/proof}"
  local tracking_file="$proof_dir/allow-tracking-$gate.jsonl"

  python3 "$_RQ_SCRIPT_DIR/report_unused_entries.py" "$_RQ_ALLOW_CONFIG" "$gate" "$tracking_file" || true
}
export -f report_unused_allow_entries

# print_allow_hint <gate-name>
# Prints a hint to stderr showing how to add an exception for the failing gate.
print_allow_hint() {
  local gate="$1"
  cat <<EOF >&2

To exempt a file from this gate: add an entry to sdlc.config.json → allow.$gate
  { "file": "path/to/file", "reason": "explain why (15+ chars)" }
EOF
}
export -f print_allow_hint
