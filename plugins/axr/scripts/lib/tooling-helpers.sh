#!/usr/bin/env bash
# scripts/lib/tooling-helpers.sh — build-tooling detection helpers shared
# across dimension checkers that inspect lockfiles, env pinning, and
# tool configuration (check-tooling.sh primarily).
#
# Pure functions — take no shell-global state, output to stdout.
#
# Contract: callers MUST be at the target repo root (cwd). These helpers
# test paths with bare relative globs (e.g., "package-lock.json") and
# therefore rely on $PWD == repo root. Checker scripts satisfy this
# because /axr invokes them with cwd set to the target repo.

# Comprehensive lockfile list — kept in one place so additions (new package
# managers) propagate to every checker that counts lockfiles.
_AXR_LOCKFILES=(
    package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock
    poetry.lock uv.lock Pipfile.lock
    Gemfile.lock
    Cargo.lock
    go.sum
    composer.lock
    gradle.lockfile
    packages.lock.json
    Package.resolved
)

# ---------------------------------------------------------------------------
# list_lockfiles — print (one per line) paths of lockfiles present at $PWD.
# ---------------------------------------------------------------------------
list_lockfiles() {
    local f
    for f in "${_AXR_LOCKFILES[@]}"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# count_lockfiles — print the number of lockfiles present.
# ---------------------------------------------------------------------------
count_lockfiles() {
    list_lockfiles | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# list_env_pins — print env pinning files present at $PWD.
# ---------------------------------------------------------------------------
list_env_pins() {
    local f
    for f in .tool-versions .nvmrc .python-version .ruby-version \
             rust-toolchain rust-toolchain.toml \
             .java-version .sdkmanrc global.json; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# list_lint_configs — print linter config files present at $PWD.
# ---------------------------------------------------------------------------
list_lint_configs() {
    local f
    # Node
    for f in .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml \
             .eslintrc.yaml .eslintrc.cjs eslint.config.js \
             eslint.config.mjs eslint.config.cjs biome.json; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    # Python
    for f in .ruff.toml ruff.toml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    if [ -f pyproject.toml ] && grep -qE '^\[tool\.(ruff|pylint)\]' pyproject.toml 2>/dev/null; then
        printf '%s\n' "pyproject.toml"
    fi
    # Ruby / Go / Rust
    for f in .rubocop.yml .golangci.yml .golangci.yaml .clippy.toml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    # Java
    for f in checkstyle.xml pmd.xml spotbugs.xml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    # PHP
    for f in .php-cs-fixer.php .php-cs-fixer.dist.php phpcs.xml phpcs.xml.dist; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    # Swift
    [ -f .swiftlint.yml ] && printf '%s\n' ".swiftlint.yml"
    return 0
}

# ---------------------------------------------------------------------------
# list_format_configs — print formatter config files present at $PWD.
# ---------------------------------------------------------------------------
list_format_configs() {
    local f
    for f in .prettierrc .prettierrc.js .prettierrc.json .prettierrc.yml \
             .prettierrc.yaml .prettierrc.cjs .editorconfig .swiftformat; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    if [ -f pyproject.toml ] && grep -qE '^\[tool\.(black|isort)\]' pyproject.toml 2>/dev/null; then
        printf '%s\n' "pyproject.toml"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# list_type_check_configs — print type-checker config files present at $PWD.
# ---------------------------------------------------------------------------
list_type_check_configs() {
    local f
    # TypeScript
    [ -f tsconfig.json ] && printf '%s\n' "tsconfig.json"
    # Python
    for f in mypy.ini .mypy.ini pyrightconfig.json; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    if [ -f pyproject.toml ] && grep -qE '^\[tool\.(mypy|pyright)\]' pyproject.toml 2>/dev/null; then
        printf '%s\n' "pyproject.toml"
    fi
    # PHP
    for f in phpstan.neon phpstan.neon.dist phpstan.dist.neon \
             psalm.xml psalm.xml.dist; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# list_containerization — print container/nix files present at $PWD.
# ---------------------------------------------------------------------------
list_containerization() {
    local f
    for f in Dockerfile .devcontainer/devcontainer.json flake.nix shell.nix nix.conf; do
        [ -e "$f" ] && printf '%s\n' "$f"
    done
    return 0
}
