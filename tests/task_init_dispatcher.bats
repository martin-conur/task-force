#!/usr/bin/env bats
# Tests for the unified task-init dispatcher (repo root task-init)

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Delegation — no extra args (exercises the empty-array PASSTHROUGH fix)
# ---------------------------------------------------------------------------

@test "delegates to claude-notion with no passthrough args" {
  run "$TASK_INIT_DISPATCHER" claude-notion
  assert_success
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
}

@test "delegates to kiro-notion with no passthrough args" {
  run "$TASK_INIT_DISPATCHER" kiro-notion
  assert_success
  assert [ -f "$MAIN_REPO/.kiro/steering/notion-workflow.md" ]
}

@test "delegates to claude-jira with no passthrough args" {
  run "$TASK_INIT_DISPATCHER" claude-jira
  assert_success
  assert [ -f "$MAIN_REPO/.claude/jira-workflow.md" ]
}

# ---------------------------------------------------------------------------
# --force passthrough
# ---------------------------------------------------------------------------

@test "--force before impl name is forwarded to the implementation" {
  run "$TASK_INIT_DISPATCHER" claude-notion
  assert_success
  run "$TASK_INIT_DISPATCHER" --force claude-notion
  assert_success
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
}

@test "--force after impl name is forwarded via PASSTHROUGH" {
  run "$TASK_INIT_DISPATCHER" claude-notion
  assert_success
  run "$TASK_INIT_DISPATCHER" claude-notion --force
  assert_success
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
}

# ---------------------------------------------------------------------------
# Multi-arg PASSTHROUGH (jira-specific flags)
# ---------------------------------------------------------------------------

@test "passes --site --key --board through to claude-jira implementation" {
  run "$TASK_INIT_DISPATCHER" claude-jira \
    --site "https://acme.atlassian.net" --key PROJ --board "My Board"
  assert_success
  run grep "https://acme.atlassian.net" "$MAIN_REPO/.claude/jira-workflow.md"
  assert_success
  run grep "PROJ-" "$MAIN_REPO/.claude/jira-workflow.md"
  assert_success
  run grep "My Board" "$MAIN_REPO/.claude/jira-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

@test "interactive menu choice 3 delegates to claude-notion" {
  run bash -c "echo 3 | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
}

@test "interactive menu choice 1 delegates to claude-jira" {
  run bash -c "echo 1 | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.claude/jira-workflow.md" ]
}

@test "interactive menu choice 2 delegates to kiro-notion" {
  run bash -c "echo 2 | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.kiro/steering/notion-workflow.md" ]
}

@test "interactive menu invalid choice exits non-zero" {
  run bash -c "echo 9 | \"$TASK_INIT_DISPATCHER\""
  assert_failure
  assert_output --partial "Invalid choice"
}

# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

@test "fails with error when not in a git repo" {
  cd /tmp
  run "$TASK_INIT_DISPATCHER" claude-notion
  assert_failure
  assert_output --partial "not in a git repo"
}
