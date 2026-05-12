#!/usr/bin/env bash
# Shared zellij tab launcher. Sourced by every <impl>/bin/task-work.
#
# Exports:
#   aw_launch_tab <slug> <cwd> <cmd>
#
# Writes a throwaway KDL layout with the command baked in, then calls
#   zellij action new-tab --name <slug> --layout <layout>
# so the command starts inside the new tab atomically — no focus race,
# no write-chars, no interleaving across concurrent task-work invocations.
#
# If <cmd> is empty, the tab opens an interactive shell in <cwd> (used for
# --no-launch). Otherwise the tab runs:
#   bash -c "cd <cwd> && exec <cmd>"

# Escape \ and " for KDL-string interpolation. KDL strings do not expand shell
# variables, so $ and {} are safe to leave alone.
aw_kdl_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # \ -> \\
  s="${s//\"/\\\"}"   # " -> \"
  printf '%s' "$s"
}

# Launch a new zellij tab. See file header for semantics.
aw_launch_tab() {
  local slug="$1"
  local cwd="$2"
  local cmd="${3:-}"

  local cwd_q
  cwd_q=$(printf '%q' "$cwd")

  local exec_line
  if [[ -z "$cmd" ]]; then
    # Interactive shell cd'd into the worktree. Use the user's default shell.
    exec_line="cd $cwd_q && exec \"\${SHELL:-bash}\" -i"
  else
    exec_line="cd $cwd_q && exec $cmd"
  fi

  local layout
  layout=$(mktemp -t aw-layout.XXXXXX) || {
    echo "Error: mktemp failed" >&2
    return 1
  }
  # macOS mktemp doesn't support --suffix; rename to .kdl for clarity.
  mv "$layout" "$layout.kdl"
  layout="$layout.kdl"

  {
    printf 'layout {\n'
    printf '    pane {\n'
    printf '        command "bash"\n'
    printf '        args "-c" "%s"\n' "$(aw_kdl_escape "$exec_line")"
    printf '    }\n'
    printf '}\n'
  } > "$layout"

  zellij action new-tab --name "$slug" --layout "$layout"

  # Zellij reads the layout synchronously on new-tab, but defer cleanup as
  # insurance across zellij versions. The background job is detached so it
  # doesn't block the caller's exit.
  ( sleep 2 && rm -f "$layout" ) >/dev/null 2>&1 &
}
