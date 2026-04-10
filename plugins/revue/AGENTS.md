# revue — Code Review Agent Team

Four specialized reviewers analyze pull request diffs: architecture, security, correctness, and style.

## Installation

Point Codex at the repo-root `codex/` directory of `jerrod/agent-plugins`. That directory is a self-contained Codex marketplace (`.agents/plugins/marketplace.json` + `plugins/revue/`); the plugin will appear in the plugin browser from there.

## Available Skills

- `$review-pr` — Run a full code review on the current PR. Dispatches four reviewers sequentially, merges findings into review.json.
- `$respond` — Reply to a PR comment directed at revue.

## Platform Differences

On Codex, reviewers run sequentially (one at a time) rather than in parallel. The output is identical — four specialized perspectives covering architecture, security, correctness, and style. Review time is longer but analytical quality is the same.
