#!/usr/bin/env bats
# Tests for the root task-done dispatcher (bin/task-done)

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SLUG="my-feature"

run_task_done() {
  local args=("$@")
  run bash -c "echo y | $TASK_DONE_DISPATCHER ${args[*]}"
}

setup() {
  setup_repo
  setup_stubs
  setup_worktree "$SLUG"
  cd "$WORKTREE_BASE/$SLUG"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails with no impl configured" {
  run "$TASK_DONE_DISPATCHER" --force
  assert_failure
  assert_output --partial "no agentic-workflow impl configured"
}

@test "fails on unknown --impl" {
  run "$TASK_DONE_DISPATCHER" --impl bogus --force
  assert_failure
  assert_output --partial "unknown impl"
}

# ---------------------------------------------------------------------------
# Detects impl from the MAIN worktree (not the task worktree)
# ---------------------------------------------------------------------------

@test "detects kiro-notion from main worktree's .kiro/steering/notion-workflow.md" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_DONE_DISPATCHER" --force
  assert_success
  # kiro-notion's task-done prints branch/base lines
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "detects claude-jira and uppercases Jira key in PR title" {
  # Recreate the worktree with a Jira-key-looking slug
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/jira-workflow.md"
  # Need a Jira-shaped slug
  cd "$MAIN_REPO"
  git -C "$MAIN_REPO" worktree remove -f "$WORKTREE_BASE/$SLUG" 2>/dev/null || true
  rm -rf "$WORKTREE_BASE/.$SLUG.info"
  setup_worktree "proj-99"
  cd "$WORKTREE_BASE/proj-99"
  run_task_done --force
  # claude-jira version uppercases
  assert_output --partial '"PROJ-99"'
}

# ---------------------------------------------------------------------------
# Overrides
# ---------------------------------------------------------------------------

@test "--impl forces the impl even when no workflow doc is present" {
  run "$TASK_DONE_DISPATCHER" --impl kiro-notion --force
  assert_success
  assert_output --partial "Branch:   task/$SLUG"
}

@test "AW_IMPL env var picks the impl" {
  AW_IMPL=claude-notion run "$TASK_DONE_DISPATCHER" --force
  assert_success
  assert_output --partial "Branch:   task/$SLUG"
}

# ---------------------------------------------------------------------------
# Passthrough
# ---------------------------------------------------------------------------

@test "--remove-worktree is passed through and cleans up" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_DONE_DISPATCHER" --remove-worktree --force
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}
