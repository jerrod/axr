#!/usr/bin/env bash
# tests/validator/_lib_setup.sh — shared workspace setup for bin/validate fixture tests.
#
# Sourced (not executed) by test_*.sh scripts. Provides:
#   setup_validator_workspace <fixture_name>
#     Creates a disposable git-initialized marketplace root containing a copy
#     of the live bin/ directory and a single plugin populated from
#     tests/fixtures/validator-cases/<fixture_name>/. Returns the workspace
#     path on stdout. Caller is responsible for cleanup (the test scripts
#     install their own EXIT trap on $WORK).
#
# Hard requirement: each fixture's plugin.json must declare its name field
# matching the directory name — that name is used in the synthesized
# marketplace.json plugin entry.

# shellcheck disable=SC2034  # variables are consumed by sourcing scripts

setup_validator_workspace() {
    local fixture_name="$1"
    local script_dir repo_root fixture work
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    repo_root="$(cd "$script_dir/../.." && pwd)"
    fixture="$repo_root/tests/fixtures/validator-cases/$fixture_name"

    [ -d "$fixture" ] || {
        printf 'setup_validator_workspace: fixture missing: %s\n' "$fixture" >&2
        return 1
    }

    work="$(mktemp -d)" || return 1
    mkdir -p "$work/.claude-plugin" "$work/plugins" || return 1

    # Copy the ENTIRE bin/ directory so future helper extraction still works.
    cp -R "$repo_root/bin" "$work/bin" || return 1

    # Synthesize a minimal marketplace.json referencing the fixture.
    cat > "$work/.claude-plugin/marketplace.json" <<MARKETPLACE_EOF
{
  "name": "test-marketplace",
  "version": "1.0",
  "owner": { "name": "test" },
  "plugins": [
    {
      "name": "${fixture_name}-fixture",
      "description": "fixture",
      "source": "./plugins/${fixture_name}-fixture",
      "category": "test"
    }
  ]
}
MARKETPLACE_EOF

    cp -R "$fixture" "$work/plugins/${fixture_name}-fixture" || return 1

    # Isolated git repo — no global config, no signing, no hooks. The
    # subshell scopes the env override so it does not bleed into the caller.
    (
        cd "$work" || exit 1
        export GIT_CONFIG_GLOBAL=/dev/null
        git init -q
        git -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
        git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
    ) || return 1

    printf '%s\n' "$work"
}

# run_validator_in <workspace> <out_log_path>
# Runs bin/validate inside the workspace, capturing stdout+stderr to the
# given log path. Echoes the validator's exit code on stdout.
run_validator_in() {
    local work="$1" out_log="$2"
    local rc=0
    ( cd "$work" && bin/validate ) > "$out_log" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
