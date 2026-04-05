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
             rust-toolchain rust-toolchain.toml; do
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
