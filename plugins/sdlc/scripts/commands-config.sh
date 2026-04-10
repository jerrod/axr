#!/usr/bin/env bash
# Command configuration helpers for sdlc quality gates.
# Sourced by gate scripts that need explicit command config.
# Requires load-config.sh to be sourced first (sets _RQ_COMMANDS_CONFIG).
set -uo pipefail

# get_command <gate>
# Returns the command config for a gate from sdlc.config.json commands section.
# String commands: returns the string. Object commands: returns JSON string.
# Returns empty string if gate has no command configured.
get_command() {
  local gate="$1"
  python3 -c "
import json, sys
commands = json.loads(sys.argv[1])
gate = sys.argv[2]
cmd = commands.get(gate)
if cmd is None:
    pass  # print nothing
elif isinstance(cmd, str):
    print(cmd)
else:
    print(json.dumps(cmd))
" "$_RQ_COMMANDS_CONFIG" "$gate" 2>/dev/null || true
}

# parse_command_config <json_string>
# Parse an object-form command config into shell variables.
# Sets: _CMD_RUN, _CMD_FORMAT, _CMD_REPORT
# For string-form commands, get_command returns the string directly — don't call this.
parse_command_config() {
  local config="$1"
  _CMD_RUN=$(echo "$config" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('run',''))" 2>/dev/null || echo "")
  _CMD_FORMAT=$(echo "$config" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('format',''))" 2>/dev/null || echo "")
  _CMD_REPORT=$(echo "$config" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('report_path',''))" 2>/dev/null || echo "")
}
