#!/usr/bin/env bash
# sdlc-update — Check and apply all available plugin updates.
# No Claude tokens consumed — pure shell.
set -euo pipefail

PLUGINS_DIR="$HOME/.claude/plugins"
INSTALLED="$PLUGINS_DIR/installed_plugins.json"
MARKETPLACES="$PLUGINS_DIR/known_marketplaces.json"

# shellcheck source=plugins/sdlc/scripts/update-config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-config.sh"
# shellcheck source=plugins/sdlc/scripts/marketplace-sync.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/marketplace-sync.sh"

# ─── CLI flags ────────────────────────────────────────────────────

MODE="update"
for arg in "$@"; do
  case "$arg" in
    --auto-on)
      write_config "auto_update" "true"
      echo "Auto-update enabled. Future sessions will update plugins automatically."
      exit 0
      ;;
    --auto-off)
      write_config "auto_update" "false"
      echo "Auto-update disabled. Use /sdlc-update to check manually."
      exit 0
      ;;
    --disable-checks)
      write_config "update_check" "false"
      echo "Update checks disabled. Run /sdlc-update --enable-checks to re-enable."
      exit 0
      ;;
    --enable-checks)
      write_config "update_check" "true"
      echo "Update checks re-enabled."
      exit 0
      ;;
    --snooze) MODE="snooze" ;;
    --check-only) MODE="check" ;;
    --status)
      echo "=== sdlc-update config ==="
      echo "  auto_update: $(read_config auto_update false)"
      echo "  update_check: $(read_config update_check true)"
      echo "  snoozed: $(snooze_status)"
      exit 0
      ;;
  esac
done

if [ "$MODE" = "snooze" ]; then
  do_snooze
  exit 0
fi

if [ ! -f "$INSTALLED" ]; then
  echo "ERROR: $INSTALLED not found"
  exit 1
fi

# ─── Phase 1: Update marketplace repos ────────────────────────────
# sync_marketplace lives in marketplace-sync.sh (sourced above) so
# it can be unit-tested in isolation. We also emit a lookup table
# (marketplace → loc|repo) here so Phase 2 resolves marketplace info
# in pure shell, avoiding the previous N+1 python-subprocess pattern.

echo "=== Updating marketplace repos ==="
echo ""

# Guard sourced vars so a refactor dropping any export fails loud.
: "${STATE_DIR:?STATE_DIR must be exported by update-config.sh}"
: "${SNOOZE_FILE:?SNOOZE_FILE must be exported by update-config.sh}"

# Unique per-process temp files — no collision on concurrent runs.
MKT_LOOKUP=$(mktemp)
MKT_ROWS=$(mktemp)
PLUGIN_ROWS=$(mktemp)
STALE_FILE=$(mktemp)
cleanup_temp_files() {
  rm -f "$MKT_LOOKUP" "$MKT_ROWS" "$PLUGIN_ROWS" "$STALE_FILE"
}
trap cleanup_temp_files EXIT

# Build the marketplace lookup table AND the Phase 1 iteration rows
# in a single python3 call that writes BOTH to tempfiles before
# returning. This avoids the earlier pipe-then-consume pattern where
# a python crash mid-write could leave a partial lookup file that
# Phase 2 would silently consume without an error.
if ! SDLC_MF="$MARKETPLACES" SDLC_LOOKUP="$MKT_LOOKUP" SDLC_ROWS="$MKT_ROWS" python3 -c "
import json, os
with open(os.environ['SDLC_MF']) as f:
    data = json.load(f)
with open(os.environ['SDLC_LOOKUP'], 'w') as lookup, \
     open(os.environ['SDLC_ROWS'], 'w') as rows:
    for name, info in data.items():
        source = info.get('source', {})
        loc = info.get('installLocation', '')
        stype = source.get('source', '')
        repo = source.get('repo', '')
        lookup.write(f'{name}\t{loc}\t{repo}\n')
        if stype == 'directory':
            rows.write(f'dir|{name}||{loc}\n')
        elif stype == 'github':
            rows.write(f'github|{name}|{repo}|{loc}\n')
"; then
  echo "ERROR: failed to parse $MARKETPLACES" >&2
  exit 1
fi

while IFS='|' read -r stype name label loc; do
  if [ "$stype" = "dir" ]; then
    header="  $name (local: $loc)"
  elif [ "$stype" = "github" ]; then
    header="  $name (github: $label)"
  else
    continue
  fi
  echo "$header"
  if [ -z "$loc" ] || ! git -C "$loc" rev-parse --git-dir >/dev/null 2>&1; then
    if [ "$stype" = "dir" ]; then
      echo "    (not a git repo, skipping)"
    fi
    continue
  fi
  sync_marketplace "$loc"
done <"$MKT_ROWS"

echo ""

# ─── Phase 2: Check each installed plugin for staleness ───────────
# python3 emits all installed-plugin rows into a tempfile (not a pipe)
# so a parse error surfaces via the explicit exit-code check below —
# a crash mid-stream would otherwise silently produce partial rows.
# Reading from a regular file also keeps the while-loop in the parent
# shell, which matches the Phase 1 pattern.

echo "=== Checking installed plugins ==="
echo ""

if ! SDLC_INSTALLED="$INSTALLED" SDLC_ROWS="$PLUGIN_ROWS" python3 -c "
import json, os
with open(os.environ['SDLC_INSTALLED']) as f:
    data = json.load(f)
plugins = data.get('plugins', {})
with open(os.environ['SDLC_ROWS'], 'w') as rows:
    for key, installs in plugins.items():
        # lastUpdated is expected to be ISO-8601 so lexicographic max
        # matches chronological; coerce None to '' to avoid TypeError.
        latest = max(installs, key=lambda x: x.get('lastUpdated') or '')
        name = key.split('@')[0]
        marketplace = key.split('@')[1] if '@' in key else ''
        sha = latest.get('gitCommitSha', '')
        version = latest.get('version', 'unknown')
        rows.write(f'{name}|{marketplace}|{sha}|{version}\n')
"; then
  echo "ERROR: failed to parse $INSTALLED" >&2
  exit 1
fi

while IFS='|' read -r name marketplace sha version; do
  remote_sha=""
  if [ -n "$marketplace" ]; then
    # Resolve marketplace info via a pure-bash scan of the pre-built
    # lookup table. No awk forks per plugin, and IFS=$'\t' means
    # paths or names containing spaces are preserved intact.
    mkt_loc=""
    mkt_repo=""
    while IFS=$'\t' read -r _key _loc _repo; do
      if [ "$_key" = "$marketplace" ]; then
        mkt_loc="$_loc"
        mkt_repo="$_repo"
        break
      fi
    done <"$MKT_LOOKUP"
    # Try local git first
    if [ -n "$mkt_loc" ] && git -C "$mkt_loc" rev-parse --git-dir >/dev/null 2>&1; then
      remote_sha=$(git -C "$mkt_loc" rev-parse HEAD 2>/dev/null || echo "")
    fi
    # Fall back to git ls-remote for GitHub-sourced marketplaces.
    # Validate mkt_repo against a strict allowlist (letters, digits,
    # dot, underscore, slash, hyphen) so a crafted entry in
    # known_marketplaces.json cannot introduce unexpected characters
    # into the URL argument. Consistent with the plugin-name check
    # in Phase 3.
    if [ -z "$remote_sha" ] && [ -n "$mkt_repo" ] &&
      [[ "$mkt_repo" =~ ^[A-Za-z0-9_./-]+$ ]]; then
      remote_sha=$(git ls-remote "https://github.com/$mkt_repo.git" HEAD 2>/dev/null | awk '{print $1}' || echo "")
    fi
  fi

  if [ -z "$remote_sha" ]; then
    printf "  %-30s %s (cannot check)\n" "$name" "$version"
    continue
  fi

  short_installed="${sha:0:7}"
  short_remote="${remote_sha:0:7}"

  if [ "$sha" = "$remote_sha" ]; then
    printf "  %-30s ✓ current (%s)\n" "$name" "$short_installed"
  else
    printf "  %-30s ✗ stale (%s → %s)\n" "$name" "$short_installed" "$short_remote"
    echo "${name}|${version}" >>"$STALE_FILE"
  fi
done <"$PLUGIN_ROWS"

echo ""

if [ "$MODE" = "check" ]; then
  if [ -s "$STALE_FILE" ]; then
    count=$(wc -l <"$STALE_FILE" | tr -d ' ')
    echo "$count plugin(s) need updating. Run /sdlc-update to apply."
  else
    echo "All plugins are current."
  fi
  exit 0
fi

# ─── Phase 3: Update stale plugins ───────────────────────────────

if [ -s "$STALE_FILE" ]; then
  STALE_COUNT=$(wc -l <"$STALE_FILE" | tr -d ' ')
  echo "=== Updating $STALE_COUNT stale plugin(s) ==="
  echo ""

  rm -f "$STATE_DIR/just-upgraded-from.txt"

  while IFS='|' read -r plugin_name old_version; do
    # Defense-in-depth: validate the plugin name comes from the
    # allowed character set before passing it to the claude CLI.
    # Legitimate plugin names use letters, digits, underscore, dot,
    # hyphen, @ (scoping), and / (path-like refs). Anything else
    # rejects the entry — a tampered installed_plugins.json with a
    # crafted name cannot reach `claude plugins install`.
    if ! [[ "$plugin_name" =~ ^[A-Za-z0-9_.@/-]+$ ]]; then
      echo "  ✗ skipping plugin with invalid name: $plugin_name" >&2
      continue
    fi
    echo "  Updating $plugin_name..."
    # Wrap in `if` so `set -e` is suppressed for the condition — a
    # bare pipeline with pipefail would abort the script on install
    # failure before we can log the error and continue to the next
    # plugin. With `if`, pipefail still propagates the install rc
    # as the pipeline's exit code, but set -e doesn't trigger.
    if claude plugins install "$plugin_name" 2>&1 | sed 's/^/    /'; then
      echo "    ✓ updated"
      echo "$plugin_name|$old_version" >>"$STATE_DIR/just-upgraded-from.txt"
    else
      echo "    ✗ failed"
    fi
  done <"$STALE_FILE"

  rm -f "$SNOOZE_FILE"
  echo ""

  # ─── Phase 4: Show what changed ──────────────────────────────────
  # Single python3 call (via render_changelog.py) walks the whole
  # upgraded-from list once and emits the formatted output — no
  # per-plugin subprocess. See render_changelog.py for the logic.

  if [ -f "$STATE_DIR/just-upgraded-from.txt" ]; then
    echo "=== What's new ==="
    echo ""
    # Let stderr surface naturally so a python import error or a
    # malformed marketplaces json shows up to the operator instead
    # of being silently swallowed. `|| true` keeps a non-zero exit
    # from killing the outer "Done" banner.
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/render_changelog.py" \
      "$PLUGINS_DIR" \
      "$MARKETPLACES" \
      "$STATE_DIR/just-upgraded-from.txt" || true
    rm -f "$STATE_DIR/just-upgraded-from.txt"
  fi

  echo "=== Done ==="
  echo ""
  echo "Run /reload-plugins to pick up the changes."
else
  echo "All plugins are current. Nothing to update."
fi
