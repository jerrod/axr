# Remediation Strategies

Per-criterion strategies for `/axr-fix`. Each section describes what to create or modify
to improve a specific criterion's score. Strategies are guides for the LLM agent — adapt
to the target repo's actual structure, stack, and conventions.

The `/axr-fix` command looks up strategies by section heading `## <criterion_id>`.

---

## docs_context.1 — Root CLAUDE.md or AGENTS.md

**Target score:** 2-3 (Functional to Strong)

**Strategy:**
1. Read the repo structure (`ls -la`, key directories, package.json/pyproject.toml/Cargo.toml).
2. Read existing README.md for project description.
3. Read any existing CLAUDE.md (may be empty or minimal).
4. Generate or update `CLAUDE.md` with:
   - Project description (1-2 sentences)
   - Architecture overview (key directories and what they contain)
   - Tech stack (language, framework, key dependencies)
   - Development workflow (how to run, test, deploy)
   - Conventions (naming, file organization, testing approach)
   - Sharp edges (things that break easily, non-obvious behaviors)
5. Keep it under 200 lines. Agents need density, not length.

**Evidence that improves score:** File exists at root, contains architecture section, mentions conventions or sharp edges.

---

## docs_context.2 — README covers setup in ≤5 commands

**Target score:** 2-3

**Strategy:**
1. Read existing README.md.
2. Detect setup method: look for `package.json` (npm/yarn/pnpm), `pyproject.toml` (uv/pip),
   `Cargo.toml` (cargo), `go.mod` (go), `Gemfile` (bundle), `Makefile`, `bin/setup`.
3. If README lacks a quickstart section, add one:
   ```
   ## Quickstart
   git clone <repo-url>
   cd <repo-name>
   <install-command>    # e.g., npm install, uv sync
   <test-command>       # e.g., npm test, uv run pytest
   <run-command>        # e.g., npm start, uv run python -m app
   ```
4. If README has setup instructions but they require >5 commands, consolidate into
   a `bin/setup` script and reference it from the quickstart.

**Evidence that improves score:** README contains a quickstart or setup section with ≤5 commands covering clone, install, test, and run.

---

## docs_context.4 — ADRs or decision log

**Target score:** 0-2

**Strategy:**
1. Create `docs/adr/` directory.
2. Create `docs/adr/README.md` with an ADR template reference and index of decisions.
3. Create `docs/adr/0001-record-architecture-decisions.md` using the classic first ADR
   (adopting ADRs as a practice). Use standard ADR format: Title, Status, Context,
   Decision, Consequences.
4. If the repo has obvious architectural decisions visible in the code (e.g., choice
   of framework, database, monorepo vs polyrepo), create 1-2 additional ADRs
   documenting those decisions.

**Evidence that improves score:** `docs/adr/` directory exists with at least one ADR file following standard template format.

---

## safety_rails.3 — Secrets not in repo

**Target score:** 0-3

**Strategy:**
1. Read existing `.gitignore`.
2. Scan for common secret file patterns NOT already in `.gitignore`:
   - `.env`, `.env.*` (except `.env.example`, `.env.test`)
   - `*.pem`, `*.key`, `*.p12`
   - `credentials.json`, `service-account*.json`
   - `*.secret`, `*.secrets`
   - `.aws/credentials`, `.gcp/`, `.azure/`
3. Add missing patterns to `.gitignore`.
4. If `.env.example` does not exist but `.env` patterns are present, create
   `.env.example` with placeholder values showing required variables.
5. Check for pre-commit hook with secret scanning (e.g., `detect-secrets`,
   `gitleaks`). If absent, note in output but do not install (that changes CI).

**Evidence that improves score:** `.gitignore` covers secret file patterns; `.env.example` exists if `.env` patterns are present.

---

## safety_rails.5 — Agent boundaries documented

**Target score:** 0-2

**Strategy:**
1. Read CLAUDE.md (create if missing — apply docs_context.1 strategy first).
2. Add an "Agent Permissions" or "Agent Boundaries" section documenting:
   - What agents SHOULD do (write code, run tests, create PRs, run linters)
   - What agents MUST NOT do (deploy to production, modify infrastructure,
     delete data, push to main, run destructive commands)
   - Review checkpoints (when human review is required before proceeding)
3. If the repo has `.claude/settings.json` or similar agent config, reference
   its permission model in the boundaries section.

**Evidence that improves score:** CLAUDE.md contains a section with agent permissions, boundaries, or operational constraints.

---

## style_validation.5 — Editor/IDE config shared

**Target score:** 0-3

**Strategy:**
1. Check for existing `.editorconfig`. If present, verify coverage. If missing:
2. Detect indentation style from source files (read 3-5 representative files,
   check tabs vs spaces, measure indent width).
3. Generate `.editorconfig`:
   ```ini
   root = true

   [*]
   indent_style = <space|tab>
   indent_size = <2|4>
   end_of_line = lf
   charset = utf-8
   trim_trailing_whitespace = true
   insert_final_newline = true

   [*.md]
   trim_trailing_whitespace = false

   [Makefile]
   indent_style = tab
   ```
4. If `.vscode/settings.json` exists, ensure it does not conflict. If `.vscode/`
   does not exist but the project uses VS Code conventions, optionally create
   `.vscode/extensions.json` with recommended linter/formatter extensions.

**Evidence that improves score:** `.editorconfig` exists with project-appropriate settings (indent style, charset, trailing whitespace rules).

---

## tooling.2 — One-command local bootstrap

**Target score:** 0-3

**Strategy:**
1. Check for existing bootstrap script (`bin/setup`, `bin/bootstrap`,
   `scripts/setup`, Makefile `setup` target).
2. If missing, detect the stack and create `bin/setup`:
   - Node: `npm install` / `yarn` / `pnpm install`
   - Python: `uv sync` or `pip install -r requirements.txt`
   - Ruby: `bundle install`
   - Go: `go mod download`
   - Rust: `cargo build`
3. Make it executable: `chmod +x bin/setup`.
4. Add database setup if detected (e.g., `bin/rails db:setup`,
   `alembic upgrade head`).
5. Add to README quickstart if not already referenced.

**Evidence that improves score:** `bin/setup` or equivalent exists, is executable, and handles dependency installation.

---

## tooling.4 — Dev container or codespace support

**Target score:** 0-2

**Strategy:**
1. Detect the primary stack from manifest files (`package.json`,
   `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`).
2. Create `.devcontainer/devcontainer.json`:
   ```json
   {
     "name": "<repo-name>",
     "image": "mcr.microsoft.com/devcontainers/<language>:<version>",
     "features": {},
     "postCreateCommand": "<install-command>",
     "customizations": {
       "vscode": {
         "extensions": ["<relevant-extensions>"]
       }
     }
   }
   ```
3. Select the appropriate base image:
   - Node: `mcr.microsoft.com/devcontainers/javascript-node:20`
   - Python: `mcr.microsoft.com/devcontainers/python:3.12`
   - Go: `mcr.microsoft.com/devcontainers/go:1.22`
   - Rust: `mcr.microsoft.com/devcontainers/rust:1`
   - Ruby: `mcr.microsoft.com/devcontainers/ruby:3.3`
4. If the project has services (database, Redis), add a `docker-compose.yml`
   and reference it via `dockerComposeFile`.

**Evidence that improves score:** `.devcontainer/devcontainer.json` exists with appropriate base image and post-create command.
