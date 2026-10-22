#!/usr/bin/env bash
# Agent processes still running inside a worktree (#305).
#
# This file is meant to be sourced, not executed.
#
# Closing a zellij tab does not reliably take its agent with it. kiro runs as
# three processes — `kiro-cli-chat chat`, the bun `tui.js` front end and
# `kiro-cli-chat acp` — and in recommender-systems all three outlived their
# closed tabs for up to two days, one of them in a worktree git had already
# pruned. They were only idle because the credits had run out. Nothing in
# task-force could see them: task-recreate-worker judges liveness by the tab
# name and the radio heartbeat, both gone, and so started a second agent in the
# same worktree beside them. A PM found them with `lsof`.
#
# So this lists, for one worktree, the agent processes whose cwd is inside it.
# The cost is bounded: one `ps` over the whole table, then a cwd lookup only for
# processes whose command looks like an agent (`claude`, `kiro-cli*`, a bun or
# node running kiro-cli) and their descendants — `/proc/<pid>/cwd` on Linux, a
# single batched `lsof -a -d cwd` elsewhere.
#
# The caller's own agent is never listed. task-done runs inside the worker's
# tab, under the very agent that is finishing, so its own ancestry has its cwd
# in the worktree by construction; that tree goes when the tab is closed. The
# exclusion is the whole process tree of the outermost agent among the caller's
# ancestors, so its helpers (the bun front end, an MCP server) go with it.
#
# Environment:
#   TASK_FORCE_NO_PROC_SCAN=1  skip the scan entirely: nothing is ever listed.
#                              The test suite sets it so no run reads this
#                              machine's live process table.
#   AW_PROC_CWD_SOURCE   proc | lsof; default proc when /proc/self/cwd is
#                        readable, else lsof.
#   AW_PROC_ROOT         where proc mode reads (default /proc).
#   AW_PROC_SELF_PID     the pid whose agent tree is excluded (default $$).
#   AW_PROC_KILL_CMD     the command that sends signals (default the builtin).
#   AW_PROC_TERM_WAIT    seconds between TERM and KILL (default 5).

# _aw_proc_table
# `<pid> <ppid> <lstart: 5 words> <command…>` for every process. lstart, not
# etime, because the start time is what tells a recycled pid from the original.
_aw_proc_table() {
  ps -A -o pid= -o ppid= -o lstart= -o command= 2>/dev/null || true
}

# _aw_proc_candidates <self-pid>
# Reads the table on stdin. One `<pid>\t<start>\t<command>` line per agent
# process and per descendant of one, minus the self pid's agent tree.
_aw_proc_candidates() {
  awk -v self="$1" '
    {
      pid = $1; ppid[pid] = $2
      start[pid] = $3 " " $4 " " $5 " " $6 " " $7
      cmd = $8; for (i = 9; i <= NF; i++) cmd = cmd " " $i
      command[pid] = cmd; order[++n] = pid
      # Matched on the whole command line, so a wrapper (node …/claude,
      # bun …/kiro-cli/tui.js, the bash -ic task-work launches) counts too.
      if (cmd ~ /(^|[ \/])claude( |$)/ || cmd ~ /(^|[ \/])kiro-cli[^ \/]*( |$)/ \
          || cmd ~ /(^|[ \/])(bun|node)( .*)?kiro-cli/) agent[pid] = 1
    }
    END {
      # The outermost agent among the caller and its ancestors.
      root = ""
      for (p = self; p != "" && p != "0" && !(p in seen); p = ppid[p]) {
        seen[p] = 1
        if (p in agent) root = p
        if (!(p in ppid)) break
      }
      for (p in agent) keep[p] = 1
      do {                       # descendants of any agent, to a fixed point
        grew = 0
        for (i = 1; i <= n; i++) {
          p = order[i]
          if (!(p in keep) && (ppid[p] in keep)) { keep[p] = 1; grew = 1 }
        }
      } while (grew)
      if (root != "") {          # the agent the caller runs under, and its tree
        drop[root] = 1
        do {
          grew = 0
          for (i = 1; i <= n; i++) {
            p = order[i]
            if (!(p in drop) && (ppid[p] in drop)) { drop[p] = 1; grew = 1 }
          }
        } while (grew)
      }
      for (i = 1; i <= n; i++) {
        p = order[i]
        if ((p in keep) && !(p in drop)) printf "%s\t%s\t%s\n", p, start[p], command[p]
      }
    }'
}

# _aw_proc_cwds <pid>...
# `<pid>\t<cwd>` for each pid whose cwd can be read.
_aw_proc_cwds() {
  local src="${AW_PROC_CWD_SOURCE:-}" root="${AW_PROC_ROOT:-/proc}" pid cwd
  [[ $# -gt 0 ]] || return 0
  if [[ -z "$src" ]]; then
    src=lsof
    [[ -r "$root/self/cwd" ]] && src=proc
  fi
  if [[ "$src" == proc ]]; then
    for pid in "$@"; do
      cwd=$(readlink "$root/$pid/cwd" 2>/dev/null) || continue
      printf '%s\t%s\n' "$pid" "${cwd% (deleted)}"
    done
    return 0
  fi
  # -F: `p<pid>` opens a process, `n<path>` names its cwd. lsof exits 1 when any
  # pid has gone in the meantime, which is no error here.
  local IFS=,
  { lsof -a -d cwd -Fpn -p "$*" 2>/dev/null || true; } | awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { path = substr($0, 2); sub(/ \(deleted\)$/, "", path); print pid "\t" path }'
}

# aw_worktree_agent_procs <dir>
# One `<pid>\t<start>\t<command>` line per agent process whose cwd is <dir> or
# below it. Prints nothing, and succeeds, when there are none.
aw_worktree_agent_procs() {
  local dir="${1%/}" phys cands
  [[ -n "$dir" && "${TASK_FORCE_NO_PROC_SCAN:-}" != 1 ]] || return 0
  # Both spellings: a symlinked worktree base is logical in our paths and
  # physical in the kernel's. A vanished worktree has only the logical one.
  phys=$(cd "$dir" 2>/dev/null && pwd -P) || phys="$dir"
  cands=$(_aw_proc_table | _aw_proc_candidates "${AW_PROC_SELF_PID:-$$}")
  [[ -n "$cands" ]] || return 0
  # shellcheck disable=SC2046  # one word per pid, on purpose
  _aw_proc_cwds $(cut -f1 <<<"$cands") | awk -F'\t' -v d="$dir" -v p="$phys" '
    NR == FNR { cwd[$1] = $2; next }
    ($1 in cwd) {
      c = cwd[$1]
      if (c == d || c == p || index(c, d "/") == 1 || index(c, p "/") == 1) print
    }' - <(printf '%s\n' "$cands")
}

# aw_print_worktree_procs <indent> <lines>
# The listing as `aw_worktree_agent_procs` printed it, one aligned row a process.
aw_print_worktree_procs() {
  local indent="$1" pid start cmd
  while IFS=$'\t' read -r pid start cmd; do
    [[ -n "$pid" ]] || continue
    printf '%s%-7s started %s  %s\n' "$indent" "$pid" "$start" "$cmd"
  done <<<"$2"
}

_aw_proc_signal() {
  if [[ -n "${AW_PROC_KILL_CMD:-}" ]]; then
    "$AW_PROC_KILL_CMD" "$@"
  else
    kill "$@"
  fi
}

# aw_kill_worktree_procs <dir> <lines>
# Stops the processes in <lines> (as listed for <dir>): TERM, then KILL whatever
# is still alive after $AW_PROC_TERM_WAIT seconds. Each pid is signalled only if
# a fresh scan of <dir> still lists it with the same start time — a process that
# exited during the confirmation, or a pid since recycled by an unrelated
# process, is left alone. Prints one line per signal sent; fails when anything
# survived the KILL.
aw_kill_worktree_procs() {
  local dir="$1" listed="$2" now pid start cmd waited=0
  local wait="${AW_PROC_TERM_WAIT:-5}"
  local -a targets=() alive=()
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=5
  now=$(aw_worktree_agent_procs "$dir")
  while IFS=$'\t' read -r pid start cmd; do
    [[ -n "$pid" ]] || continue
    grep -qxF "$(printf '%s\t%s\t%s' "$pid" "$start" "$cmd")" <<<"$now" && targets+=("$pid")
  done <<<"$listed"
  [[ ${#targets[@]} -gt 0 ]] || return 0
  echo "Sending TERM to: ${targets[*]}"
  _aw_proc_signal -TERM "${targets[@]}" 2>/dev/null || true
  while :; do
    alive=()
    for pid in "${targets[@]}"; do
      _aw_proc_signal -0 "$pid" 2>/dev/null && alive+=("$pid")
    done
    [[ ${#alive[@]} -gt 0 && $waited -lt $wait ]] || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  [[ ${#alive[@]} -gt 0 ]] || return 0
  echo "Still running after ${wait}s; sending KILL to: ${alive[*]}"
  _aw_proc_signal -KILL "${alive[@]}" 2>/dev/null || true
  sleep 1
  local -a left=()
  for pid in "${alive[@]}"; do
    _aw_proc_signal -0 "$pid" 2>/dev/null && left+=("$pid")
  done
  if [[ ${#left[@]} -gt 0 ]]; then
    echo "Could not stop: ${left[*]}" >&2
    return 1
  fi
  return 0
}
