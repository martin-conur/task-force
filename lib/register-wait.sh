#!/usr/bin/env bash
# Wait for a launched agent's radio register, and say why when it does not land
# (#304, #393).
#
# This file is meant to be sourced, not executed.
#
# A launcher that prints "Started worker" and returns has said something about
# zellij, not radio. A missing role command, missing hooks and an agent still
# booting all look the same from outside, and a PM that reads "not registered"
# as "never started" retypes the role prompt into a run already under way. So
# task-work, task-reviewer and task-recreate-worker each wait for the role's
# SessionStart / agentSpawn register: a session file written since the launch,
# by the expected agent, bound to the new tab. When none lands they warn and
# still exit 0 — the tab and the agent are up — naming which case it is,
# checked from the worktree.
#
# Exports:
#   aw_register_wait_secs [<launcher-value>]   seconds to wait: <launcher-value>
#                                              (a launcher's own variable), else
#                                              $TASK_FORCE_REGISTER_WAIT, else 30
#   aw_radio_session_file <role>               the role's radio session file
#   aw_info_field <key> <file>                 one KEY=value field of a sidecar
#   aw_register_wait <session-file> <agent> <launched-at> <tab-id> <secs>
#                                              0 once the register is in; else 1,
#                                              with the reason in AW_REGISTER_WHY
#   aw_register_case <agent> <role> <dir>      the warning's "which case" lines

# shellcheck source=lib/hook-carrier.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-carrier.sh"

aw_register_wait_secs() {
  local v="${1:-${TASK_FORCE_REGISTER_WAIT:-30}}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=30
  printf '%s' "$v"
}

aw_radio_session_file() {
  printf '%s/radio/sessions/%s.info' "${TASK_FORCE_HOME:-$HOME/.task-force}" "$1"
}

aw_info_field() {
  [[ -f "$2" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$2"
}

# Prints nothing and succeeds once the register is in; otherwise prints why not.
_aw_register_status() {
  local file="$1" agent="$2" since="$3" want_tab="$4" hb got tab_id
  [[ -f "$file" ]] || { echo "no session file was written"; return 1; }
  hb=$(aw_info_field LAST_HEARTBEAT "$file")
  # ISO-8601 UTC at one-second resolution, so a string compare orders them.
  if [[ -z "$hb" || "$hb" < "$since" ]]; then
    echo "the session file is left over from before the launch (heartbeat ${hb:-none})"
    return 1
  fi
  got=$(aw_info_field AGENT "$file")
  if [[ "$got" != "$agent" ]]; then
    echo "the session file says AGENT=${got:-<none>}, not $agent"
    return 1
  fi
  tab_id=$(aw_info_field TAB_ID "$file")
  if [[ -z "$tab_id" ]]; then
    echo "it registered with an empty TAB_ID, so no wake can reach it"
    return 1
  fi
  if [[ -n "$want_tab" && "$tab_id" != "$want_tab" ]]; then
    echo "it registered TAB_ID=$tab_id, but the new tab is $want_tab"
    return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # AW_REGISTER_WHY is read by the caller
aw_register_wait() {
  local file="$1" agent="$2" since="$3" want_tab="$4" secs="$5" waited=0
  AW_REGISTER_WHY=""
  while ! AW_REGISTER_WHY=$(_aw_register_status "$file" "$agent" "$since" "$want_tab"); do
    ((waited >= secs)) && return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# aw_register_case <agent> <role> <dir>
# Indented for a `Warning:` block. Checked now, not at launch: a file can go
# missing after the pre-launch check, or arrive too late for the agent to read.
aw_register_case() {
  local agent="$1" role="$2" dir="$3"
  if ! aw_dir_has_role_file "$agent" "$dir" "$role"; then
    echo "         $(aw_role_file_rel "$agent" "$role") is missing from the worktree: the $role never"
    echo "         started, it has no role prompt. Restore the file, then retry the launch."
  elif ! aw_dir_has_hook_carrier "$agent" "$dir" "$role"; then
    echo "         $(aw_hook_carrier_rel "$agent" "$role") carries no 'radio register' hook: the $role"
    echo "         runs, but radio cannot wake it (its own 'radio send' still works)."
    echo "         Do not retype its prompt; it is already working."
  else
    echo "         The role file and the radio hooks are both there: it is still starting,"
    echo "         or a startup prompt is waiting in the tab (claude's folder-trust question,"
    echo "         kiro's upgrade dialog). Look at the tab before retrying anything."
  fi
}
