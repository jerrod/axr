#!/usr/bin/env bash
# Command configuration helpers for sdlc quality gates.
# Sourced by gate scripts that need explicit command config.
# Requires load-config.sh to be sourced first (sets _SDLC_COMMANDS_CONFIG).
#
# ─── SECURITY / TRUST BOUNDARY ─────────────────────────────────────────────
# The `commands.<gate>.run` field in sdlc.config.json is a SECURITY-CRITICAL
# field. Gate scripts word-split that value and execute it directly. Anyone
# with commit access to sdlc.config.json can therefore execute arbitrary
# commands in CI under the developer's credentials.
#
# Treat changes to `commands.*.run` (and the string-form `commands.<gate>`)
# with the same scrutiny as changes to CI workflow files. As defense in
# depth, `_validate_cmd_run` below restricts the first whitespace token of
# any `run` value to a known set of build/test tool prefixes (bin/, npm,
# pytest, ./gradlew, …). Unrecognized first-tokens are rejected and the
# parsed command is cleared so callers fall back to their built-in defaults.
# The allowlist is intentionally narrow — extending it requires reviewing
# the new prefix against the same trust-boundary criteria.
# ───────────────────────────────────────────────────────────────────────────
set -uo pipefail

# _validate_cmd_run <cmd_run>
# Defense-in-depth allowlist for the first token of a `run` field. Returns 0
# if the first whitespace-separated token is a recognized build/test tool
# prefix; returns 1 (and prints a warning to stderr) otherwise.
_validate_cmd_run() {
  local cmd_run="$1"
  # Reject embedded newlines before word-splitting: a multi-line run value
  # would split into separate array elements, any of which could be treated
  # as a distinct command by the caller's `"${_cmd_array[@]}"` execution.
  case "$cmd_run" in
    *$'\n'*)
      echo "commands-config: rejecting run field containing newline" >&2
      return 1
      ;;
  esac
  local first_token="${cmd_run%% *}"
  case "$first_token" in
    bin/*|./bin/*|./gradlew|./gradlew/*) return 0 ;;
    bin|npm|npx|yarn|pnpm|bun|pytest|python3|python|uv|cargo|go|gradle|mvn|make|bundle|rake|bash|sh|ruby) return 0 ;;
    *)
      echo "commands-config: rejecting unsafe command first-token '$first_token' in run field; only known build/test tools allowed" >&2
      return 1
      ;;
  esac
}

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
" "$_SDLC_COMMANDS_CONFIG" "$gate" 2>/dev/null || true
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
  if [ -n "$_CMD_RUN" ] && ! _validate_cmd_run "$_CMD_RUN"; then
    _CMD_RUN=""
    _CMD_FORMAT=""
    _CMD_REPORT=""
  fi
}
