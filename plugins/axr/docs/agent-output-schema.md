# Agent Output Schema (axr judgment subagents)

**Schema version:** 1.0

Canonical output contract for all 5 `axr` judgment subagents. Every agent emits
a **JSON array of criterion objects** to stdout. The orchestrator writes each
array to `.axr/tmp/agent-<name>.json`, then `aggregate.sh --merge-agents`
overlays these onto per-dimension JSONs.

## Output shape

A single JSON array. Each element is a criterion object with the fields below.
**No wrapper envelope** — the orchestrator routes criteria to their dimensions
by parsing the `id` prefix.

## Criterion fields (all required)

| Field | Type | Rules |
|---|---|---|
| `id` | string | Must match a rubric criterion id exactly (e.g., `docs.subsystem-readmes`). |
| `name` | string | Copy verbatim from the rubric criterion name. |
| `score` | integer | 0, 1, 2, or 3. **Never 4** — score 4 requires human confirmation per `anchors_literal: true`. |
| `evidence` | array of strings | Concrete file paths, line numbers, greppable patterns. **Non-empty for score ≥ 2.** For score 0/1, may be empty. Max 20 elements, each ≤500 chars. Enforced by `merge-agents.sh`. |
| `notes` | string | Short qualitative justification (1–2 sentences). ≤500 chars. Enforced by `merge-agents.sh`. |
| `reviewer` | string | Always the literal string `"agent-draft"`. |

## Scoring discipline

- **0–3 only.** Never emit 4. Score 4 is reserved for human confirmation.
- **Unknown defaults to 1**, with `evidence: []` and a note explaining the
  uncertainty. Do not inflate scores.
- **Evidence required for ≥ 2.** If you cannot cite specific files/patterns,
  score 1.

## Example output (2 criteria)

```json
[
  {
    "id": "docs.subsystem-readmes",
    "name": "Local READMEs for non-obvious subsystems",
    "score": 2,
    "evidence": [
      "src/auth/README.md explains OIDC flow and token refresh boundaries",
      "src/billing/README.md covers Stripe webhook contract",
      "src/ingest/ has no README despite 12 source files"
    ],
    "notes": "Roughly 40% of non-obvious subsystems documented; found READMEs are clear but ingest/ and workers/ are undocumented.",
    "reviewer": "agent-draft"
  },
  {
    "id": "docs.glossary",
    "name": "Domain glossary",
    "score": 1,
    "evidence": [],
    "notes": "No GLOSSARY.md or docs/glossary file. Domain terms scattered informally across README.md.",
    "reviewer": "agent-draft"
  }
]
```
