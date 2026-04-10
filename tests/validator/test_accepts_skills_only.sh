#!/usr/bin/env bash
# Validator must accept a plugin that has skills/ but no commands/ or scripts/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixtures/validator-cases/skills-only"

# Disposable workspace that looks like a marketplace root.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.claude-plugin" "$WORK/plugins"

# Copy the ENTIRE bin/ directory so future _lib extraction still works.
cp -R "$REPO_ROOT/bin" "$WORK/bin"

cat > "$WORK/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "test-marketplace",
  "version": "1.0",
  "owner": { "name": "test" },
  "plugins": [
    {
      "name": "skills-only-fixture",
      "description": "fixture",
      "source": "./plugins/skills-only-fixture",
      "category": "test"
    }
  ]
}
EOF

cp -R "$FIXTURE" "$WORK/plugins/skills-only-fixture"

# Isolated git repo — no global config, no signing, no hooks.
(
    cd "$WORK"
    GIT_CONFIG_GLOBAL=/dev/null git init -q
    GIT_CONFIG_GLOBAL=/dev/null git \
        -c user.email=t@t -c user.name=t \
        -c commit.gpgsign=false \
        add -A
    GIT_CONFIG_GLOBAL=/dev/null git \
        -c user.email=t@t -c user.name=t \
        -c commit.gpgsign=false \
        commit -q -m init
)

# Run the validator with explicit rc capture (set -e would kill the test on
# any non-zero exit — we want to inspect the exit code, not abort).
rc=0
( cd "$WORK" && bin/validate ) > "$WORK/out.log" 2>&1 || rc=$?

if [ "$rc" -ne 0 ]; then
    echo "FAIL: validator rejected skills-only plugin (exit $rc)"
    cat "$WORK/out.log"
    exit 1
fi

echo "PASS: validator accepted skills-only plugin"
