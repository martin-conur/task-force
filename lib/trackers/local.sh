#!/usr/bin/env bash
# Local-markdown tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed. $AW_ROOT must be set by the
# caller before sourcing — this is the only module that pulls in another lib,
# and bin/task-done sets AW_ROOT for lib/detect-impl.sh before it gets here.
#
# The only tracker whose task-done does real work of its own: the backlog lives
# in the repo, so a finished task has to be struck off two local artifacts no
# forge is going to update.

# shellcheck source=lib/board-regen.sh
source "$AW_ROOT/lib/board-regen.sh"

aw_tracker_usage_steps() {
  echo "  1. Show the diff summary and existing PR (or print gh pr create command)"
  echo "  2. Remove the slug entry from .git/task-force/state.json"
  echo "  3. Regenerate tasks/_board.md from the main worktree"
  echo "  4. Remove the worktree"
  echo "  5. Close the zellij tab"
}

# Drop this slug's line from the JSONL sidecar, then re-render the board.
#
# Both read the MAIN worktree: `tasks/` and `.git/task-force/` live there, and
# by the time this fires the task worktree has already been removed.
#
# `aw_regenerate_board` always returns 0 by contract (lib/board-regen.sh) — a
# board that failed to render is worth a warning, not worth aborting a cleanup
# whose worktree and tab are already gone (#223). The `|| true` at the call site
# is belt-and-braces over that, not a substitute for it.
aw_tracker_post_cleanup() {
  local main_worktree="$1" slug="$2" impl="$3" state_file
  state_file="$main_worktree/.git/task-force/state.json"
  if [[ -f "$state_file" ]]; then
    awk -v slug="$slug" '
      $0 !~ ("\"slug\"[[:space:]]*:[[:space:]]*\"" slug "\"") { print }
    ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  fi
  # Pass the caller explicitly rather than letting aw_regenerate_board default
  # `self` to ${BASH_SOURCE[1]} (lib/board-regen.sh:30). That default used to
  # resolve to <impl>/bin/task-done, whose sibling is <impl>/bin/task-board;
  # from here it would resolve to THIS file, which has no task-board beside it,
  # and the sibling fallback would silently find nothing. Naming the impl's own
  # task-done keeps the resolution byte-identical to pre-#236 — $PATH first,
  # then that loadout's sibling copy — so this inversion changes no behaviour
  # here. #238 consolidates the two task-board copies; this line moves with it.
  aw_regenerate_board "$main_worktree" "$AW_ROOT/$impl/bin/task-done"
}
