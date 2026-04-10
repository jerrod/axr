#!/usr/bin/env bash
# Tests for git-helpers.sh — specifically get_repo_name.
# Exercises every branch: remote URL variants, missing remote, subdir cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$SCRIPT_DIR/git-helpers.sh"

PASS=0
FAIL=0
TMPDIRS=()

cleanup() {
  for d in "${TMPDIRS[@]:-}"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# make_repo [REMOTE_URL]
# Creates a fresh git repo in mktemp -d and optionally sets origin to the
# supplied URL. Returns the tmpdir path.
make_repo() {
  local remote="${1:-}"
  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")
  (
    cd "$tmpdir"
    git init -q
    if [ -n "$remote" ]; then
      git remote add origin "$remote"
    fi
  )
  echo "$tmpdir"
}

assert_eq() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  got:      $got"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test 1: https URL with .git suffix ──────────────────────────────────────
REPO=$(make_repo "https://github.com/arqu-co/engineer.git")
GOT=$(cd "$REPO" && get_repo_name)
assert_eq "https .git suffix → engineer" "engineer" "$GOT"

# ─── Test 2: SSH URL with .git suffix ────────────────────────────────────────
REPO=$(make_repo "git@github.com:arqu-co/engineer.git")
GOT=$(cd "$REPO" && get_repo_name)
assert_eq "ssh .git suffix → engineer" "engineer" "$GOT"

# ─── Test 3: URL without .git suffix ─────────────────────────────────────────
REPO=$(make_repo "https://github.com/arqu-co/widget")
GOT=$(cd "$REPO" && get_repo_name)
assert_eq "no .git suffix → widget" "widget" "$GOT"

# ─── Test 4: Invoked from a subdirectory still resolves via remote ───────────
# Simulates the "cwd is not the repo root" case. Directory basename of cwd
# would be "sub", but get_repo_name must return the remote-derived name.
REPO=$(make_repo "git@github.com:acme/widget.git")
mkdir -p "$REPO/sub"
GOT=$(cd "$REPO/sub" && get_repo_name)
assert_eq "subdir with remote → widget (not sub)" "widget" "$GOT"

# ─── Test 5: No remote, invoked from repo root → directory basename ──────────
REPO=$(make_repo "")
GOT=$(cd "$REPO" && get_repo_name)
EXPECTED=$(basename "$REPO")
assert_eq "no remote, root → $EXPECTED" "$EXPECTED" "$GOT"

# ─── Test 6: No remote, invoked from subdir → repo root name, not subdir ─────
# This is the regression case: historically the fallback used PWD, returning
# the subdir name. The fix uses git rev-parse --show-toplevel.
REPO=$(make_repo "")
mkdir -p "$REPO/sub"
GOT=$(cd "$REPO/sub" && get_repo_name)
EXPECTED=$(basename "$REPO")
assert_eq "no remote, subdir → $EXPECTED (not sub)" "$EXPECTED" "$GOT"

# ─── Test 7: Directory-name-based clone does not override remote ─────────────
# Historically, a clone named "arqu-engineer" of arqu-co/engineer could
# cause metrics to be written under "arqu-engineer". The remote URL is the
# single source of truth.
tmpdir=$(mktemp -d)
TMPDIRS+=("$tmpdir")
CLONE="$tmpdir/arqu-engineer"
mkdir -p "$CLONE"
(
  cd "$CLONE"
  git init -q
  git remote add origin "https://github.com/arqu-co/engineer.git"
)
GOT=$(cd "$CLONE" && get_repo_name)
assert_eq "clone dir=arqu-engineer, remote=engineer → engineer" "engineer" "$GOT"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
