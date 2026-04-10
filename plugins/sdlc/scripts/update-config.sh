#!/usr/bin/env bash
# Shared config and snooze helpers for sdlc-update and session-start.
# Sourced, not executed directly.

STATE_DIR="$HOME/.claude/plugins/data/sdlc"
SNOOZE_FILE="$STATE_DIR/update-snoozed"
UPDATE_CONFIG_FILE="$STATE_DIR/update-config.json"

mkdir -p "$STATE_DIR"

read_config() {
  local key="$1"
  local default="${2:-}"
  if [ -f "$UPDATE_CONFIG_FILE" ]; then
    SDLC_CFG="$UPDATE_CONFIG_FILE" SDLC_KEY="$key" SDLC_DEF="$default" python3 -c "
import json, os
data = json.load(open(os.environ['SDLC_CFG']))
print(data.get(os.environ['SDLC_KEY'], os.environ['SDLC_DEF']))
" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

write_config() {
  local key="$1"
  local value="$2"
  local data="{}"
  [ -f "$UPDATE_CONFIG_FILE" ] && data=$(cat "$UPDATE_CONFIG_FILE")
  SDLC_DATA="$data" SDLC_KEY="$key" SDLC_VAL="$value" SDLC_OUT="$UPDATE_CONFIG_FILE" python3 -c "
import json, os
data = json.loads(os.environ['SDLC_DATA'])
data[os.environ['SDLC_KEY']] = os.environ['SDLC_VAL']
json.dump(data, open(os.environ['SDLC_OUT'], 'w'), indent=2)
" 2>/dev/null
}

# Snooze file format (one-line, space-separated):
#   <literal "snooze"> <level 1-3> <unix-timestamp>
# The leading "snooze" sentinel is checked by validate_snooze_file before use,
# so any other shape (empty, truncated, foreign) is treated as "no snooze".
validate_snooze_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  local first_word
  read -r first_word _ _ <"$file"
  [ "$first_word" = "snooze" ]
}

is_snoozed() {
  [ ! -f "$SNOOZE_FILE" ] && return 1
  validate_snooze_file "$SNOOZE_FILE" || return 1
  # Format: snooze <level> <unix-ts>
  read -r _snz_ver _snz_level _snz_ts <"$SNOOZE_FILE"
  local now
  now=$(date +%s)
  local ttl
  case "$_snz_level" in
    1) ttl=86400 ;;  # 24h
    2) ttl=172800 ;; # 48h
    *) ttl=604800 ;; # 1 week
  esac
  [ $((now - _snz_ts)) -lt "$ttl" ]
}

# do_snooze writes the snooze file in the format documented above
# (snooze <level> <unix-ts>). When extending the level, a corrupted or
# foreign existing file is treated as "no snooze in effect" — level resets to 0.
do_snooze() {
  local cur_level=0
  if validate_snooze_file "$SNOOZE_FILE"; then
    # Format: snooze <level> <unix-ts>
    read -r _sv cur_level _st <"$SNOOZE_FILE"
    case "$cur_level" in *[!0-9]*) cur_level=0 ;; esac
  fi
  local new_level=$((cur_level + 1))
  [ "$new_level" -gt 3 ] && new_level=3
  echo "snooze $new_level $(date +%s)" >"$SNOOZE_FILE"
  local duration
  case "$new_level" in
    1) duration="24 hours" ;;
    2) duration="48 hours" ;;
    *) duration="1 week" ;;
  esac
  echo "Snoozed for $duration. Run /sdlc-update to check manually."
  echo "Tip: /sdlc-update --auto-on for automatic updates."
}

snooze_status() {
  if [ -f "$SNOOZE_FILE" ]; then
    if ! validate_snooze_file "$SNOOZE_FILE"; then
      echo "no"
      return 0
    fi
    # Format: snooze <level> <unix-ts>
    read -r _snz_ver snz_level snz_ts <"$SNOOZE_FILE"
    local now ttl remaining
    now=$(date +%s)
    case "$snz_level" in
      1) ttl=86400 ;;
      2) ttl=172800 ;;
      *) ttl=604800 ;;
    esac
    remaining=$(((snz_ts + ttl - now) / 3600))
    if [ "$remaining" -gt 0 ]; then
      echo "${remaining}h remaining (level $snz_level)"
    else
      echo "expired"
    fi
  else
    echo "no"
  fi
}
