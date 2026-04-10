---
name: investigate
description: Systematic root-cause debugging across Datadog logs/RUM/APM, Google Cloud logging, and the local codebase. Mirrors the gstack /investigate discipline (Iron Law, 3-strike rule, regression test, structured DEBUG REPORT) and routes per service. Optionally posts findings to Slack.
argument-hint: "<symptom or service:error description, optionally a Slack thread URL>"
allowed-tools: Read, Glob, Grep, Edit, Write, Bash(curl, gh, git, gcloud, jq, date, find, python3), Agent, WebFetch
---

# /sdlc:investigate

Systematic debugging skill. Driven by symptom, not by monitor.

## Iron Law

**NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.** Fixing symptoms creates whack-a-mole debugging.

## Prerequisites

Required for full functionality (skill fails soft when missing):

| Variable | Purpose | Required for |
|----------|---------|-------------|
| `DD_API_KEY` | Datadog API key | core-api, core-consumer, RUM (arqu-web) |
| `DD_APP_KEY` | Datadog Application key | same as above |
| `gcloud` CLI authenticated | Google Cloud logging | arqu-atlas-* services |
| `SLACK_BOT_TOKEN` | Slack bot token (`xoxb-...`) | optional Slack pull/push |

Datadog site default: `api.datadoghq.com` (US1). Override with `DD_SITE`.

## Service routing (heuristic, not a fixed list)

The skill does NOT hardcode a service catalog. **Datadog APM traces are
available for every service** — always query traces. Logs and frontend
errors split by where the service is hosted:

| Signal | Where to query | Applies to |
|---|---|---|
| **APM traces** | Datadog (`dd_spans_search`) | **Every service** — always |
| **Backend logs** | Datadog (`dd_logs_search`) | Non-atlas services (core-api, core-consumer, risklab, grs, etc.) |
| **Backend logs** | gcloud logging (`gcloud_logs`) | atlas services (`arqu-atlas-*`) |
| **Frontend errors** | Datadog RUM (`dd_rum_search`) | Browser apps (arqu-web, doubtfire-client, etc.) |

Heuristic for routing the LOGS query (traces are unconditional):
1. Service name matches `arqu-atlas-*` → gcloud logging
2. Service is a frontend / browser app → Datadog RUM
3. Everything else → Datadog logs

If uncertain, try Datadog first and fall back to gcloud. **If still unclear
how a service is hosted or configured, inspect the infra project**
(`~/src/infra` or whichever local checkout exists) — Terraform, Helm charts,
deployment manifests, and Datadog monitor definitions there are the source
of truth for where logs/metrics live and which `service:` tag is used.
Grep the infra repo for the service name and read the surrounding config
before falling back to AskUserQuestion. The lib.sh helpers validate service
names against `[a-zA-Z0-9_.-]+` (format, not catalog) and reject anything
with spaces, quotes, or query operators.

Helper functions for all of these live at `lib.sh` in this directory. Source it at the
start of any Bash block that calls a backend:

```bash
_LIB=$(find "$HOME/.claude" -path "*/investigate/lib.sh" 2>/dev/null | sort -V | tail -1)
[ -z "$_LIB" ] && { echo "FATAL: investigate/lib.sh not found"; exit 1; }
source "$_LIB"
```

---

## Phase 1: Root Cause Investigation

### Step 0: Parse symptom and detect service

Read `$ARGUMENTS`. Extract:
- **Service name** (any string the user provides — do not validate against an allow-list)
- **Slack thread URL** if present (`https://<workspace>.slack.com/archives/...`)
- **Error fragment** (the actual message/symptom text)
- **Time window** (default: last 1h)

Apply the routing heuristic above to pick the backend. If the service name is
missing entirely, use AskUserQuestion to get one. Don't enumerate options —
ask the user to type the service name.

If a Slack URL is present, fetch the thread first (Section: Slack pull) and
incorporate the messages into the symptom set before continuing.

### Step 1a: Pull signals from the right backends

**Always query Datadog APM traces** — they exist for every service:
```bash
dd_spans_search "<service>" 1   # last 1h, error spans + trace deep links
```
Trace IDs link to `https://app.datadoghq.com/apm/trace/<trace_id>`.

**Then query logs from the host-appropriate backend:**

- atlas services (`arqu-atlas-*`) → gcloud logging
  ```bash
  gcloud config get-value project    # confirm correct project first
  gcloud_logs "<container>" 1        # severity>=ERROR
  ```
  If the active project looks wrong, AskUserQuestion to confirm before querying.

- everything else → Datadog logs
  ```bash
  dd_logs_search "<service>" 1
  ```

**If the service is a frontend / browser app** (e.g. `arqu-web`,
`doubtfire-client`, or any FE project — RUM is enabled across all FE), also query RUM:
```bash
dd_rum_search "<service>" 1
```
Group by `@error.message` and `@view.url`. Errors clustered on a single
browser version → likely client-side, not a backend regression.

Look for: a single dominant error (likely root cause), a cluster correlated
with a recent deploy (regression), or a new error appearing for the first
time today (recent change).

### Step 1b: Read source code

Locate the affected repo for the service. Look in `~/src/` for a directory
matching the service name or its parent project. If you can't find it, ask
the user. Use Grep to locate the error message verbatim. Read the surrounding
code (functions calling this code path).

### Step 1c: Recent changes

`git -C <repo> log --oneline -20 -- <affected files>`. Was this working
before? **Regression means the root cause is in the diff.**

### Output

A single specific testable hypothesis with file:line if known.

---

## Scope Lock

Identify the narrowest directory containing the affected files. Tell the user:

> Edits restricted to `<dir>/` for this debug session. This prevents unrelated
> changes during root-cause work.

Self-enforce: do not edit files outside that directory until Phase 4 begins.
If the bug genuinely spans the whole repo, skip the lock and note why.

---

## Phase 2: Pattern Analysis

Match the symptom against known patterns:

| Pattern | Signature | Where to look |
|---------|-----------|---------------|
| Race condition | Intermittent, timing-dependent | Concurrent access to shared state |
| Nil/null propagation | NoneType / TypeError | Missing guards on optional values |
| State corruption | Inconsistent data, partial updates | Transactions, callbacks, hooks |
| Integration failure | Timeout, unexpected response | External API calls, service boundaries |
| Configuration drift | Works locally, fails in staging/prod | Env vars, feature flags, DB state |
| Stale cache | Shows old data, fixes on cache clear | Redis, CDN, browser cache |
| Celery task retry storm | Same task ID alerting repeatedly in any celery worker | Task signature, idempotency, exception handling |

Also check:
- `TODOS.md` if it exists in the affected repo
- `git log --grep="<error keyword>"` for prior fixes touching the same files
- **Recurring bugs in the same files are an architectural smell**, not a coincidence

---

## Phase 3: Hypothesis Testing

Before writing ANY fix:

1. **Verify the hypothesis.** Add a temporary log statement, assertion, or run a
   targeted Datadog/gcloud query that would confirm or refute it. Examples:
   - Add `print(f"DEBUG cart={cart}")` at the suspected line and trigger the repro.
   - Query Datadog: `dd_logs_search "core-api" 1 | grep "promo_code"` to confirm the
     error correlates with carts missing that field.

2. **If wrong**, return to Phase 1, gather more evidence, do not guess.

3. **3-strike rule**: track hypotheses tested in this session. After 3 failed
   hypotheses, **STOP** and AskUserQuestion:
   ```
   3 hypotheses tested, none match. This may be architectural rather than a simple bug.

   A) Continue investigating — I have a new hypothesis: [describe]
   B) Escalate for human review — this needs someone who knows the system
   C) Add logging and wait — instrument the area and catch it next time
   ```

**Red flags:** "quick fix for now" (there is none); proposing a fix before
tracing data flow (you're guessing); each fix revealing a new problem (wrong layer).

---

## Phase 4: Implementation

Only after the hypothesis is verified:

1. **Smallest change** that eliminates the root cause. Resist refactoring adjacent code.

2. **Regression test** that:
   - Fails without the fix (proves the test is meaningful)
   - Passes with the fix (proves the fix works)

   Test runner per repo:
   - core-api, core-consumer, arqu-atlas → `pytest`
   - arqu-web → `vitest`

3. **Run the full test suite** for the affected repo. Paste output. No regressions allowed.

4. **If the fix touches >5 files**, AskUserQuestion:
   ```
   This fix touches N files. That's a large blast radius for a bug fix.
   A) Proceed — the root cause genuinely spans these files
   B) Split — fix the critical path now, defer the rest
   C) Rethink — maybe there's a more targeted approach
   ```

5. **Revert any temporary diagnostic edits** from Phase 3 before committing.

---

## Phase 5: Verification & Report

**Fresh verification:** Reproduce the original bug scenario (or re-query the
backend after the fix lands and confirm error rate dropped). This is not optional.

Emit the structured DEBUG REPORT:

```
DEBUG REPORT
════════════════════════════════════════
Symptom:           [what the user observed]
Service:           [core-api / arqu-atlas-celery-worker / etc]
Backend used:      [Datadog logs+APM / gcloud logging / RUM / code-only]
Root cause:        [what was actually wrong]
Fix:               [file:line references]
Evidence:          [test output + Datadog/gcloud query results]
Regression test:   [file:line of new test]
Datadog link:      [https://app.datadoghq.com/... if applicable]
Related:           [TODOS items, prior bugs in same area]
Status:            DONE | DONE_WITH_CONCERNS | BLOCKED
════════════════════════════════════════
```

If `--slack-channel <C>` was passed (or `INVESTIGATE_SLACK_CHANNEL` is set), post
the report to Slack now (Section: Slack push).

---

## Slack integration (optional, fail-soft)

**Prefer the Slack MCP server when available.** If MCP Slack tools are present
in the session (tool names like `mcp__slack__*`), use them directly — they
handle auth and rate limiting for you. The lib.sh `slack_*` helpers are a
fallback for when MCP is not available, using `SLACK_BOT_TOKEN` from env.

Detection order at the top of any Slack step:
1. MCP Slack tools available → use them
2. `SLACK_BOT_TOKEN` set → use lib.sh helpers (`slack_post`, `slack_thread_fetch`)
3. Neither → print a one-line warning and skip Slack. If the user passed a
   Slack thread URL explicitly, error on that — they clearly wanted Slack.

### Slack pull (Phase 1 input)

If `$ARGUMENTS` contains a Slack thread URL, fetch the thread and use the
messages as additional symptom context in Phase 1. With MCP: call the
appropriate `mcp__slack__*` tool for thread replies. Without MCP:
```bash
slack_thread_fetch "<url>"
```

### Slack push (Phase 5 output)

After the DEBUG REPORT is emitted, if `--slack-channel <C>` was passed (or
`INVESTIGATE_SLACK_CHANNEL` is set), post the report to that channel. With
MCP: call the appropriate `mcp__slack__*` post-message tool. Without MCP:
```bash
slack_post "<channel>" "$(cat <<'EOF'
DEBUG REPORT
...full report...
EOF
)"
```

Use a code block (triple backticks) inside the message. On any Slack error
(channel not found, rate limit, auth), warn and continue — never block.

---

## Important Rules

- **Never apply a fix you cannot verify.** Reproduce and confirm, or don't ship it.
- **Never say "this should fix it."** Verify. Run the tests.
- **3-strike rule is binding.** 3 failed hypotheses → STOP and escalate.
- **Scope lock is binding.** Don't edit outside the locked directory until Phase 4.
- **Slack is optional.** Backend failures should fail soft where possible.
- **Completion status:** `DONE` / `DONE_WITH_CONCERNS` / `BLOCKED`.
