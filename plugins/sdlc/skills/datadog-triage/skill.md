---
name: datadog-triage
description: Query Datadog API for alerting/warning monitors, investigate each one, then fix real bugs or tune noisy alarms. Filters by environment (default production).
argument-hint: "[env] (default: production) — e.g. 'staging', 'development', or 'all'"
allowed-tools: Read, Glob, Grep, Edit, Write, Bash(curl, gh, git, kubectl, terraform, find, python3, date, jq), Agent, WebFetch
---

# /datadog-triage

Query the Datadog API for monitors in alert, warn, or no-data state, investigate each one, and either fix the underlying issue or tune the alarm to reduce noise.

## Prerequisites

The following environment variables must be set (typically in `~/.zshrc`):
- `DD_API_KEY` — Datadog API key
- `DD_APP_KEY` — Datadog Application key

The Datadog site is `api.datadoghq.com` (US1). If the org moves to a different site, update the `DD_SITE` variable below.

## Instructions

### Step 0: Determine environment and time range

Parse the user's argument: `$ARGUMENTS`

- If empty, default environment is `production`
- If the user provides an environment name, use that (e.g., `staging`, `development`, `all`)
- If the user provides `all`, do not filter by environment
- Time range: last 24 hours unless the user specifies otherwise

### Step 1: Fetch alerting monitors from the Datadog API

Use the Datadog Monitor Search API to find monitors that are alerting, warning, or in no-data state.

```bash
# Set site (default US1)
DD_SITE="${DD_SITE:-api.datadoghq.com}"

# Search for monitors by status
# For a specific environment:
curl -s "https://$DD_SITE/api/v1/monitor/search?query=env:${ENV}" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY"

# For "all" environments, omit the env filter:
curl -s "https://$DD_SITE/api/v1/monitor/search" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY"
```

For each monitor returned, check the `status` field. Focus on monitors that are **not** `OK`:
- `Alert` — actively firing
- `Warn` — warning threshold breached
- `No Data` — monitor is not receiving expected metrics

For monitors in Alert or Warn status, fetch full details including group states:

```bash
curl -s "https://$DD_SITE/api/v1/monitor/${MONITOR_ID}?group_states=all" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY"
```

Extract from each monitor:
- **Monitor name** (e.g., "[arqu-web-production] Frontend Error Count Exceeded")
- **Service** (e.g., arqu-web, core-api, config-api, eventproc, redis-cache, doubtfire-client)
- **Alert type** (e.g., error count, CPU, memory, latency, new error, crash loop)
- **Environment** (from tags or name)
- **Status** (Alert, Warn, No Data, OK)
- **Query** (the Datadog query being evaluated)
- **Thresholds** (critical, warning, recovery)
- **Monitor ID** (for linking to Datadog UI)

Group monitors by priority:
1. **Alert** — actively firing, needs investigation
2. **Warn** — approaching threshold, may need tuning
3. **No Data** — monitors not receiving metrics, may need fixing or silencing

Present a numbered summary table to the user:
```
| # | Monitor | Service | Env | Status | Assessment |
|---|---------|---------|-----|--------|------------|
| 1 | Error Count | arqu-web | prod | ALERT | Investigate |
| 2 | CPU Usage | core-api | prod | Warn | Tune candidate |
| 3 | API Latency | core-api | prod | No Data | Fix or silence |
```

Ask the user which alerts to investigate, or proceed with all Alert + Warn monitors if they say "all".

### Step 2: Investigate each alert

For each alert being investigated, run these diagnostic steps in parallel where possible:

#### 2a: Read the alarm Terraform definition

The alarm definitions live in this repo at:
```
infra/devops/terraform/modules/monitoring/alarms/{service_name}/
```

Service name mapping:
- `arqu-web` -> `arqu_web/`
- `core-api` -> `core_api/`
- `config-api` -> `config_api/`
- `eventproc` -> `eventproc/`
- `redis-cache` -> `redis_cache/`
- `doubtfire-client` -> `doubtfire_client/`
- System-wide -> `system/`

Read the relevant `.tf` file(s) to understand:
- The Datadog query being used
- Current thresholds (critical, warning, recovery)
- What's excluded (negative filters like `-@error.message:*...`)
- Time window (e.g., `last_5m`, `last_15m`)

Also read `locals.tf` and `variables.tf` if present for environment-specific overrides.

#### 2b: Query Datadog for additional context

For monitors in Alert/Warn, fetch recent metric data to understand the trend:

```bash
# Get the monitor's recent state changes
curl -s "https://$DD_SITE/api/v1/monitor/${MONITOR_ID}?group_states=all" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY"
```

Check the `state.groups` in the response to see:
- Which specific groups are alerting (e.g., which queue, which deployment)
- When they last triggered (`last_triggered_ts`)
- Whether they're flapping (frequent state changes)

#### 2c: Investigate the root cause in application code

Based on the alert type, search the relevant application codebases:

- **Error-based alerts**: Search for the error message pattern in the codebase. Use `Grep` and `Glob` to find the source.
- **Performance alerts**: Look at recent changes to the service (`git log --oneline -20` in the service repo)
- **Resource alerts**: Check deployment manifests, recent scaling changes
- **No Data alerts**: Check if the integration/agent is configured correctly, if the metric name changed, or if the service is down

### Step 3: Classify and act

For each alert, classify it as one of:

#### A. Real issue — fix the code
If the alert indicates a genuine bug or regression:
1. Identify the root cause
2. Propose a fix (or implement it if straightforward)
3. Create a branch and commit the fix
4. Present the fix to the user for review

#### B. Noisy alarm — tune the monitor
If the alert is firing on expected/benign behavior:

Common tuning actions (edit the `.tf` file):
1. **Add exclusion filters**: Add `-@error.message:*pattern*` to exclude known benign errors
2. **Raise thresholds**: Increase critical/warning values if the current ones are too sensitive
3. **Widen time window**: Change `last_5m` to `last_15m` to smooth out spikes
4. **Add recovery thresholds**: Add `criticalRecovery` / `warningRecovery` to prevent flapping

Example — adding an exclusion to a RUM error count monitor:
```hcl
# Before
query: "rum(\"service:arqu-web @type:error env:production\").rollup(\"count\").last(\"5m\") > 50"

# After — exclude a known benign error
query: "rum(\"service:arqu-web @type:error -@error.message:*ResizeObserver\\ loop\\ completed* env:production\").rollup(\"count\").last(\"5m\") > 50"
```

IMPORTANT: When editing RUM queries, escape spaces with `\\ ` (double backslash + space) inside the query string. Wildcards use `*`.

#### C. No Data — fix or silence
If a monitor is in "No Data" state:
- Check if the service is actually running and emitting the expected metrics
- If the metric was renamed or removed, update the monitor query
- If the monitor is no longer relevant, suggest adding `notify_no_data: false` or muting it
- If it's a newly deployed monitor that hasn't received data yet, note it as expected

#### D. Transient — no action needed
If the alert triggered once and recovered, and diagnostics show the system is healthy:
- Note it as transient, no action required
- If it happens repeatedly, suggest adding a `renotifyInterval` or minimum duration to prevent noise

### Step 4: Apply changes

For each alarm tune or code fix:

1. Edit the relevant file(s)
2. Show the diff to the user
3. Wait for user approval before committing

When tuning alarms, follow the existing patterns in the `.tf` files:
- Keep the `kubectl_manifest` resource structure
- Preserve existing tags, notification channels, and metadata
- Only modify the `query`, `options.thresholds`, or add exclusion filters

### Step 5: Summary

After processing all alerts, present a summary:

```
## Datadog Triage Summary

### Fixes Applied
- [service] Description of fix (file changed)

### Alarms Tuned
- [monitor-name] What was changed and why (file changed)

### No Action Needed
- [monitor-name] Transient / already recovered

### No Data Monitors
- [monitor-name] Status and recommended action

### Recommended Follow-ups
- Any longer-term suggestions (e.g., "consider splitting this monitor", "add SLO")
```

## Important Notes

- Never silence or delete a monitor entirely — always tune rather than remove
- When adding error exclusions, be specific. Exclude the exact error message pattern, not broad categories
- Preserve the notification routing (`@slack-datadog-{env}`, `@pagerduty-{service}`)
- If unsure whether an alert is real or noise, default to investigating further rather than tuning it away
- The Datadog API uses `DD_API_KEY` and `DD_APP_KEY` from the environment — never hardcode these
- Monitor search API paginates at 50 results per page — handle pagination if needed
- Datadog UI links: `https://app.datadoghq.com/monitors/{monitor_id}` for direct access
