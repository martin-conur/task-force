#!/usr/bin/env bats
# Agent processes that outlive their closed tab (#305): lib/worktree-procs.sh,
# task-recreate-worker's refusal and --kill-stale, task-done's warning.
#
# Nothing here reads or signals a real process. ps, lsof and the signal sender
# are stubs fed from fixture files, and every fixture pid is above both kernels'
# pid ceilings (Linux 4194304, macOS 99998), so even a signal that escaped the
# stub would find no process to reach. The suite sets TASK_FORCE_NO_PROC_SCAN=1
# for every other file (tests/setup_suite.bash); this one unsets it per test.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

TASK_DONE="$REPO_ROOT_REAL/bin/task-done"

setup() {
  setup_repo
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  export ZELLIJ=fake-session
  unset TASK_FORCE_NO_PROC_SCAN TASK_FORCE_ROLE
  export AW_PROC_CWD_SOURCE=lsof AW_PROC_TERM_WAIT=0
  export AW_PROC_KILL_CMD="$STUB_BIN/kill-stub"
  # Nothing in the fixture tables descends from it, so no self tree is dropped
  # unless a test says so.
  export AW_PROC_SELF_PID=1
  PROC_FIX="$BATS_TEST_TMPDIR/procs"
  mkdir -p "$PROC_FIX"
  : > "$PROC_FIX/ps.txt"; : > "$PROC_FIX/lsof.txt"; : > "$PROC_FIX/alive"
  export PROC_FIX

  cat > "$STUB_BIN/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps $*" >> "$STUB_CALLS_DIR/ps.calls"
# A second table, from the Nth call on, models a process table that changed
# between the listing and the kill.
n=$(grep -c . "$STUB_CALLS_DIR/ps.calls")
if [[ -f "$PROC_FIX/ps.after" && -n "${PROC_PS_SWITCH_AT:-}" && $n -ge $PROC_PS_SWITCH_AT ]]; then
  cat "$PROC_FIX/ps.after"
else
  cat "$PROC_FIX/ps.txt"
fi
EOF
  cat > "$STUB_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "lsof $*" >> "$STUB_CALLS_DIR/lsof.calls"
cat "$PROC_FIX/lsof.txt"
EOF
  # Records every signal; `-0 <pid>` succeeds only for pids listed in alive.
  cat > "$STUB_BIN/kill-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS_DIR/kill.calls"
if [[ "$1" == -0 ]]; then grep -qxF "$2" "$PROC_FIX/alive"; exit; fi
if [[ "$1" == -TERM ]]; then
  shift
  for p in "$@"; do grep -qxF "$p" "$PROC_FIX/alive.after-term" 2>/dev/null || sed -i.bak "/^$p\$/d" "$PROC_FIX/alive"; done
fi
if [[ "$1" == -KILL ]]; then
  shift
  for p in "$@"; do sed -i.bak "/^$p\$/d" "$PROC_FIX/alive"; done
fi
exit 0
EOF
  chmod +x "$STUB_BIN/ps" "$STUB_BIN/lsof" "$STUB_BIN/kill-stub"
  WT_PHYS="$(cd "$MAIN_REPO/.." && pwd -P)/${REPO_NAME}-worktrees"
}

teardown() {
  teardown_all
}

# proc <pid> <ppid> <cwd> <command…>: one row in the ps table, one in lsof's.
proc() {
  local pid="$1" ppid="$2" cwd="$3"; shift 3
  printf '%s %s Thu Oct 22 19:47:43 2026 %s\n' "$pid" "$ppid" "$*" >> "$PROC_FIX/ps.txt"
  printf 'p%s\nfcwd\nn%s\n' "$pid" "$cwd" >> "$PROC_FIX/lsof.txt"
  echo "$pid" >> "$PROC_FIX/alive"
}

dead_worker() {
  local slug="${1:-issue-42}"
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug"
  seed_hook_carriers "$WORKTREE_BASE/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nGH_URL=https://github.com/owner/repo/issues/42\n' "$slug" \
    > "$WORKTREE_BASE/.$slug.info"
}

# The recommender-systems case: kiro's three processes left in the worktree,
# plus an agent in another worktree and a non-agent in this one, neither of
# which is any of this command's business.
stray_kiro_in() {
  local wt="$1"
  proc 5000001 1 "$wt" kiro-cli-chat chat --agent worker
  proc 5000002 5000001 "$wt/src" bun /opt/kiro-cli/tui.js
  proc 5000003 1 "$wt" kiro-cli-chat acp
  proc 5000004 1 "$WT_PHYS/other-slug" claude /worker
  proc 5000005 1 "$wt" vim notes.md
}

kill_calls() { cat "$STUB_CALLS_DIR/kill.calls" 2>/dev/null || true; }

lib() {
  bash -c "source '$REPO_ROOT_REAL/lib/worktree-procs.sh'; $1"
}

# ---------------------------------------------------------------------------
# The helper
# ---------------------------------------------------------------------------

@test "helper: lists agent processes and their children in the worktree, nothing else" {
  stray_kiro_in /work/wt
  run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_line --index 0 --partial $'5000001\tThu Oct 22 19:47:43 2026\tkiro-cli-chat chat --agent worker'
  assert_line --index 1 --partial $'5000002\t'
  assert_line --index 2 --partial $'5000003\t'
  assert_equal "${#lines[@]}" 3
}

@test "helper: a child of an agent is listed even when its own command is not one" {
  proc 5000001 1 /work/wt kiro-cli-chat chat
  proc 5000006 5000001 /work/wt node /opt/mcp/server.js
  proc 5000007 1 /work/wt node /opt/mcp/server.js
  run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_line --index 1 --partial $'5000006\t'
  refute_output --partial 5000007
}

@test "helper: asks lsof for the cwd of agent candidates only, in one call" {
  stray_kiro_in /work/wt
  run lib "aw_worktree_agent_procs /work/wt"
  run cat "$STUB_CALLS_DIR/lsof.calls"
  assert_output "lsof -a -d cwd -Fpn -p 5000001,5000002,5000003,5000004"
}

@test "helper: a prefix of the worktree path is not the worktree" {
  proc 5000001 1 /work/wt-2 claude /worker
  run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_output ""
}

@test "helper: leaves out the agent the caller runs under, and its whole tree" {
  # task-done runs under the finishing worker's own claude, cwd in the worktree.
  proc 5000010 1 /work/wt claude /worker
  proc 5000011 5000010 /work/wt /bin/zsh -c task-done
  proc 5000012 5000010 /work/wt node mcp-server
  proc 5000001 1 /work/wt kiro-cli-chat chat
  AW_PROC_SELF_PID=5000011 run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_output --partial $'5000001\t'
  refute_output --partial 5000010
  refute_output --partial 5000011
  refute_output --partial 5000012
}

@test "helper: reads /proc/<pid>/cwd in proc mode, and a deleted cwd still counts" {
  local root="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$root/5000001" "$root/5000003"
  ln -s /work/wt "$root/5000001/cwd"
  ln -s "/work/wt (deleted)" "$root/5000003/cwd"
  proc 5000001 1 ignored kiro-cli-chat chat
  proc 5000003 1 ignored kiro-cli-chat acp
  AW_PROC_CWD_SOURCE=proc AW_PROC_ROOT="$root" run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_line --index 0 --partial $'5000001\t'
  assert_line --index 1 --partial $'5000003\t'
  [[ ! -f "$STUB_CALLS_DIR/lsof.calls" ]]
}

@test "helper: TASK_FORCE_NO_PROC_SCAN=1 lists nothing and never runs ps" {
  stray_kiro_in /work/wt
  TASK_FORCE_NO_PROC_SCAN=1 run lib "aw_worktree_agent_procs /work/wt"
  assert_success
  assert_output ""
  [[ ! -f "$STUB_CALLS_DIR/ps.calls" ]]
}

# ---------------------------------------------------------------------------
# task-recreate-worker
# ---------------------------------------------------------------------------

@test "recreate: refuses and lists the pids still running in the worktree" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "agent processes are still running in worktree 'issue-42'"
  assert_output --partial "5000001 "
  assert_output --partial "5000002 "
  assert_output --partial "5000003 "
  refute_output --partial 5000004
  refute_output --partial 5000005
  assert_output --partial "--kill-stale"
  assert_equal "$(kill_calls)" ""
  run grep -qs new-tab "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "recreate: --force does not get past running processes" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --force
  assert_failure
  assert_output --partial "agent processes are still running"
  assert_equal "$(kill_calls)" ""
}

@test "recreate: --kill-stale signals exactly the worktree's pids, then recovers" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --kill-stale --yes
  assert_success
  assert_output --partial "Sending TERM to: 5000001 5000002 5000003"
  run grep -E '^-(TERM|KILL)' "$STUB_CALLS_DIR/kill.calls"
  assert_output "-TERM 5000001 5000002 5000003"
  run grep -c -E '5000004|5000005' "$STUB_CALLS_DIR/kill.calls"
  assert_output 0
  assert_stub_called zellij "new-tab --name issue-42"
  run grep 'stray-procs: task-recreate-worker stopped 5000001 5000002 5000003 in' "$TASK_FORCE_HOME/radio/log"
  assert_success
}

@test "recreate: --kill-stale sends KILL to what survives the TERM, and only that" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  echo 5000003 > "$PROC_FIX/alive.after-term"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --kill-stale --yes
  assert_success
  run grep -E '^-(TERM|KILL)' "$STUB_CALLS_DIR/kill.calls"
  assert_line --index 0 "-TERM 5000001 5000002 5000003"
  assert_line --index 1 "-KILL 5000003"
  assert_equal "${#lines[@]}" 2
}

@test "recreate: --kill-stale refuses to recover when a process will not die" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  # The stub never removes it: TERM and KILL both bounce.
  cat > "$STUB_BIN/kill-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS_DIR/kill.calls"
[[ "$1" == -0 && "$2" == 5000003 ]] && exit 0
[[ "$1" == -0 ]] && exit 1
exit 0
EOF
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --kill-stale --yes
  assert_failure
  assert_output --partial "Could not stop: 5000003"
  run grep -q new-tab "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "recreate: --kill-stale skips a pid recycled since the listing" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  # From the second ps call on, 5000002 is a different process (new start time).
  sed 's/^5000002 5000001 Thu Oct 22 19:47:43 2026/5000002 1 Fri Oct 23 08:00:00 2026/' \
    "$PROC_FIX/ps.txt" > "$PROC_FIX/ps.after"
  PROC_PS_SWITCH_AT=2 AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --kill-stale --yes
  assert_success
  run grep -E '^-TERM' "$STUB_CALLS_DIR/kill.calls"
  assert_output "-TERM 5000001 5000003"
}

@test "recreate: --kill-stale without a terminal or --yes signals nothing" {
  dead_worker issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --kill-stale </dev/null
  assert_failure
  assert_output --partial "no terminal to ask on"
  assert_equal "$(kill_calls)" ""
}

@test "recreate: with no processes in the worktree, recovery is unchanged" {
  dead_worker issue-42
  proc 5000004 1 "$WT_PHYS/other-slug" claude /worker
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  refute_output --partial "agent processes"
  assert_stub_called zellij "new-tab --name issue-42"
  assert_equal "$(kill_calls)" ""
}

# ---------------------------------------------------------------------------
# task-done
# ---------------------------------------------------------------------------

@test "task-done: warns about and lists the processes, logs them, and still removes the worktree" {
  setup_worktree issue-42
  stray_kiro_in "$WT_PHYS/issue-42"
  cd "$WORKTREE_BASE/issue-42"
  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Agent processes are still running in this worktree"
  assert_output --partial "5000001 "
  assert_output --partial "5000003 "
  refute_output --partial 5000004
  assert_output --partial "kill 5000001 5000002 5000003"
  run grep 'stray-procs: task-done left 5000001 5000002 5000003 running in' "$TASK_FORCE_HOME/radio/log"
  assert_success
  [[ ! -d "$WT_PHYS/issue-42" ]]
  assert_equal "$(kill_calls)" ""
}

@test "task-done: with no processes in the worktree, no warning" {
  setup_worktree issue-42
  proc 5000004 1 "$WT_PHYS/other-slug" claude /worker
  cd "$WORKTREE_BASE/issue-42"
  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  refute_output --partial "Agent processes"
  run grep -qs stray-procs "$TASK_FORCE_HOME/radio/log"
  assert_failure
}
