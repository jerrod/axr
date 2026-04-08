#!/usr/bin/env bash
# _lib_lock.sh — Journal locking helpers for therapist scripts.
#
# Split out from _lib.sh to keep the main library under the 300-line
# file-size limit. Requires THERAPIST_DIR to be set by the caller (via
# ensure_therapist_dir in _lib.sh). Requires rotate_journal_if_needed
# to be defined before _journal_append_and_rotate is invoked.
#

# _journal_append_and_rotate — callback executed while holding the journal
# lock. Takes the pre-built JSONL entry as arg 1 and performs the append
# and rotation atomically so concurrent hook executions cannot overlap
# with a rotate-in-progress and lose data.
_journal_append_and_rotate() {
  local entry="$1"
  printf '%s\n' "$entry" >>"${THERAPIST_DIR}/journal.jsonl"
  rotate_journal_if_needed
}

# _journal_with_lock — acquire an exclusive journal lock, run the given
# command with its arguments, and release the lock. Prefers flock(1) when
# present (Linux, Homebrew util-linux on macOS). Falls back to a portable
# mkdir-based advisory lock so the plugin works out of the box on macOS
# where flock is not installed by default.
_journal_with_lock() {
  local cb="$1"
  shift
  local lock_file="${THERAPIST_DIR}/journal.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 200
      "$cb" "$@"
    ) 200>"$lock_file"
    return
  fi
  # mkdir is atomic on local filesystems — use a lock directory.
  local lock_dir="${lock_file}.d"
  local waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    # After ~5s, assume the holder crashed and steal the lock.
    if [[ "$waited" -gt 100 ]]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || break
      break
    fi
  done
  # Ensure the lock is released even on callback failure.
  trap 'rm -rf "${lock_dir}" 2>/dev/null || true' RETURN
  "$cb" "$@"
  rm -rf "$lock_dir" 2>/dev/null || true
  trap - RETURN
}
