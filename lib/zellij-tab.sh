#!/usr/bin/env bash
# Shared zellij tab launcher. Sourced by bin/task-work and the other launchers.
#
# Exports:
#   aw_launch_tab <slug> <cwd> <cmd>
#   aw_radio_home_env_prefix   (TASK_FORCE_HOME for a launcher's env prefix, #262)
#   aw_zellij_session_running <session>   (#291)
#
# Every zellij call here goes through aw_zellij, so a launcher that sets
# AW_ZELLIJ_SESSION drives that session instead of the one it runs in (#291).
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

# `zellij "$@"`, or `zellij -s "$AW_ZELLIJ_SESSION" "$@"` when a launcher
# targets another session (#291): task-recreate-worker --session, which
# task-monitor's R uses to open a worker's tab in its repo's session rather
# than the monitor's. `-s` wins over the caller's own $ZELLIJ_SESSION_NAME.
# A `-s` naming no running session prints a plain-text session list and exits
# 0 without creating anything; aw_zellij_session_running is the check to make
# before relying on that.
aw_zellij() {
  if [[ -n "${AW_ZELLIJ_SESSION:-}" ]]; then
    zellij -s "$AW_ZELLIJ_SESSION" "$@"
  else
    zellij "$@"
  fi
}

# True when there is a zellij session to talk to: the one we run in, or the
# one AW_ZELLIJ_SESSION names.
aw_zellij_reachable() {
  [[ -n "${ZELLIJ:-}" || -n "${AW_ZELLIJ_SESSION:-}" ]]
}

# True when stdin is exactly one JSON array: a stream of several values fails
# even if the last is an array, as does empty input. Slurped, because `jq -e`
# on EMPTY input exits 0 on jq 1.6 (4 on 1.7+): an empty list-tabs answer would
# pass as an array there (#296). Slurping turns empty input into `[]`, false on
# both.
aw_jq_is_array() {
  jq -se 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1
}

# rc 0 when zellij session <session> is running: its list-tabs answers with a
# JSON array. A session that is not running answers with plain text and exit
# 0, so the exit status alone proves nothing. Without jq it cannot tell, and
# says no.
aw_zellij_session_running() {
  local session="$1"
  [[ -n "$session" ]] || return 1
  command -v zellij >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  zellij -s "$session" action list-tabs --json 2>/dev/null \
    | aw_jq_is_array
}

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
  aw_zellij action list-tabs --json 2>/dev/null \
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
  if ! aw_zellij_reachable; then
    echo "not-in-zellij not running inside zellij (\$ZELLIJ unset)"; return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "no-jq jq is not on PATH"; return 0
  fi
  tabs=$(aw_zellij action list-tabs --json 2>/dev/null || true)
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

# Name of the tab that holds <tab_id> right now (#260). The read half of the
# check task-done makes before `close-tab-by-id`: an id is only valid within one
# zellij server's lifetime, so after a restart a sidecar's TAB_ID can name an
# unrelated tab, and closing it closes that tab. Protocol:
#   rc 0 + name : a tab has that id; this is its visible name
#   rc 0 + ""   : list-tabs answered and no tab has that id
#   rc 2 + ""   : could not ask (jq missing, non-numeric id, list-tabs empty or
#                 unparseable) — the caller cannot tell "ours" from "not ours"
aw_zellij_tab_name_by_id() {
  local id="$1" tabs
  case "$id" in ''|*[!0-9]*) return 2 ;; esac
  command -v jq >/dev/null 2>&1 || return 2
  tabs=$(aw_zellij action list-tabs --json 2>/dev/null || true)
  printf '%s' "$tabs" | aw_jq_is_array || return 2
  printf '%s' "$tabs"     | jq -r --argjson t "$id" '[.[] | select(.tab_id == $t) | .name] | .[0] // empty' 2>/dev/null
}

# True when tab name <name> belongs to <slug>: the bare slug, or the slug after
# a space-separated prefix. radio paints `⏸️ <slug>` / `▶️ <slug>` / `❓︎ <slug>`
# (#140), and matching on the space-delimited tail rather than on that exact
# list keeps a prefix added later from turning every teardown into a refusal —
# while `other-<slug>` still does not pass for `<slug>`.
aw_tab_name_is_slug() {
  local name="$1" slug="$2"
  [[ -n "$slug" ]] || return 1
  [[ "$name" == "$slug" || "$name" == *" $slug" ]]
}

# Append one line to radio's log, the place every tab-binding diagnosis lands
# (`tab-id:` at capture, `tab-close:` at teardown). Never fails the caller.
aw_radio_log() {
  local log_file="${TASK_FORCE_HOME:-$HOME/.task-force}/radio/log"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log_file" 2>/dev/null || true
}

# The radio-home part of a launcher's RADIO_ENV_PREFIX (#262): `TASK_FORCE_HOME=<v> `
# when the launcher has one, nothing when it does not. A new zellij tab starts
# from the zellij *server's* environment, not the caller's, so without this a
# launcher pointed at a scratch home logs there while the agent it starts
# registers in the real ~/.task-force — one launch split across two radio
# states, and a probe whose role name matches a live worker overwrites it.
# Unset stays unset, so the agent defaults exactly as before. %q because the
# prefix is re-parsed by the tab's `bash -ic`: a path with a space must arrive
# as one value. Every tab launcher appends this; task-pm execs in place and
# inherits the env, so it needs none.
aw_radio_home_env_prefix() {
  [[ -n "${TASK_FORCE_HOME:-}" ]] || return 0
  printf 'TASK_FORCE_HOME=%q ' "$TASK_FORCE_HOME"
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
  # The diagnosis re-queries list-tabs (once for the names, once more for the
  # race check) rather than reusing the first lookup's output. That is up to
  # three zellij round-trips, deliberately: it only runs once something has
  # already failed, and the race check is only meaningful as a *fresh* query.
  # Do not fold them together.
  reason=$(aw_zellij_tab_id_miss_reason "$slug")
  code="${reason%% *}"
  log_file="${TASK_FORCE_HOME:-$HOME/.task-force}/radio/log"
  {
    echo "⚠ Could not capture the zellij tab id for '$slug': ${reason#* }."
    echo "  No TAB_ID= was written to $info_file; unless radio's session file"
    echo "  has one, task-done will skip closing this tab — close it by hand then."
    echo "  Logged to $log_file (grep 'tab-id:')."
  } >&2
  aw_radio_log "$(printf 'tab-id: %s capture missed slug=%s reason=%s info=%s detail=%s' \
    "$caller" "$slug" "$code" "$info_file" "${reason#* }")"
  return 0
}

# Launch a new zellij tab. See file header for semantics.
#
# Optional 4th arg `stay_on_caller_tab`: when "1", capture the caller's tab
# position before `new-tab` and snap focus back via `go-to-tab` afterwards
# (#130). task-work, task-recreate-worker and task-reviewer all pass it by
# default so PM can dispatch without losing focus (#254); task-work /
# task-recreate-worker --focus pass "" instead. Any other value (including
# empty/missing) shifts focus to the new tab.
#
# Failure modes (no $ZELLIJ, no jq, empty position lookup, non-zero
# go-to-tab) fall through to the legacy behavior — the worker spawn must
# never abort because the snap-back path errored. Same defensive style as
# aw_zellij_tab_id_by_name above.
#
# Note on the ~100-300ms flicker window between new-tab and go-to-tab:
# keystrokes typed during that window can land in the new tab. Acceptable:
# the dispatching PM is typically idle on radio while the launch runs.
aw_launch_tab() {
  local slug="$1"
  local cwd="$2"
  local cmd="${3:-}"
  local stay_on_caller_tab="${4:-}"

  local caller_pos=""
  if [[ "$stay_on_caller_tab" == "1" ]] && aw_zellij_reachable \
     && command -v jq >/dev/null 2>&1; then
    caller_pos=$(aw_zellij action list-tabs --json 2>/dev/null \
      | jq -r '.[] | select(.active) | .position' 2>/dev/null) || caller_pos=""
  fi

  if [[ -z "$cmd" ]]; then
    # Interactive shell cd'd into the worktree. --cwd handles the cd; zellij
    # uses the user's default shell when no command is specified.
    aw_zellij action new-tab --name "$slug" --cwd "$cwd"
  else
    # `--` is required before the command to stop zellij's own arg parsing.
    # `bash -ic` gives us interactive shell semantics (reads bashrc etc.) so
    # the agent command runs in the same environment the user would get.
    aw_zellij action new-tab --name "$slug" --cwd "$cwd" -- bash -ic "$cmd"
  fi

  # .position is 0-indexed; go-to-tab is 1-indexed (verified zellij 0.44.3).
  if [[ -n "$caller_pos" ]]; then
    aw_zellij action go-to-tab "$((caller_pos + 1))" 2>/dev/null || true
  fi
}
