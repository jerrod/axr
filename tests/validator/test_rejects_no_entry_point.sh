#!/usr/bin/env bash
# Validator must reject a plugin with NO commands/, skills/, or agents/.
# This proves the entry-point requirement is not a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixtures/validator-cases/no-entry-point"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.claude-plugin" "$WORK/plugins"
cp -R "$REPO_ROOT/bin" "$WORK/bin"

cat > "$WORK/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "test-marketplace",
  "version": "1.0",
  "owner": { "name": "test" },
  "plugins": [
    {
      "name": "no-entry-point-fixture",
      "description": "fixture",
      "source": "./plugins/no-entry-point-fixture",
      "category": "test"
    }
  ]
}
EOF

cp -R "$FIXTURE" "$WORK/plugins/no-entry-point-fixture"

(
    cd "$WORK"
    GIT_CONFIG_GLOBAL=/dev/null git init -q
    GIT_CONFIG_GLOBAL=/dev/null git \
        -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        add -A
    GIT_CONFIG_GLOBAL=/dev/null git \
        -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
        commit -q -m init
)

rc=0
( cd "$WORK" && bin/validate ) > "$WORK/out.log" 2>&1 || rc=$?

# Expect non-zero exit AND the specific error message.
if [ "$rc" -eq 0 ]; then
    echo "FAIL: validator accepted a plugin with no entry point (should have failed)"
    cat "$WORK/out.log"
    exit 1
fi

if ! grep -q "no entry point" "$WORK/out.log"; then
    echo "FAIL: validator rejected the plugin but not for the expected reason"
    cat "$WORK/out.log"
    exit 1
fi

echo "PASS: validator rejected no-entry-point plugin with the expected message"
