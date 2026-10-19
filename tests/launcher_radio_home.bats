#!/usr/bin/env bats
# Launched tabs carry the launcher's TASK_FORCE_HOME (#262).
#
# A new zellij tab starts from the zellij *server's* environment, not the
# caller's. So a launcher run against a scratch radio home used to log there
# while the agent it started registered in the real ~/.task-force — one launch
# split across two radio states. Every tab launcher now puts the home on the
# tab's command (lib/zellij-tab.sh aw_radio_home_env_prefix); task-pm execs in
# place and inherits it.
#
# Each case re-runs the tab's verbatim `bash -ic` payload (captured by the zellij
# stub) under a *different* TASK_FORCE_HOME, the way the zellij server would,
# and reads the home the agent stub actually started with. The set case uses a
# path with a space, so it also proves the value survives the re-parse whole.
# The unset case asserts positively on both sides: the launcher really ran
# defaulted (its tab-id miss line lands under $HOME/.task-force), and the agent
# starts with the variable unset — not merely that the string is absent.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  cd "$MAIN_REPO"
  export GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  SCRATCH_HOME="$BATS_TEST_TMPDIR/scratch radio home"
  mkdir -p "$SCRATCH_HOME"
  # Where the unset case's defaults land. Never the developer's real $HOME.
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  teardown_all
}

# The post-reboot state task-recreate-worker recovers (see its own suite).
dead_worker() {
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/issue-42" -b task/issue-42
  printf 'BASE_BRANCH=main\nSLUG=issue-42\nGH_URL=https://github.com/owner/repo/issues/42\nTAB_ID=999\n' \
    > "$WORKTREE_BASE/.issue-42.info"
}

# Run launcher <name> with whatever TASK_FORCE_HOME / HOME the caller exported.
launch() {
  case "$1" in
    task-work)            AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" ;;
    task-reviewer)        AW_IMPL=claude-gh run "$TASK_REVIEWER" 42 ;;
    task-reviewer-kiro)   run "$TASK_REVIEWER_KIRO" 42 ;;
    task-recreate-worker) dead_worker; AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 ;;
  esac
}

agent_for() { [[ "$1" == task-reviewer-kiro ]] && echo kiro-cli || echo claude; }

# Re-run the tab's payload as the zellij server would: from ITS environment,
# which here has a different home (or none), never the launcher's.
rerun_tab_cmd() {
  local server_home="$1" cmd
  cmd=$(cat "$STUB_CALLS_DIR/zellij.new-tab-cmd")
  rm -f "$STUB_CALLS_DIR"/*.home
  if [[ "$server_home" == "<unset>" ]]; then
    env -u TASK_FORCE_HOME HOME="$FAKE_HOME" bash -c "$cmd"
  else
    TASK_FORCE_HOME="$server_home" bash -c "$cmd"
  fi
}

assert_forwards_set_home() {
  local launcher="$1" agent
  agent=$(agent_for "$launcher")
  export TASK_FORCE_HOME="$SCRATCH_HOME"
  launch "$launcher"
  assert_success
  run grep -F "TASK_FORCE_HOME=" "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_success
  rerun_tab_cmd "$BATS_TEST_TMPDIR/zellij-server-home"
  run tail -1 "$STUB_CALLS_DIR/$agent.home"
  assert_output "TASK_FORCE_HOME=$SCRATCH_HOME"
}

assert_leaves_unset_home_unset() {
  local launcher="$1" agent
  agent=$(agent_for "$launcher")
  unset TASK_FORCE_HOME
  export HOME="$FAKE_HOME"
  launch "$launcher"
  assert_success
  # The launcher really ran defaulted: its tab-id miss went to the default home.
  run grep -F "tab-id: ${launcher%-kiro} capture missed" "$FAKE_HOME/.task-force/radio/log"
  assert_success
  run grep -F "TASK_FORCE_HOME" "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
  rerun_tab_cmd "<unset>"
  run tail -1 "$STUB_CALLS_DIR/$agent.home"
  assert_output "TASK_FORCE_HOME=<unset>"
}

@test "task-work: the tab carries a set TASK_FORCE_HOME, space and all" {
  assert_forwards_set_home task-work
}

@test "task-work: an unset TASK_FORCE_HOME stays unset in the tab" {
  assert_leaves_unset_home_unset task-work
}

@test "claude task-reviewer: the tab carries a set TASK_FORCE_HOME, space and all" {
  assert_forwards_set_home task-reviewer
}

@test "claude task-reviewer: an unset TASK_FORCE_HOME stays unset in the tab" {
  assert_leaves_unset_home_unset task-reviewer
}

@test "kiro task-reviewer: the tab carries a set TASK_FORCE_HOME, space and all" {
  assert_forwards_set_home task-reviewer-kiro
}

@test "kiro task-reviewer: an unset TASK_FORCE_HOME stays unset in the tab" {
  assert_leaves_unset_home_unset task-reviewer-kiro
}

@test "task-recreate-worker: the tab carries a set TASK_FORCE_HOME, space and all" {
  assert_forwards_set_home task-recreate-worker
}

@test "task-recreate-worker: an unset TASK_FORCE_HOME stays unset in the tab" {
  assert_leaves_unset_home_unset task-recreate-worker
}

# task-pm opens no tab: it execs the agent in place, so the env is inherited.
# Asserted rather than assumed (#262).
@test "task-pm: execs in place, so the agent inherits a set TASK_FORCE_HOME" {
  export ZELLIJ=fake-session TASK_FORCE_HOME="$SCRATCH_HOME"
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  run tail -1 "$STUB_CALLS_DIR/claude.home"
  assert_output "TASK_FORCE_HOME=$SCRATCH_HOME"
}

@test "task-pm: an unset TASK_FORCE_HOME stays unset" {
  unset TASK_FORCE_HOME
  export ZELLIJ=fake-session HOME="$FAKE_HOME"
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  run tail -1 "$STUB_CALLS_DIR/claude.home"
  assert_output "TASK_FORCE_HOME=<unset>"
}
