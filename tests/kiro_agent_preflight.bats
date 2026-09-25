#!/usr/bin/env bats
# The kiro launchers refuse to spawn an agent that does not resolve (#218).
#
# `kiro-cli chat --agent <name>` does NOT fail when <name> cannot be found: it
# prints one io error to stderr, immediately scrolled past by the TUI it then
# starts, and falls back to a built-in default agent carrying none of
# task-force's hooks. The role never registers, and radio is silently dead for
# that whole session — presenting as a radio bug rather than a launch bug.
#
# In practice this arrives as a stale install, not a missing one: the global
# ~/.kiro/agents/*.json are symlinks into the checkout that installed them, so
# renaming or moving that checkout leaves dangling links behind. That is the
# state the machine this was diagnosed on was in.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  # Point HOME at an empty dir so the real ~/.kiro/agents can neither satisfy
  # nor pollute these assertions.
  FAKE_HOME=$(mktemp -d)
  export HOME="$FAKE_HOME"
}

teardown() {
  [[ -n "${FAKE_HOME:-}" ]] && rm -rf "$FAKE_HOME"
  teardown_all
}

# ----- the guard itself ------------------------------------------------------

@test "aw_require_kiro_agent passes when the workspace agent exists" {
  setup_kiro_agents
  source "$REPO_ROOT_REAL/lib/kiro-agent.sh"
  run aw_require_kiro_agent worker "$MAIN_REPO" "task-init kiro-gh"
  assert_success
}

@test "aw_require_kiro_agent passes when only the global agent exists" {
  mkdir -p "$HOME/.kiro/agents"
  echo '{}' > "$HOME/.kiro/agents/worker.json"
  source "$REPO_ROOT_REAL/lib/kiro-agent.sh"
  run aw_require_kiro_agent worker "$MAIN_REPO" "task-init kiro-gh"
  assert_success
}

@test "aw_require_kiro_agent fails, names both paths, and names the fix" {
  source "$REPO_ROOT_REAL/lib/kiro-agent.sh"
  run aw_require_kiro_agent worker "$MAIN_REPO" "task-init kiro-gh"
  assert_failure
  assert_output --partial "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output --partial "$HOME/.kiro/agents/worker.json"
  assert_output --partial "task-init kiro-gh"
}

@test "a DANGLING global symlink is reported as such, not merely as missing" {
  # The whole point: the file "exists" to ls, so a plain not-found message would
  # send someone looking in the wrong place.
  mkdir -p "$HOME/.kiro/agents"
  ln -s /nonexistent/checkout/worker.json "$HOME/.kiro/agents/worker.json"
  source "$REPO_ROOT_REAL/lib/kiro-agent.sh"
  run aw_require_kiro_agent worker "$MAIN_REPO" "task-init kiro-gh"
  assert_failure
  assert_output --partial "DANGLING SYMLINK"
  assert_output --partial "/nonexistent/checkout/worker.json"
}

# ----- wired into the launchers ---------------------------------------------

@test "kiro task-work aborts before creating a worktree, branch or tab" {
  run env AW_IMPL=kiro-gh "$KIRO_GH_TASK_WORK" probe
  assert_failure
  assert_output --partial "kiro agent 'worker' does not resolve"
  # Nothing was scaffolded — the abort is before any side effect.
  assert [ ! -d "$WORKTREE_BASE/probe" ]
  run git -C "$MAIN_REPO" rev-parse --verify --quiet task/probe
  assert_failure
  run bash -c "grep -c 'action new-tab' '$STUB_CALLS_DIR/zellij.calls' 2>/dev/null || echo 0"
  assert_output "0"
}

@test "kiro task-work proceeds once the agent resolves" {
  setup_kiro_agents
  run env AW_IMPL=kiro-gh "$KIRO_GH_TASK_WORK" probe
  assert_success
  assert [ -d "$WORKTREE_BASE/probe" ]
}

@test "task-pm aborts BEFORE renaming the tab on a kiro loadout" {
  # #165 RC-6: a PM that renames its tab and then dies runs sessionless, so the
  # ordering is the assertion, not just the exit status.
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  export ZELLIJ=fake-session
  run "$TASK_PM"
  assert_failure
  assert_output --partial "kiro agent 'pm' does not resolve"
  run bash -c "grep -c 'action rename-tab' '$STUB_CALLS_DIR/zellij.calls' 2>/dev/null || echo 0"
  assert_output "0"
}

@test "task-pm on a CLAUDE loadout is unaffected by the kiro preflight" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"
  export ZELLIJ=fake-session
  run "$TASK_PM"
  assert_success
  refute_output --partial "does not resolve"
}
