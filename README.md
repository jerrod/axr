# agent-plugins

Claude Code plugin marketplace by [jerrod](https://github.com/jerrod). Tools for agent-operated software engineering — readiness scoring, code review, and behavioral correction.

## Plugins

### axr — Agent eXecution Readiness scoring

Grades a repository against a 100-point rubric across 12 dimensions using deterministic bash checkers and judgment subagents. Produces a machine-readable JSON report and a human-readable markdown report per run.

See `plugins/axr/README.md` for details.

### revue — Enterprise code review by a four-agent team

Runs four specialized reviewers — **architect**, **security**, **correctness**, **style** — against a pull request diff in parallel, then aggregates findings into a single verdict with deduplication and severity sorting.

> **⚠ Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.** revue depends on Claude Code's experimental agent-team feature to spawn its four reviewers concurrently. Without this env var set, the `review-pr` skill cannot dispatch subagents. Add the export to your shell profile so every session has it:
>
> ```bash
> export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
> ```

See `plugins/revue/README.md` for details.

### therapist — Diagnose and fix persistent rationalization patterns

A CBT-adapted intervention framework for sessions where Claude repeatedly violates explicit rules. Bundles a `/therapist` slash command, ambient hooks that catch rationalization phrases live at `Write`/`Edit`/`Bash` tool use, and a reference toolbox of eleven techniques.

See `plugins/therapist/README.md` for details.

### sdlc — Full development lifecycle with executable quality gates

Enforces the brainstorm → plan → pair-build → review → ship workflow with 24 skills, 23 subagents, 8 lifecycle hooks, and executable gates at every checkpoint. File size, coverage, complexity, lint, and test-quality are all script-verified. PR descriptions embed proof artifacts any reviewer can independently re-run. Hard fork of [`arqu-co/rq`](https://github.com/arqu-co/claude-skills/tree/main/plugins/rq) at v1.29.8.

See `plugins/sdlc/README.md` for details.

## Quickstart

```bash
# Install the marketplace in Claude Code
# /plugin → Add Marketplace → jerrod/agent-plugins

# Validate the marketplace + every plugin
bin/validate

# Run linting (shellcheck + JSON + frontmatter)
bin/lint

# Run tests (validates all checkers produce schema-valid JSON)
bin/test
```

## Installation

### In Claude Code

1. `/plugin` → Add Marketplace → `jerrod/agent-plugins`
2. Choose the plugin(s) you want to install
3. **For revue:** also set `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your shell profile

### In Codex

Codex consumes these plugins via the **personal marketplace** pattern from [the official Codex plugin docs](https://developers.openai.com/codex/plugins/build): a marketplace manifest at `~/.agents/plugins/marketplace.json` with plugin files under `~/.codex/plugins/<name>/`. The `bin/install` script does the full install in one command — no clone required.

#### 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/jerrod/agent-plugins/main/bin/install | bash
```

This downloads only the four plugin directories from the latest `main` tarball (~2 MB), copies them into `~/.codex/plugins/`, and writes `~/.agents/plugins/marketplace.json` with the correct `./.codex/plugins/<name>` source paths. It refuses to clobber an existing personal marketplace with a different name — pass `--force` if you want to replace one.

Options (either pass via flags when running from a clone, or set the matching `AGENT_PLUGINS_*` env var when piping via curl):

| Flag | Env var | Default |
|---|---|---|
| `--ref REF` | `AGENT_PLUGINS_REF` | `main` (use a tag for a pinned install) |
| `--plugin-dir DIR` | `AGENT_PLUGINS_PLUGIN_DIR` | `$HOME/.codex/plugins` |
| `--marketplace FILE` | `AGENT_PLUGINS_MARKETPLACE` | `$HOME/.agents/plugins/marketplace.json` |
| `--force` | `AGENT_PLUGINS_FORCE=1` | refuse to overwrite a differently-named personal marketplace |
| `--uninstall` | — | reverse of install |

After the installer finishes, **restart Codex** so it re-reads `~/.agents/plugins/marketplace.json`.

##### Manual install (no curl | bash)

If you'd rather not pipe curl into bash, the installer just automates these four lines:

```bash
mkdir -p ~/.codex/plugins ~/.agents/plugins
curl -sL https://github.com/jerrod/agent-plugins/archive/main.tar.gz \
  | tar -xz --strip-components=3 -C ~/.codex/plugins \
    agent-plugins-main/codex/plugins/axr \
    agent-plugins-main/codex/plugins/revue \
    agent-plugins-main/codex/plugins/sdlc \
    agent-plugins-main/codex/plugins/therapist

cat > ~/.agents/plugins/marketplace.json <<'JSON'
{
  "name": "agent-plugins",
  "interface": { "displayName": "agent-plugins" },
  "plugins": [
    { "name": "axr",       "source": { "source": "local", "path": "./.codex/plugins/axr" },       "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" }, "category": "Coding" },
    { "name": "revue",     "source": { "source": "local", "path": "./.codex/plugins/revue" },     "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" }, "category": "Coding" },
    { "name": "sdlc",      "source": { "source": "local", "path": "./.codex/plugins/sdlc" },      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" }, "category": "Coding" },
    { "name": "therapist", "source": { "source": "local", "path": "./.codex/plugins/therapist" }, "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" }, "category": "Coding" }
  ]
}
JSON
```

Both paths land in the exact same state — the installer just adds safer merging, the foreign-marketplace guard, and uninstall support.

#### 2. Enable

Codex discovers the marketplace automatically after restart. To turn individual plugins on, either use the Codex plugin UI or append any of these blocks to `~/.codex/config.toml`:

```toml
[plugins."axr@agent-plugins"]
enabled = true

[plugins."revue@agent-plugins"]
enabled = true

[plugins."sdlc@agent-plugins"]
enabled = true

[plugins."therapist@agent-plugins"]
enabled = true
```

The plugin ID is always `<plugin-name>@agent-plugins`. Skip any you don't want.

#### 3. Use

Each enabled plugin's skills are namespaced under `<name>:<skill>`:

| Plugin | Skills |
|---|---|
| `axr` | `axr:axr`, `axr:axr-check`, `axr:axr-diff`, `axr:axr-fix`, `axr:axr-badge` |
| `revue` | `revue:review-pr`, `revue:respond` |
| `sdlc` | 23 skills including `sdlc:dev`, `sdlc:brainstorm`, `sdlc:writing-plans`, `sdlc:pair-build`, `sdlc:review`, `sdlc:ship` |
| `therapist` | `therapist:therapist` |

Invoke them the same way you invoke any other Codex skill. See each plugin's `plugins/<name>/README.md` and `AGENTS.md` for the full skill catalog. A few behaviors differ from Claude Code (multi-agent workflows run sequentially, some hooks fire at different times) — check each plugin's "Codex Limitations" / "Platform Differences" section.

#### 4. Update

Re-run the installer. It downloads the latest tarball, replaces the plugin directories in place, and refreshes the marketplace entries:

```bash
curl -fsSL https://raw.githubusercontent.com/jerrod/agent-plugins/main/bin/install | bash
```

Then restart Codex.

#### 5. Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/jerrod/agent-plugins/main/bin/install | bash -s -- --uninstall
```

This removes the four plugin directories from `~/.codex/plugins/` and deletes the agent-plugins entries from the personal marketplace (keeping any unrelated entries intact). You also want to delete any `[plugins."*@agent-plugins"]` blocks you added to `~/.codex/config.toml` by hand.

## For contributors

The marketplace is structured as:

- `plugins/<name>/` — each plugin self-contained (manifest, commands/skills/agents, scripts, docs, README, CLAUDE.md)
- `bin/` — marketplace-level gate scripts that validate every plugin
- `.claude-plugin/marketplace.json` — marketplace manifest

Plugins may use any of `commands/`, `skills/`, or `agents/` as their entry point. `scripts/` is optional (agent-team plugins like revue have none).

See `CLAUDE.md` for workflow conventions. All changes go through the sdlc workflow: brainstorm → plan → pair-build → review → ship.
