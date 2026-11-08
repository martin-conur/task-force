#!/usr/bin/env bash
# Shared zellij tab launcher. Sourced by bin/task-work and the other launchers.
#
# Exports:
#   aw_launch_tab <slug> <cwd> <cmd>
#   aw_radio_home_env_prefix   (TASK_FORCE_HOME for a launcher's env prefix, #262)
#   aw_zellij_session_running <session>   (#291)
#   aw_zellij_own_tab_id   (#358)
#   aw_bounded <secs> <cmd...>, aw_zellij_bounded   (#384)
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

# region:zellij-deadline
# aw_bounded <secs> <cmd> [args...] — run <cmd>, stopping it once <secs> (a
# fraction is fine) have passed (#384). Its stdout and stderr pass through. rc
# 124 when the deadline stopped it, else <cmd>'s own. Portable: macOS has no
# timeout(1). A watchdog sleeps beside <cmd> and is cancelled as soon as <cmd>
# ends, so a quick call pays no polling delay; it marks the deadline only while
# <cmd> is still running, so a cancel racing the deadline cannot pass for one.
# Both run in background subshells, which inherit the caller's ERR trap under
# `set -E`: task-reviewer's removes the worktree. Each drops it, and `set -e`,
# first, so a failing <cmd> or a cancelled sleep stays a return code.
aw_bounded() {
  local secs="$1"; shift
  local mark pid wd rc=0
  mark=$(mktemp "${TMPDIR:-/tmp}/aw-bounded.XXXXXX" 2>/dev/null) || { "$@"; return; }
  rm -f "$mark"
  { trap - ERR; set +e; "$@"; } &
  pid=$!
  {
    trap - ERR; set +e
    sleep "$secs"
    kill -0 "$pid" 2>/dev/null || exit 0
    : >"$mark"
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    exit 0
  } </dev/null >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  # Its sleep first: the watchdog then finds <cmd> gone and exits unmarked.
  pkill -P "$wd" 2>/dev/null || kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [[ -e "$mark" ]]; then
    rm -f "$mark"
    return 124
  fi
  return "$rc"
}
# endregion:zellij-deadline

# aw_zellij, bounded (#384): the snap-back's list-tabs and go-to-tab, and the
# caller-position lookup before it. A stalled zellij server used to hold the
# launch there indefinitely, and a list-tabs that answered late or not at all
# ended the snap-back with no log line. Each call gets TASK_FORCE_ZELLIJ_TIMEOUT
# seconds (default 3, as radio's); one that runs out logs `zellij-timeout:`
# with $AW_ZELLIJ_CTX and answers nothing, rc 124. new-tab is not bounded: it
# is the launch itself, and stopping it halfway would leave a tab with no
# record of it.
aw_zellij_bounded() {
  local secs="${TASK_FORCE_ZELLIJ_TIMEOUT:-3}" rc=0 what="${1:-}"
  [[ "$what" != action ]] || what="${2:-}"
  aw_bounded "$secs" aw_zellij "$@" || rc=$?
  if (( rc == 124 )); then
    aw_radio_log "$(printf 'zellij-timeout: %s %ss %s' "$what" "$secs" "${AW_ZELLIJ_CTX:-}")"
  fi
  return "$rc"
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

# The tab this process runs in (#358): the tab_id of the terminal pane
# $ZELLIJ_PANE_ID names, read off `list-panes`. zellij exports that id into
# every terminal pane, so unlike the focused tab it cannot move under us while
# we run. Terminal and plugin panes number separately, hence the is_plugin
# filter; zellij spells a terminal pane `N` or `terminal_N`. Always the session
# we run in, never AW_ZELLIJ_SESSION's. Empty stdout means "could not tell"
# (no pane id, no jq, the pane not listed): the caller must skip, never fall
# back to the focused tab.
aw_zellij_own_tab_id() {
  local p="${ZELLIJ_PANE_ID:-}"
  p="${p#terminal_}"
  case "$p" in *[!0-9]*|"") return 0 ;; esac
  command -v zellij >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  zellij action list-panes --json --tab 2>/dev/null \
    | jq -r --argjson p "$p" \
        '[.[] | select(.id == $p and (.is_plugin // false) == false) | .tab_id]
         | .[0] // empty' 2>/dev/null
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
#
# zellij handles new-tab asynchronously and 0.44 has no way to open a tab
# without focusing it, so the go-to-tab can land before the new tab has
# finished opening, which then takes focus anyway (#311). The race cannot be
# avoided, only corrected: aw_snap_back_to_tab re-checks afterwards.
aw_launch_tab() {
  local slug="$1"
  local cwd="$2"
  local cmd="${3:-}"
  local stay_on_caller_tab="${4:-}"

  local caller_pos=""
  if [[ "$stay_on_caller_tab" == "1" ]] && aw_zellij_reachable \
     && command -v jq >/dev/null 2>&1; then
    caller_pos=$(AW_ZELLIJ_CTX="caller=pre-launch slug=$slug" \
        aw_zellij_bounded action list-tabs --json 2>/dev/null \
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
    aw_snap_back_to_tab "$slug" "$caller_pos"
  fi
}

# Focus the tab at 0-indexed <caller_pos> and make sure it stays focused
# (#311). Checks the active tab right after the go-to-tab and, while it is
# not the caller's, issues go-to-tab again: at most AW_TAB_FOCUS_CHECKS checks
# (default 7), AW_TAB_FOCUS_INTERVAL seconds apart (default 0.25), so the
# worst case is about 1.5s and the common case is two list-tabs, one sleep
# apart.
#
# "Caller active" counts only once list-tabs shows the new tab <slug> (#343):
# a list-tabs answered before zellij has processed the new-tab reports the
# caller active with no new tab yet, and the new tab steals focus right after.
# Even then it takes two consecutive caller-active checks to settle, so a
# steal landing just after the tab appears is still caught.
#
# Once settled it looks once more, AW_TAB_FOCUS_LATE seconds later (default
# 1, 0 skips it, #384): on a loaded server the steal can land after both
# checks, and nothing looked again. A late steal is retried like any other,
# on a budget of its own.
#
# Every exit that leaves focus in doubt writes one `tab-focus:` line to
# radio's log and warns on stderr, so a lost focus always leaves a trace
# (#384): before, a list-tabs that answered nothing usable (empty, slow,
# failed) ended the loop silently. A launch never fails over focus. A retry
# that worked is logged too, to count how often the race actually happens.
# Every list-tabs and go-to-tab is bounded (aw_zellij_bounded).
aw_snap_back_to_tab() {
  local slug="$1" caller_pos="$2"
  local checks="${AW_TAB_FOCUS_CHECKS:-7}" interval="${AW_TAB_FOCUS_INTERVAL:-0.25}"
  local late="${AW_TAB_FOCUS_LATE:-1}"
  local target=$((caller_pos + 1)) gotos=1 i state active="" listed=""
  local seen_new=0 streak=0 late_done=0 late_steal=0 tail=""
  local AW_ZELLIJ_CTX="caller=snap-back slug=$slug"
  # 0 (or 0.0) skips the late look: count it as done already.
  [[ "$late" =~ ^0*\.?0*$ ]] && late_done=2

  aw_zellij_bounded action go-to-tab "$target" 2>/dev/null || true
  for (( i = 1; i <= checks; i++ )); do
    # "<active position> <slug listed?>"; the paint prefixes are stripped as
    # in aw_zellij_tab_id_by_name, since radio may rename the tab already.
    state=$(aw_zellij_bounded action list-tabs --json 2>/dev/null \
      | jq -r --arg n "$slug" \
          '([.[] | select(.active) | .position] | .[0] // empty | tostring)
           + " "
           + (any(.[]; (.name // "" | sub("^⏸️ "; "") | sub("^▶️ "; "")
                        | sub("^❓︎ "; "")) == $n) | tostring)' 2>/dev/null) || state=""
    active="${state%% *}" listed="${state#* }"
    if [[ -z "$active" ]]; then
      aw_radio_log "$(printf 'tab-focus: list-tabs unusable after %d check(s), %d go-to-tab(s) slug=%s caller_position=%s' \
        "$i" "$gotos" "$slug" "$caller_pos")"
      echo "⚠ Could not confirm focus on your tab: zellij's tab list did not answer, so '$slug' may have taken it (logged, grep 'tab-focus:')." >&2
      return 0
    fi
    [[ "$listed" == true ]] && seen_new=1
    if [[ "$active" == "$caller_pos" ]]; then
      (( seen_new )) && streak=$((streak + 1))
      if (( streak >= 2 )); then
        if (( late_done == 0 )); then
          # Settled: one more look, later. The caller still active then
          # settles it again, so streak stays at 1.
          late_done=1 streak=1 checks=$((checks + 1))
          sleep "$late" 2>/dev/null || true
          continue
        fi
        if (( gotos > 1 )); then
          (( late_steal == 0 )) || tail=" late_steal=1"
          aw_radio_log "$(printf 'tab-focus: snap-back needed %d go-to-tab(s) slug=%s caller_position=%s%s' \
            "$gotos" "$slug" "$caller_pos" "$tail")"
        fi
        return 0
      fi
      (( i < checks )) || break
      sleep "$interval" 2>/dev/null || true
      continue
    fi
    # A steal the late look saw gets a budget of its own: the first is spent.
    if (( late_done == 1 && late_steal == 0 )); then
      late_steal=1 checks=$((i + ${AW_TAB_FOCUS_CHECKS:-7}))
    fi
    streak=0
    (( i < checks )) || break
    sleep "$interval" 2>/dev/null || true
    aw_zellij_bounded action go-to-tab "$target" 2>/dev/null || true
    gotos=$((gotos + 1))
  done
  if (( ! seen_new )); then
    aw_radio_log "$(printf 'tab-focus: new tab never appeared after %d check(s) slug=%s caller_position=%s active_position=%s' \
      "$checks" "$slug" "$caller_pos" "$active")"
    echo "⚠ Could not confirm focus on your tab: '$slug' never showed up in zellij's tab list, and may still take focus (logged, grep 'tab-focus:')." >&2
    return 0
  fi
  aw_radio_log "$(printf 'tab-focus: snap-back failed after %d go-to-tab(s) slug=%s caller_position=%s active_position=%s' \
    "$gotos" "$slug" "$caller_pos" "$active")"
  echo "⚠ Could not keep focus on your tab: '$slug' may have taken it (logged, grep 'tab-focus:')." >&2
  return 0
}
