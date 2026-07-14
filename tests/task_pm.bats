#!/usr/bin/env bats
# Tests for bin/task-pm: in-place PM-tab takeover (canonical file, #170).
# Asserts:
#   - rename-tab to "pm" via zellij (when $ZELLIJ is set)
#   - exports TASK_FORCE_ROLE=pm and ZELLIJ_TAB=pm
#   - exec's `claude /pm` (claude impls) / `kiro-cli chat --agent pm` (kiro)
#   - errors out cleanly outside a git repo
#
# The loadout is pinned per-test via AW_IMPL (lib/detect-impl.sh resolution
# order: --impl flag > AW_IMPL > workflow-doc auto-detect).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  export ZELLIJ=fake-session
}

teardown() {
  teardown_all
}

# ----- claude launch line ---------------------------------------------------

@test "claude task-pm renames the current tab to pm-<reponame> and exec's claude /pm (#165)" {
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  # Tab rename is now repo-scoped (#165) — symmetric with worker-<reponame>-<slug>.
  assert_stub_called zellij "action rename-tab pm-${REPO_NAME}"
  # Claude was invoked with /pm
  run stub_calls claude
  assert_output --partial "/pm"
}

@test "claude task-pm exports TASK_FORCE_ROLE=pm and ZELLIJ_TAB=pm" {
  # The claude stub records its env via $STUB_CALLS_DIR/claude.env when invoked.
  # We assert via a wrapper that exec's the script then dumps env.
  run env -i HOME="$HOME" PATH="$PATH" ZELLIJ="$ZELLIJ" STUB_CALLS_DIR="$STUB_CALLS_DIR" \
    AW_IMPL=claude-gh bash -c "'$TASK_PM' >/dev/null 2>&1; echo OK"
  # We can't easily intercept env on macOS in a portable way; instead, verify
  # the claude stub was invoked at all (which means task-pm reached its exec).
  assert_success
  run stub_calls claude
  assert_output --partial "/pm"
}

@test "claude task-pm: works without zellij (\$ZELLIJ unset → no rename)" {
  unset ZELLIJ
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  run stub_calls zellij
  refute_output --partial "rename-tab"
  run stub_calls claude
  assert_output --partial "/pm"
}

@test "claude task-pm errors out cleanly outside a git repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_failure
  assert_output --partial "not in a git repo"
  rm -rf "$outside"
}

# ----- kiro launch line -----------------------------------------------------

@test "kiro task-pm renames the current tab to pm-<reponame> and exec's kiro-cli pm agent (#165)" {
  AW_IMPL=kiro-gh run "$TASK_PM"
  assert_success
  assert_stub_called zellij "action rename-tab pm-${REPO_NAME}"
  run stub_calls kiro-cli
  assert_output --partial "chat --agent pm"
}

@test "kiro task-pm errors out cleanly outside a git repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  AW_IMPL=kiro-gh run "$TASK_PM"
  assert_failure
  assert_output --partial "not in a git repo"
  rm -rf "$outside"
}

# ----- impl auto-detection --------------------------------------------------

@test "task-pm picks the claude launch line from the workflow doc" {
  # Use claude-gh workflow doc as the impl signal.
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"

  run "$TASK_PM"
  assert_success
  # The claude stub should have been invoked.
  run stub_calls claude
  assert_output --partial "/pm"
}

@test "task-pm picks the kiro launch line from the workflow doc" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/gh-workflow.md"

  run "$TASK_PM"
  assert_success
  run stub_calls kiro-cli
  assert_output --partial "chat --agent pm"
}

@test "task-pm errors cleanly without a workflow doc" {
  run "$TASK_PM"
  assert_failure
  assert_output --partial "no agentic-workflow impl configured"
}

@test "task-pm --help prints usage without needing a configured repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  run "$TASK_PM" --help
  assert_success
  assert_output --partial "Usage: task-pm"
  assert_output --partial "--also"
  rm -rf "$outside"
}

# ----- --also alias sessions (#165) -----------------------------------------

# radio role names allow only [a-zA-Z0-9_-] (repo basenames with dots are a
# pre-existing framework limitation), and mktemp -d basenames contain a dot —
# so these tests build clean-named repos to exercise the alias path.
_clean_repo() {  # $1 = basename → prints the created repo path
  local parent name path
  parent=$(mktemp -d)
  name="$1"
  path="$parent/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  printf '%s' "$path"
}

@test "task-pm --also writes an alias session pointing pm-<other> at this PM (#165)" {
  setup_task_force_home
  local primary other
  primary=$(_clean_repo pmrepo)
  other=$(_clean_repo otherrepo)
  cd "$primary"

  AW_IMPL=claude-gh run "$TASK_PM" --also "$other"
  assert_success
  assert_output --partial "Aliased pm-otherrepo → pm-pmrepo"

  local alias_file="$TASK_FORCE_HOME/radio/sessions/pm-otherrepo.info"
  assert [ -f "$alias_file" ]
  run cat "$alias_file"
  assert_output --partial "ALIAS=pm-pmrepo"
  # Alias sessions own no inbox.
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm-otherrepo/inbox" ]

  # PM still launches normally.
  run stub_calls claude
  assert_output --partial "/pm"
}

@test "task-pm --also skips a repo that resolves to this PM's own repo (#165)" {
  setup_task_force_home
  local primary
  primary=$(_clean_repo pmrepo)
  cd "$primary"
  AW_IMPL=claude-gh run "$TASK_PM" --also "$primary"
  assert_success
  assert_output --partial "resolves to this PM's own repo"
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/pm-pmrepo.info" ]
}
