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
                    | sub("^❓︎ "; "")) == $n)
          | .tab_id]
         | .[0] // empty' 2>/dev/null
}

# Why aw_zellij_tab_id_by_name came back empty for <slug>, as
# "<code> <human text>" on one line. Codes: no-zellij-bin, not-in-zellij,
# no-jq, list-tabs-empty, race, no-match. no-match carries the names zellij did
# report, JSON-quoted so a byte-level mismatch against the slug is visible
# in the line itself rather than needing the (long-gone) tab to reproduce.
aw_zellij_tab_id_miss_reason() {
  local target="$1" tabs names
  if ! command -v zellij >/dev/null 2>&1; then
    echo "no-zellij-bin zellij is not on PATH"; return 0
  fi
  if [[ -z "${ZELLIJ:-}" ]]; then
    echo "not-in-zellij not running inside zellij (\$ZELLIJ unset)"; return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "no-jq jq is not on PATH"; return 0
  fi
  tabs=$(zellij action list-tabs --json 2>/dev/null || true)
  names=$(printf '%s' "$tabs" | jq -c '[.[].name]' 2>/dev/null || true)
  if [[ -z "$names" ]]; then
    echo "list-tabs-empty zellij action list-tabs --json returned nothing parseable"; return 0
  fi
  # The diagnosis re-queries, so a tab that was not listed yet when the lookup
  # ran can be listed now: name that case instead of reporting a mismatch.
  if [[ -n "$(aw_zellij_tab_id_by_name "$target")" ]]; then
    echo "race tab \"$target\" was not listed yet when the lookup ran (it is now)"; return 0
  fi
  echo "no-match no tab named \"$target\" (${#target} chars) in list-tabs; names seen: $names"
}

# Resolve <slug>'s tab_id and append TAB_ID= to <info_file> (#117). On a miss,
# say so on stderr at the moment it happens and append a `tab-id:` line to
# radio's log (#242): before this the miss was silent, and its only symptom was
# task-done's "no tab id captured" hours later, in a different command, after
# the context that explained it was gone. A miss never fails the caller — the
# tab is already open and the agent already running. A hit prints nothing.
aw_record_tab_id() {
  local slug="$1" info_file="$2" caller="$3" id reason code log_file
  id=$(aw_zellij_tab_id_by_name "$slug" || true)
  if [[ -n "$id" ]]; then
    printf 'TAB_ID=%s\n' "$id" >> "$info_file"
    return 0
  fi
  reason=$(aw_zellij_tab_id_miss_reason "$slug")
  code="${reason%% *}"
  log_file="${TASK_FORCE_HOME:-$HOME/.task-force}/radio/log"
  {
    echo "⚠ Could not capture the zellij tab id for '$slug': ${reason#* }."
    echo "  No TAB_ID= was written to $info_file; unless radio's session file"
    echo "  has one, task-done will skip closing this tab — close it by hand then."
    echo "  Logged to $log_file (grep 'tab-id:')."
  } >&2
  if mkdir -p "$(dirname "$log_file")" 2>/dev/null; then
    printf '%s tab-id: %s capture missed slug=%s reason=%s info=%s detail=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$caller" "$slug" "$code" "$info_file" "${reason#* }" \
      >> "$log_file" 2>/dev/null || true
  fi
  return 0
}

# Launch a new zellij tab. See file header for semantics.
#
# Optional 4th arg `stay_on_caller_tab`: when "1", capture the caller's tab
# position before `new-tab` and snap focus back via `go-to-tab` afterwards
# (#130). Used by `task-work --auto` so PM can dispatch workers without
# losing focus. Any other value (including empty/missing) preserves the
# legacy focus-shift behavior.
#
# Failure modes (no $ZELLIJ, no jq, empty position lookup, non-zero
# go-to-tab) fall through to the legacy behavior — the worker spawn must
# never abort because the snap-back path errored. Same defensive style as
# aw_zellij_tab_id_by_name above.
#
# Note on the ~100-300ms flicker window between new-tab and go-to-tab:
# keystrokes typed during that window can land in the new tab. Acceptable
# for --auto (explicit autonomy opt-in; PM is typically idle on radio).
aw_launch_tab() {
  local slug="$1"
  local cwd="$2"
  local cmd="${3:-}"
  local stay_on_caller_tab="${4:-}"

  local caller_pos=""
  if [[ "$stay_on_caller_tab" == "1" && -n "${ZELLIJ:-}" ]] \
     && command -v jq >/dev/null 2>&1; then
    caller_pos=$(zellij action list-tabs --json 2>/dev/null \
      | jq -r '.[] | select(.active) | .position' 2>/dev/null) || caller_pos=""
  fi

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

  # .position is 0-indexed; go-to-tab is 1-indexed (verified zellij 0.44.3).
  if [[ -n "$caller_pos" ]]; then
    zellij action go-to-tab "$((caller_pos + 1))" 2>/dev/null || true
  fi
}
