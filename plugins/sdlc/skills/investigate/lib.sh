#!/usr/bin/env bash
# Helper functions for /sdlc:investigate.
# Source this file from SKILL.md Bash blocks. Functions normalize backend
# output and fail soft when credentials are missing.
# Requires bash (uses ${var:N:M} substring syntax).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || {
  echo "ERROR: lib.sh requires bash" >&2
  return 1
}

DD_SITE="${DD_SITE:-api.datadoghq.com}"

_log_warn() { echo "WARN: $*" >&2; }
_log_err() { echo "ERROR: $*" >&2; }

# ─── Input validation ────────────────────────────────────────────

_validate_name() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    _log_err "Invalid $label: '$value' (must match [a-zA-Z0-9_.-]+)"
    return 1
  fi
}

_validate_hours() {
  local hours="$1"
  if [[ ! "$hours" =~ ^[0-9]+$ ]]; then
    _log_err "Invalid hours value: '$hours' (must be a positive integer)"
    return 1
  fi
}

# ─── Credential checks ──────────────────────────────────────────

_VALID_DD_SITES="api.datadoghq.com api.datadoghq.eu api.us3.datadoghq.com api.us5.datadoghq.com api.ap1.datadoghq.com"

_require_dd() {
  if [ -z "${DD_API_KEY:-}" ] || [ -z "${DD_APP_KEY:-}" ]; then
    _log_err "DD_API_KEY and DD_APP_KEY must be set in env"
    return 1
  fi
  local valid=false site
  for site in $_VALID_DD_SITES; do
    [ "$DD_SITE" = "$site" ] && valid=true && break
  done
  if [ "$valid" = "false" ]; then
    _log_err "DD_SITE '$DD_SITE' is not a recognized Datadog endpoint"
    return 1
  fi
}

_require_gcloud() {
  if ! command -v gcloud >/dev/null 2>&1; then
    _log_err "gcloud CLI not installed"
    return 1
  fi
}

_require_slack() {
  if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    _log_warn "SLACK_BOT_TOKEN not set — skipping Slack"
    return 1
  fi
}

# ─── Shared helpers ──────────────────────────────────────────────

_dd_time_window() {
  local hours="$1"
  _validate_hours "$hours" || return 1
  to_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  from_ts=$(date -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ)
}

# ─── Datadog Logs ────────────────────────────────────────────────
# Usage: dd_logs_search <service> <hours>
dd_logs_search() {
  _require_dd || return 1
  local service="$1" hours="${2:-1}"
  _validate_name "service" "$service" || return 1
  local from_ts to_ts
  _dd_time_window "$hours" || return 1

  curl -sS -X POST "https://${DD_SITE}/api/v2/logs/events/search" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg svc "$service" --arg from "$from_ts" --arg to "$to_ts" \
      '{filter:{query:("service:"+$svc+" status:error"),from:$from,to:$to},
        sort:"-timestamp",page:{limit:200}}')" |
    jq -r '.data[]? | {
      ts:    .attributes.timestamp,
      msg:   (.attributes.message // .attributes.attributes.error.message // "(no message)"),
      trace: .attributes.attributes.trace_id
    } | "\(.ts)\t\(.trace // "-")\t\(.msg | gsub("\n";" ") | .[0:240])"' |
    sort | uniq -c | sort -rn | head -20
}

# ─── Datadog RUM ─────────────────────────────────────────────────
# Usage: dd_rum_search <service> <hours>
dd_rum_search() {
  _require_dd || return 1
  local service="$1" hours="${2:-1}"
  _validate_name "service" "$service" || return 1
  local from_ts to_ts
  _dd_time_window "$hours" || return 1

  curl -sS -X POST "https://${DD_SITE}/api/v2/rum/events/search" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg svc "$service" --arg from "$from_ts" --arg to "$to_ts" \
      '{filter:{query:("service:"+$svc+" @type:error"),from:$from,to:$to},
        sort:"-timestamp",page:{limit:200}}')" |
    jq -r '.data[]? | {
      url:     .attributes.attributes.view.url,
      msg:    (.attributes.attributes.error.message // "(no message)"),
      browser: .attributes.attributes.browser.name
    } | "\(.browser // "-")\t\(.url // "-")\t\(.msg | gsub("\n";" ") | .[0:240])"' |
    sort | uniq -c | sort -rn | head -20
}

# ─── Datadog APM Spans ───────────────────────────────────────────
# Usage: dd_spans_search <service> <hours>
dd_spans_search() {
  _require_dd || return 1
  local service="$1" hours="${2:-1}"
  _validate_name "service" "$service" || return 1
  local from_ts to_ts
  _dd_time_window "$hours" || return 1

  curl -sS -X POST "https://${DD_SITE}/api/v2/spans/events/search" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg svc "$service" --arg from "$from_ts" --arg to "$to_ts" \
      '{filter:{query:("service:"+$svc+" status:error"),from:$from,to:$to},
        sort:"-timestamp",page:{limit:50}}')" |
    jq -r '.data[]? | {
      trace:    .attributes.trace_id,
      resource: .attributes.resource_name,
      err:     (.attributes.attributes.error.message // "-")
    } | "https://app.datadoghq.com/apm/trace/\(.trace)\t\(.resource)\t\(.err | .[0:200])"' |
    head -20
}

# ─── Google Cloud Logging ────────────────────────────────────────
# Usage: gcloud_logs <container_name> <hours>
gcloud_logs() {
  _require_gcloud || return 1
  local container="$1" hours="${2:-1}"
  _validate_name "container" "$container" || return 1
  _validate_hours "$hours" || return 1
  local freshness="${hours}h"
  gcloud logging read \
    "resource.type=\"k8s_container\" AND resource.labels.container_name=\"${container}\" AND severity>=ERROR" \
    --limit=200 --format=json --freshness="${freshness}" 2>/dev/null |
    jq -r '.[] | "\(.timestamp)\t\(.severity)\t\((.jsonPayload.message // .textPayload // "-") | gsub("\n";" ") | .[0:240])"' |
    sort | uniq -c | sort -rn | head -20
}

# ─── Slack ───────────────────────────────────────────────────────
# Usage: slack_post <channel> <text>
slack_post() {
  _require_slack || return 1
  local channel="$1" text="$2"
  local resp ok err
  resp=$(curl -sS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -nc --arg c "$channel" --arg t "$text" \
      '{channel:$c, text:$t, unfurl_links:false, unfurl_media:false}')")
  ok=$(echo "$resp" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    err=$(echo "$resp" | jq -r '.error // "unknown"')
    _log_warn "Slack post failed: $err"
    return 1
  fi
  echo "Posted to Slack channel ${channel}"
}

# Usage: slack_thread_fetch <slack-thread-url>
slack_thread_fetch() {
  _require_slack || return 1
  local url="$1"
  local channel ts resp ok
  channel=$(echo "$url" | sed -nE 's#.*/archives/([A-Z0-9]+)/.*#\1#p')
  ts=$(echo "$url" | sed -nE 's#.*/p([0-9]+).*#\1#p')
  if [ -z "$channel" ] || [ -z "$ts" ]; then
    _log_err "Could not parse Slack URL: $url"
    return 1
  fi
  # Convert p1234567890123456 → 1234567890.123456
  ts="${ts:0:10}.${ts:10}"
  resp=$(curl -sS "https://slack.com/api/conversations.replies?channel=${channel}&ts=${ts}" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}")
  ok=$(echo "$resp" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    _log_warn "slack_thread_fetch failed: $(echo "$resp" | jq -r '.error // "unknown"')"
    return 1
  fi
  echo "$resp" | jq -r '.messages[]? | "[\(.user // "?")] \(.text)"'
}
