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
