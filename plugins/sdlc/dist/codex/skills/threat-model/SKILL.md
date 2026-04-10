---
name: threat-model
description: "Repository-grounded threat modeling — enumerates trust boundaries, assets, attacker capabilities, abuse paths, and mitigations. Produces a Markdown threat model anchored to actual code. Trigger: 'threat model this repo', 'security threat model', 'enumerate threats', 'map attack surfaces'."
---

# Threat Modeling

## Audit Trail

Log skill invocation:

```bash
AUDIT_SCRIPT=$(find . -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | head -1)
[ -z "$AUDIT_SCRIPT" ] && AUDIT_SCRIPT=$(find "$HOME/.claude" -name "audit-trail.sh" -path "*/sdlc/*" 2>/dev/null | sort -V | tail -1)
[[ "$AUDIT_SCRIPT" != "$HOME/.claude/"* && "$AUDIT_SCRIPT" != "./"* ]] && AUDIT_SCRIPT=""
SAFE_ARGS="${ARGUMENTS//\"/\\\"}"
```

- **Start:** `bash "$AUDIT_SCRIPT" log security sdlc:threat-model started --context="$SAFE_ARGS"`
- **End:** `bash "$AUDIT_SCRIPT" log security sdlc:threat-model completed --context="<summary>"`

Deliver an actionable AppSec-grade threat model specific to THIS repository. Anchor every architectural claim to evidence found in the repo. Prefer concrete findings over generic checklists.

## Workflow

### Step 1: Scope and Extract System Model

Use Glob, Grep, and Read to identify:

- Primary components, data stores, and external integrations
- How the system runs (server, CLI, library, worker) and its entrypoints
- Separate runtime behavior from CI/build/dev tooling and from tests/examples
- Map in-scope locations to components and exclude out-of-scope items explicitly

Do not claim components, flows, or controls without evidence. Every architectural claim needs at least one repo path anchor.

### Step 2: Derive Boundaries, Assets, and Entry Points

- Enumerate trust boundaries as concrete edges between components, noting:
  - Protocol (HTTP, gRPC, IPC, file, DB)
  - Authentication and authorization mechanisms
  - Encryption (TLS, mTLS, at-rest)
  - Input validation and schema enforcement
  - Rate limiting
- List assets that drive risk: data, credentials, models, config, compute resources, audit logs
- Identify entry points: endpoints, upload surfaces, parsers/decoders, job triggers, admin tooling, logging/error sinks

### Step 3: Calibrate Attacker Capabilities

- Describe realistic attacker capabilities based on the repo's exposure and intended usage
- Explicitly note non-capabilities to avoid inflated severity (e.g., "attacker cannot access internal network" or "attacker does not have valid credentials")
- Separate attacker-controlled inputs from operator-controlled and developer-controlled inputs

### Step 4: Enumerate Threats as Abuse Paths

- Frame threats as attacker goals mapped to assets and boundaries
- Prefer multi-step abuse paths (attacker goal -> steps -> impact) over single-line generic threats
- Classify each threat and tie it to impacted assets
- Keep the count small but high quality — 5-10 threats for most repos

### Step 5: Prioritize

- Use qualitative likelihood and impact (low/medium/high) with 1-2 sentence justifications per threat
- Set overall priority (critical/high/medium/low) using likelihood x impact, adjusted for existing controls
- State which assumptions most influence the ranking

### Step 6: Validate Assumptions with User (INTERACTIVE CHECKPOINT)

**This step requires user interaction. Do not skip it.**

- Summarize key assumptions that materially affect scope or risk ranking (3-6 bullets)
- Ask 1-3 targeted questions to resolve missing context:
  - Service owner/environment, scale/users, deployment model
  - Authentication/authorization expectations
  - Internet exposure, data sensitivity, multi-tenancy
- **PAUSE and WAIT for user response before producing the final report**
- If the user cannot answer, proceed with explicit assumptions and mark conclusions as conditional

### Step 7: Recommend Mitigations

- Distinguish existing mitigations (with evidence anchors: repo path, symbol, config key) from recommended mitigations
- Tie each mitigation to a concrete location (component, boundary, or entry point)
- Prefer specific implementation hints over generic advice:
  - Good: "enforce schema validation at the upload endpoint in `src/api/upload.py:handle_upload`"
  - Bad: "validate inputs"
- For each high/critical threat, include: existing controls, gaps, recommended mitigations, detection/monitoring ideas
- Base recommendations on validated user context; mark unvalidated recommendations as conditional

### Step 8: Quality Check and Write Report

Before finalizing, confirm:

- [ ] All discovered entrypoints are covered in the threat model
- [ ] Each trust boundary is represented in at least one threat
- [ ] Runtime vs CI/dev separation is clear
- [ ] User clarifications (or explicit non-responses) are reflected
- [ ] Assumptions and open questions are explicit
- [ ] No secrets appear in the output (redact and describe instead)

Write the final report to `docs/threat-models/<repo-or-feature>-threat-model.md`.

## Complexity Scaling

Detect repo complexity before starting the full workflow:

- **Simple repos** (few endpoints, no auth, no external integrations, single-language CLI tools): produce a compact report — skip the Mermaid diagram, use shorter tables, focus on the 2-3 most relevant threats
- **Complex repos** (multiple services, auth/authz, external APIs, data stores, CI/CD pipelines): produce the full report with Mermaid diagram, complete tables, and 5-10 threats

## Output Format

The final report is a Markdown file with these sections in order:

### Executive Summary
One paragraph on the top risk themes and highest-risk areas.

### Scope and Assumptions
In-scope paths, out-of-scope items, explicit assumptions, and open questions that would materially change risk ranking.

### System Model
- Primary components (runtime plus critical build/CI when relevant)
- Data flows and trust boundaries (arrow-style bullets with protocol, auth, validation details)
- Mermaid diagram (complex repos only):
  - Use `flowchart TD` or `flowchart LR` with only `-->` arrows
  - Simple node IDs (letters/numbers/underscores) with quoted labels: `A["Label"]`
  - No `title` lines, no `style` directives
  - Plain words only in edge labels via `-->|label|`
  - No file paths, URLs, or socket paths in node labels

### Assets and Security Objectives
Table: Asset | Why it matters | Security objective (C/I/A)

### Attacker Model
Capabilities and non-capabilities sections.

### Entry Points and Attack Surfaces
Table: Surface | How reached | Trust boundary | Evidence (repo path/symbol)

### Top Abuse Paths
5-10 numbered sequences: attacker goal -> steps -> impact.

### Threat Model Table
Columns: Threat ID (TM-001 format) | Threat source | Prerequisites | Threat action | Impact | Impacted assets | Existing controls (evidence) | Gaps | Recommended mitigations | Likelihood | Impact severity | Priority (critical/high/medium/low)

### Criticality Calibration
What counts as critical/high/medium/low for THIS repo and context, with 2-3 examples per level.

### Focus Paths for Security Review
Table: Path | Why it matters | Related Threat IDs

## Risk Prioritization Guidance

- **High:** pre-auth RCE, auth bypass, cross-tenant access, sensitive data exfiltration, key/token theft, sandbox escape
- **Medium:** targeted DoS of critical components, partial data exposure, rate-limit bypass with measurable impact, log poisoning affecting detection
- **Low:** low-sensitivity info leaks, noisy DoS with easy mitigation, issues requiring unlikely preconditions

## Evidence Rules

- Every claim must be backed by at least one repo path (file, symbol, config key, or short quoted snippet)
- Never output secrets — if you encounter tokens, keys, or passwords, redact them and describe their presence and location
- Use Grep, Glob, and Read tools to find evidence — never use bash `grep` or `rg` directly
- Include 1-2 repo-path anchors per major claim; do not dump every match

This skill produces advisory output only — no gate enforcement, no proof JSON.
