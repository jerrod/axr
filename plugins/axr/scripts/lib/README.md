# scripts/lib — helper library for axr

Five helper files with distinct audiences. If you add a new helper, pick the file whose audience matches your caller.

| File | Audience | What it exports |
|---|---|---|
| `common.sh` | `scripts/check-*.sh` dimension checker scripts | `axr_*` prefixed API: JSON output assembly (`axr_init_output`, `axr_emit_criterion`, `axr_defer_criterion`, `axr_finalize_output`), stack detection, rubric name lookup, repo-root resolution. Defines the criterion output schema. Reads `rubric/rubric.v2.json`. |
| `markdown-helpers.sh` | `scripts/check-*.sh` scripts that parse markdown | Fence-aware markdown parsers: `sanitize_evidence`, `count_h2_outside_fences`, `titles_h2_outside_fences`, `count_setup_commands`, `first_three_titles_joined`. Pure functions — take a filename, emit text or integers. |
| `workflow-helpers.sh` | `scripts/check-*.sh` scripts that inspect `.github/workflows/` | GitHub Actions workflow parsers: `extract_workflow_run_lines` (awk block-scalar parser), `workflow_files`. Used by check-style-validation, check-tests-ci, check-tooling, check-execution-visibility. |
| `tooling-helpers.sh` | `scripts/check-*.sh` scripts that inspect build tooling | Lockfile/env-pin/container detection: `list_lockfiles`, `count_lockfiles`, `list_env_pins`, `list_containerization`. Used by check-tooling. |
| `monorepo-helpers.sh` | scripts that need monorepo awareness | `axr_detect_monorepo`, `axr_list_packages`, `axr_package_scope`. Sourced by common.sh — available to all checkers. |

## Which file do I add to?

- New helper for assembling criterion JSON or looking up rubric data → **common.sh** (`axr_` prefix).
- New markdown parser or evidence sanitizer → **markdown-helpers.sh** (no prefix, pure function).
- New GitHub Actions workflow parser → **workflow-helpers.sh** (no prefix, pure function).
- New build-tooling detection → **tooling-helpers.sh** (no prefix, pure function).
- New monorepo detection or package scoping → **monorepo-helpers.sh** (`axr_` prefix).

When in doubt, pick the file whose existing contents most resemble what you're adding.

## Note on bin/ gate scripts

The marketplace-level `bin/` scripts (`bin/lint`, `bin/test`, `bin/validate`) and the plugin-local `bin/validate` each inline the small utility helpers (`strip_ansi`, `cd_repo_root`, `has_closed_frontmatter`) they need. This matches the `claude-skills` reference pattern — gate scripts are self-contained and have no source dependency on this lib directory.
