#!/usr/bin/env bash
# Board regeneration, shared by task-work and task-done on the two local loadouts
# (both callers live in lib/trackers/local.sh since #236 / #237).
#
# There were four byte-similar copies of this before #223; the fix below had to
# land in all four, which is the point at which this repo extracts (see the
# reuse/drift beat in the workflow docs). The `# region:board-regen` sentinels at
# each call site are drift-guarded by tools/check-drift.sh.
#
# Resolution order is `task-board` on $PATH first, then the caller's own sibling
# copy. That order is deliberate — an install can override with a newer copy —
# but it is also how #223 happened: ~/.local/bin/task-board is a symlink into
# whichever checkout ran install.sh last, so in a repo that dispatcher cannot
# resolve a loadout for, the call fails. It used to fail under `|| true`, which
# is why the symptom was a missing tasks/_board.md and nothing else. Changing the
# precedence is a separate question with its own blast radius (#223 direction 3);
# what changed here is that the failure is no longer silent.

# Regenerate <repo>/tasks/_board.md.
#
# Usage: aw_regenerate_board <repo-root> [<caller-script-path>]
#
# The second argument locates the sibling fallback copy; it defaults to the
# script that called us, which is what every current call site wants.
#
# Always returns 0. A board that failed to render is worth a warning, not worth
# aborting task-work after the worktree and tab already exist — but it is warned
# about, on stderr, naming the copy that ran, and the failing command's own
# diagnostics are passed through rather than discarded.
aw_regenerate_board() {
  local repo="$1" self="${2:-${BASH_SOURCE[1]}}" board sibling

  if ! board=$(aw_resolve_task_board "$self"); then
    # No task-board anywhere: not an error. A repo can be perfectly usable
    # without a rendered board, and the caller has no way to install one.
    return 0
  fi

  "$board" --repo "$repo" >/dev/null && return 0

  sibling="$(cd "$(dirname "$self")" && pwd)/task-board"
  echo "⚠ task-board failed — $repo/tasks/_board.md was NOT regenerated." >&2
  echo "  Ran: $board" >&2
  if [[ "$board" != "$sibling" ]]; then
    echo "  That copy came from \$PATH, not from this checkout. If it is the" >&2
    echo "  ~/.local/bin symlink, it points at whichever clone ran install.sh" >&2
    echo "  last; re-run install.sh from this one, or regenerate by hand:" >&2
    echo "    $sibling --repo $repo" >&2
  fi
  return 0
}

# Print the task-board to use on behalf of the script at $1: $PATH's copy if
# there is one, else the sibling next to $1. Returns 1 when there is neither.
#
# $1 is required, deliberately with no `${1:-${BASH_SOURCE[1]}}` default like the
# one aw_regenerate_board carries. That default reads as a convenience but could
# never be right here: a caller reaching this function goes through
# aw_regenerate_board, so BASH_SOURCE[1] is that frame — this file — and this
# file has no task-board beside it. So it fails at the call site instead, where
# whoever wrote the call can see it.
aw_resolve_task_board() {
  # No apostrophe in the message: the text of a ${var:?...} is shell-parsed, so
  # one would open a quote and take the rest of the file with it.
  local self="${1:?aw_resolve_task_board: path of the calling script is required}" sibling
  if command -v task-board >/dev/null 2>&1; then
    command -v task-board
    return 0
  fi
  sibling="$(cd "$(dirname "$self")" && pwd)/task-board"
  [[ -x "$sibling" ]] || return 1
  printf '%s\n' "$sibling"
}
