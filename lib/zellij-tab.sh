#!/usr/bin/env bash
# Shared zellij tab launcher. Sourced by every <impl>/bin/task-work.
#
# Exports:
#   aw_launch_tab <slug> <cwd> <cmd>
#
# Creates a new zellij tab named <slug>, with cwd <cwd>, running <cmd> as the
# initial pane's command (via `zellij action new-tab --cwd <cwd> --name <slug>
# -- bash -c "<cmd>"`).
#
# This is atomic — the command is started as part of tab creation, so there is
# no focus race and no interleaving across concurrent task-work invocations.
#
# If <cmd> is empty, opens an interactive shell cd'd into <cwd> (for
# --no-launch).
#
# NOTE: We pass `-- bash -c "<cmd>"` instead of a custom --layout file because
# --layout replaces the session's tab-bar / default template, which blanks the
# tab-bar plugin's output (i.e. tab names stop appearing). `-- CMD` is the
# zellij-native path for "new tab running this command" and preserves the
# session UI.

# Resolve a freshly-created tab's stable zellij tab_id by its name. Used by
# task-work right after aw_launch_tab to persist TAB_ID into $INFO_FILE so
# task-done has an authoritative source independent of the radio session
# file's mid-life state (#117). Empty stdout means "could not resolve" —
# zellij not running, jq absent, or the tab isn't visible yet — caller
# must treat that as a soft skip (task-done falls back to the radio
# session file in that case).
#
# Race-safe against in-flight `radio busy` / `radio ready` paints (#117
# review): the worker's SessionStart → first-prompt → radio busy chain can
# repaint the tab name to "▶️ <slug>" between aw_launch_tab returning and
# this lookup running. The jq filter strips known paint prefixes from
# .name before comparing against $n (which is always the bare slug, since
# task-work passes $SLUG), so the match still hits regardless of paint
# state. Keep this prefix list in sync with `_rename_tab` in `radio`.
aw_zellij_tab_id_by_name() {
  local target="$1"
  [[ -n "$target" ]] || return 0
  command -v zellij >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  zellij action list-tabs --json 2>/dev/null \
    | jq -r --arg n "$target" \
        '[.[]
          | select((.name
                    | sub("^⏸️ "; "")
                    | sub("^▶️ "; "")
                    | sub("^❓ "; "")) == $n)
          | .tab_id]
         | .[0] // empty' 2>/dev/null
}

# Launch a new zellij tab. See file header for semantics.
aw_launch_tab() {
  local slug="$1"
  local cwd="$2"
  local cmd="${3:-}"

  if [[ -z "$cmd" ]]; then
    # Interactive shell cd'd into the worktree. --cwd handles the cd; zellij
    # uses the user's default shell when no command is specified.
    zellij action new-tab --name "$slug" --cwd "$cwd"
  else
    # `--` is required before the command to stop zellij's own arg parsing.
    # `bash -ic` gives us interactive shell semantics (reads bashrc etc.) so
    # the agent command runs in the same environment the user would get.
    zellij action new-tab --name "$slug" --cwd "$cwd" -- bash -ic "$cmd"
  fi
}
