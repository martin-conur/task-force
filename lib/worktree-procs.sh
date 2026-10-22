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
# agent processes (see `is_agent` below for what counts) and their descendants
# — `/proc/<pid>/cwd` on Linux, a single batched `lsof -a -d cwd` elsewhere.
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
    function base(w) { sub(/.*\//, "", w); return w }
    function agent_word(w) { w = base(w); return w == "claude" || w ~ /^kiro-cli/ }
    # Judged by what runs, not by any word on the line, so `less docs/claude`
    # is not an agent. Three shapes are: the binary itself (claude,
    # kiro-cli-chat); a bun or node launcher whose script is one (node …/claude,
    # bun …/kiro-cli/tui.js); and a shell -c whose command string runs one, the
    # bash -ic wrapper task-work launches an agent in. The wrapper has to count:
    # it is the outermost agent above the caller, so the self exclusion below
    # drops it, and a stray tab leaves one behind with the rest. A shell -c
    # running `less docs/claude` still counts; the listing shows it, and
    # --kill-stale asks before it signals.
    function is_agent(i, a0, s) {
      a0 = base($8)
      if (agent_word(a0)) return 1
      if (a0 == "bun" || a0 == "node") {
        for (i = 9; i <= NF; i++) if ($i !~ /^-/) break
        return i <= NF && (agent_word($i) || $i ~ /kiro-cli/)
      }
      if (a0 ~ /^-?(bash|sh|zsh|dash)$/ && $9 ~ /^-[a-zA-Z]*c[a-zA-Z]*$/) {
        for (i = 10; i <= NF; i++) if (agent_word($i)) return 1
      }
      return 0
    }
    {
      pid = $1; ppid[pid] = $2
      start[pid] = $3 " " $4 " " $5 " " $6 " " $7
      cmd = $8; for (i = 9; i <= NF; i++) cmd = cmd " " $i
      command[pid] = cmd; order[++n] = pid
      if (is_agent()) agent[pid] = 1
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

# _aw_still_running <dir> <lines>
# The pids in <lines> that a fresh scan of <dir> still lists with the same start
# time, one a line. This, not `kill -0`, is what "still running" means here:
# `kill -0` fails alike for a process that is gone and for one we may not signal
# (EPERM), and counting the second as stopped would recover beside it.
_aw_still_running() {
  local now pid start cmd
  now=$(aw_worktree_agent_procs "$1")
  while IFS=$'\t' read -r pid start cmd; do
    [[ -n "$pid" ]] || continue
    if grep -qxF "$(printf '%s\t%s\t%s' "$pid" "$start" "$cmd")" <<<"$now"; then
      echo "$pid"
    fi
  done <<<"$2"
}

# _aw_lines_for <lines> <pids>: the rows of <lines> for these pids, one a line.
_aw_lines_for() {
  awk -F'\t' -v want=" $(tr '\n' ' ' <<<"$2")" 'index(want, " " $1 " ")' <<<"$1"
}

# aw_kill_worktree_procs <dir> <lines>
# Stops the processes in <lines> (as listed for <dir>): TERM, then KILL whatever
# is still running after $AW_PROC_TERM_WAIT seconds. Each pid is signalled only
# if a fresh scan of <dir> still lists it with the same start time, so a process
# that exited during the confirmation, or a pid since recycled by an unrelated
# process, is left alone. Prints one line per signal sent; fails when anything
# is still running after the KILL, including a process that refused the signal.
aw_kill_worktree_procs() {
  local dir="$1" listed="$2" waited=0 targets alive left
  local wait="${AW_PROC_TERM_WAIT:-5}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=5
  targets=$(_aw_still_running "$dir" "$listed")
  [[ -n "$targets" ]] || return 0
  listed=$(_aw_lines_for "$listed" "$targets")
  echo "Sending TERM to: $(tr '\n' ' ' <<<"$targets" | sed 's/ $//')"
  # shellcheck disable=SC2086  # one word per pid, on purpose
  _aw_proc_signal -TERM $targets 2>/dev/null || true
  while :; do
    alive=$(_aw_still_running "$dir" "$listed")
    [[ -n "$alive" && $waited -lt $wait ]] || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  [[ -n "$alive" ]] || return 0
  echo "Still running after ${wait}s; sending KILL to: $(tr '\n' ' ' <<<"$alive" | sed 's/ $//')"
  # shellcheck disable=SC2086
  _aw_proc_signal -KILL $alive 2>/dev/null || true
  sleep 1
  left=$(_aw_still_running "$dir" "$(_aw_lines_for "$listed" "$alive")")
  if [[ -n "$left" ]]; then
    echo "Could not stop: $(tr '\n' ' ' <<<"$left" | sed 's/ $//')" >&2
    return 1
  fi
  return 0
}
