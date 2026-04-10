# revue

Enterprise-grade code review by a team of specialized AI agents. `revue` orchestrates four reviewers — **architect**, **security**, **correctness**, and **style** — in parallel against a pull request diff, then aggregates their findings into a single verdict.

## Requirements

> **⚠ You MUST enable agent teams.** revue depends on Claude Code's experimental agent-team feature to spawn its four reviewers concurrently. Without it, the `review-pr` skill cannot dispatch subagents and will fail.
>
> ```bash
> export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
> ```
>
> Add the export to your shell profile (`~/.zshrc`, `~/.bashrc`) so every Claude Code session has it set. Confirm it's active with `echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` inside a session.

## What it does

- **Four specialized reviewers**, each with their own prompt, focus area, and output schema:
  - `architect` — API design, dependencies, breaking changes, scalability
  - `security` — OWASP Top 10, secrets, injection, auth, crypto misuse
  - `correctness` — logic bugs, edge cases, error handling, race conditions, type safety
  - `style` — naming, readability, test quality, dead code, consistency
- **Parallel dispatch.** All four agents launch in a single tool-use block and run concurrently.
- **Streaming persistence.** Each reviewer's findings are written to `$REVUE_LOG_DIR/agent-<role>.json` as soon as the agent returns, so nothing is lost if a session hits budget or turn limits.
- **Aggregated verdict.** Findings are deduplicated, sorted by severity, and written to `review.json` with an overall `approve | request_changes | comment` verdict.
- **Re-review mode.** When a previous review exists, reviewers focus on the incremental diff and mark resolved findings.

## Skills

- `review-pr` — run a full four-agent review against a PR diff. Outputs `review.json`.
- `respond` — reply to a PR comment directed at revue. Outputs `response.json`.

Both skills are user-invocable (`Skill` tool or natural-language trigger).

## Agents

| Agent | Role | Tools |
|---|---|---|
| `architect` | structural/design review | Read, Glob, Grep |
| `security` | vulnerability review | Read, Glob, Grep |
| `correctness` | logic/edge-case review | Read, Glob, Grep |
| `style` | quality/readability review | Read, Glob, Grep |

Each agent outputs a JSON array of findings. See `agents/<role>/<role>.md` for the exact schema per role.

## Finding schema

```json
{
  "file": "relative/path/to/file.ext",
  "line": 42,
  "severity": "critical|high|medium|low|info",
  "category": "architecture|security|correctness|style",
  "title": "Short descriptive title",
  "body": "**Evidence:** ...\n**Impact:** ...\n**Fix:** ...\n**Confidence:** ...",
  "confidence": "high|medium|low"
}
```

## Verdict logic

- **approve** — no critical or high findings
- **request_changes** — any critical or high finding exists
- **comment** — only medium/low/info findings

## Example wiring

See `examples/.revue.json` for per-repo instructions and `examples/revue-workflow.yml` for a GitHub Actions workflow.

## Source

Ported from `arqu-co/claude-skills` (`plugins/revue`) into the `jerrod/agent-plugins` marketplace. Runtime behavior is unchanged — only the marketplace wrapper is new.
