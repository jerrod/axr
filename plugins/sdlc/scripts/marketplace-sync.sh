#!/usr/bin/env bash
# marketplace-sync.sh — library for syncing a marketplace clone to its
# default branch's tip. Source from sdlc-update.sh and the test harness.
#
# Marketplace clones under ~/.claude/plugins/marketplaces/ are caches,
# not user workspaces. An earlier version of sdlc-update.sh blindly ran
# `git pull` on whatever branch happened to be checked out — silently
# leaving the clone stuck on a stale feature branch (and every
# subsequent /sdlc:sdlc-update reported "updated" while the plugin version
# never moved). See PR history for the 77-commit stranding incident.

# sync_marketplace LOCATION
#
# Sync the git clone at LOCATION to origin's default branch tip.
#   - On default branch → ff-only pull
#   - On non-default branch with clean tree → auto-switch to default,
#     then ff-only pull. The cache is not user work; moving it is safe.
#   - On non-default branch with dirty tree → warn + stay put +
#     print manual recovery. Never blow away uncommitted changes.
#   - On any git failure → warn + return 0. Never propagate non-zero
#     to the caller (outer loop must keep iterating other marketplaces).
sync_marketplace() {
  local loc="$1"
  local branch default

  # Marketplace clones always use `origin` as their single remote —
  # claude plugins install creates them with `git clone`, which hard-
  # codes origin. Using a literal here avoids a sed-based remote-name
  # parse entirely (and with it any quoting/injection concerns).
  branch=$(git -C "$loc" branch --show-current 2>/dev/null || echo "")

  # Resolve origin's default branch. `symbolic-ref --short` returns
  # "origin/main" (the full short ref including the remote name) so we
  # strip the leading "origin/" via parameter expansion — no sed, no
  # quoting surface. Falls back to "main" if the remote HEAD ref is
  # missing (rare for clones made by `git clone`, but possible in
  # older or hand-initialized caches).
  default=$(git -C "$loc" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  default="${default#origin/}"
  if [ -z "$default" ]; then
    default="main"
    echo "    ⚠ could not resolve origin/HEAD, assuming '$default'"
  fi

  echo "    git fetch..."
  git -C "$loc" fetch --quiet origin 2>&1 | sed 's/^/    /' || true

  if [ "$branch" != "$default" ]; then
    # Dirty-tree check: never auto-switch on top of uncommitted work.
    # There is a theoretical TOCTOU window between this status check
    # and the switch below, but marketplace caches are not concurrently
    # written by any normal workflow — acceptable risk for a cache.
    if [ -n "$(git -C "$loc" status --porcelain 2>/dev/null)" ]; then
      echo "    ⚠ on branch '$branch' with uncommitted changes — skipping"
      # Quote $loc and $default via printf '%q' so terminal control
      # characters in the JSON-sourced installLocation cannot inject
      # escape sequences into the user's terminal.
      printf '      (manually: cd %q && git stash && git switch %q && git pull)\n' \
        "$loc" "$default"
      return 0
    fi
    echo "    ⚠ on branch '$branch' — auto-switching to '$default'"
    # `git switch` (not `git checkout`) is unambiguously a branch op
    # and rejects ref names that look like flags (--orphan, -f, ...).
    git -C "$loc" switch --quiet "$default" 2>&1 | sed 's/^/    /' || {
      echo "    ✗ switch failed, leaving as-is"
      return 0
    }
  fi

  git -C "$loc" pull --ff-only --quiet 2>&1 | sed 's/^/    /' || {
    echo "    ✗ fast-forward failed (diverged or missing upstream)"
    return 0
  }
  echo "    ✓ updated"
}
