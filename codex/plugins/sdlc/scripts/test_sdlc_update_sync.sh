#!/usr/bin/env bash
# Tests for sync_marketplace in marketplace-sync.sh — branch safety +
# auto-switch. Regression coverage for the bug where sdlc-update.sh
# blindly pulled whatever branch was checked out in
# ~/.claude/plugins/marketplaces/<m>/ clones, silently stranding them
# on stale feature branches while reporting "updated".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/marketplace-sync.sh
source "$SCRIPT_DIR/marketplace-sync.sh"

# Confirm the function is actually loaded. If marketplace-sync.sh ever
# stops exporting sync_marketplace (e.g. renamed or moved), fail loud —
# previous versions of this test extracted the body via sed and could
# silently produce an empty function, making the tests vacuously pass.
if ! declare -F sync_marketplace >/dev/null 2>&1; then
  echo "FATAL: sync_marketplace not loaded from marketplace-sync.sh"
  exit 2
fi

PASS=0
FAIL=0
TMPDIRS=()

cleanup() {
  # Empty-array-safe expansion: `${var[@]+"${var[@]}"}` expands to
  # nothing when the array is unset/empty, avoiding both the
  # `set -u` unbound error on older bash and the ambiguous
  # `${var[@]:-}` pattern that loops once with an empty string.
  for d in ${TMPDIRS[@]+"${TMPDIRS[@]}"}; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# ─── Helpers ─────────────────────────────────────────────────────────

# make_bare_remote → creates a bare repo with 2 commits on main and
# explicitly sets HEAD to refs/heads/main so `symbolic-ref
# --short refs/remotes/origin/HEAD` in clones resolves to "main" via
# the real code path (not the main fallback). Without the explicit
# HEAD set, tests would still pass but for the wrong reason — via the
# fallback — and a bug in resolution logic would not be caught.
make_bare_remote() {
  local tmp
  tmp=$(mktemp -d)
  TMPDIRS+=("$tmp")
  (cd "$tmp" && git init -q --bare)
  git -C "$tmp" symbolic-ref HEAD refs/heads/main

  local seed
  seed=$(mktemp -d)
  TMPDIRS+=("$seed")
  (
    cd "$seed"
    git init -q
    git config user.email "t@t.t"
    git config user.name "t"
    git checkout -q -b main
    echo one >f
    git add f
    git commit -q -m "one"
    echo two >f
    git add f
    git commit -q -m "two"
    git remote add origin "$tmp"
    git push -q origin main
  )
  echo "$tmp"
}

# make_clone REMOTE BRANCH → clones and checks out the given branch
make_clone() {
  local remote="$1" branch="$2"
  local tmp
  tmp=$(mktemp -d)
  TMPDIRS+=("$tmp")
  git clone -q "$remote" "$tmp"
  (
    cd "$tmp"
    git config user.email "t@t.t"
    git config user.name "t"
    if [ "$branch" != "main" ]; then
      git checkout -q -b "$branch"
    fi
  )
  echo "$tmp"
}

# advance_main REMOTE → push a new commit to the remote's main
advance_main() {
  local remote="$1"
  local tmp
  tmp=$(mktemp -d)
  TMPDIRS+=("$tmp")
  (
    cd "$tmp"
    git clone -q "$remote" .
    git config user.email "t@t.t"
    git config user.name "t"
    git checkout -q main
    echo three >f
    git add f
    git commit -q -m "three"
    git push -q origin main
  )
}

# run_sync LOC → invoke sync_marketplace and capture its output for
# later use in failure reports. Previously output was suppressed via
# >/dev/null 2>&1, which masked failure detail; now we buffer the
# output and only display it if a subsequent assertion fails.
# Reset at declaration AND at the start of each call so a test block
# that doesn't call run_sync cannot see stale output from a prior test.
SYNC_OUTPUT=""
run_sync() {
  SYNC_OUTPUT=""
  SYNC_OUTPUT=$(sync_marketplace "$1" 2>&1 || true)
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
    if [ -n "$SYNC_OUTPUT" ]; then
      echo "  sync_marketplace output:"
      printf '    %s\n' "$SYNC_OUTPUT"
    fi
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test 1: clone on main gets fast-forwarded ─────────────────────
REMOTE=$(make_bare_remote)
CLONE=$(make_clone "$REMOTE" main)
advance_main "$REMOTE"
run_sync "$CLONE"
ACTUAL=$(cd "$CLONE" && git log --oneline | wc -l | tr -d ' ')
assert_eq "on main → fast-forward picks up new commit" "3" "$ACTUAL"

# ─── Test 2: clone on feature branch auto-switches to main ─────────
# Regression test — this is the bug that silently stranded the
# arqu-plugins marketplace on fix/ci-install-bun for weeks.
REMOTE=$(make_bare_remote)
CLONE=$(make_clone "$REMOTE" feat-something)
advance_main "$REMOTE"
run_sync "$CLONE"
ACTUAL_BRANCH=$(cd "$CLONE" && git branch --show-current)
ACTUAL_COMMITS=$(cd "$CLONE" && git log --oneline | wc -l | tr -d ' ')
assert_eq "feature branch → auto-switch to main" "main" "$ACTUAL_BRANCH"
assert_eq "feature branch → post-switch fast-forward picks up new commit" "3" "$ACTUAL_COMMITS"

# ─── Test 3: dirty tree on feature branch → no switch ──────────────
# Safety: never blow away uncommitted user changes without consent.
REMOTE=$(make_bare_remote)
CLONE=$(make_clone "$REMOTE" feat-dirty)
(cd "$CLONE" && echo dirty >uncommitted.txt)
advance_main "$REMOTE"
run_sync "$CLONE"
ACTUAL_BRANCH=$(cd "$CLONE" && git branch --show-current)
HAS_UNCOMMITTED=$(cd "$CLONE" && [ -f uncommitted.txt ] && echo "yes" || echo "no")
assert_eq "dirty tree on feature branch → stays on branch" "feat-dirty" "$ACTUAL_BRANCH"
assert_eq "dirty tree → uncommitted file preserved" "yes" "$HAS_UNCOMMITTED"

# ─── Test 4: symbolic-ref resolution — bare HEAD is used, not fallback ─
# Guards against the bug-for-the-wrong-reason failure mode: when the
# bare repo's HEAD is set correctly, the "could not resolve origin/HEAD"
# warning must NOT appear in the output.
REMOTE=$(make_bare_remote)
CLONE=$(make_clone "$REMOTE" main)
run_sync "$CLONE"
if echo "$SYNC_OUTPUT" | grep -q "could not resolve origin/HEAD"; then
  echo "FAIL: symbolic-ref should resolve origin/HEAD without fallback"
  echo "  sync_marketplace output:"
  printf '    %s\n' "$SYNC_OUTPUT"
  FAIL=$((FAIL + 1))
else
  echo "PASS: symbolic-ref resolves origin/HEAD without fallback"
  PASS=$((PASS + 1))
fi

# ─── Summary ─────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
