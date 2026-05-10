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

@test "passes --owner --repo --project through to claude-gh implementation" {
  run "$TASK_INIT_DISPATCHER" claude-gh --owner myorg --repo myrepo --project 5
  assert_success
  run grep "myorg" "$MAIN_REPO/.claude/gh-workflow.md"
  assert_success
  run grep "myrepo" "$MAIN_REPO/.claude/gh-workflow.md"
  assert_success
}

@test "passes --owner --repo --project through to kiro-gh implementation" {
  run "$TASK_INIT_DISPATCHER" kiro-gh --owner myorg --repo myrepo --project 5
  assert_success
  run grep "myorg" "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  assert_success
  run grep "myrepo" "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# New implementations — delegation
# ---------------------------------------------------------------------------

@test "delegates to claude-gh with no passthrough args" {
  run "$TASK_INIT_DISPATCHER" claude-gh
  assert_success
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "delegates to kiro-gh with no passthrough args" {
  run "$TASK_INIT_DISPATCHER" kiro-gh
  assert_success
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

# ---------------------------------------------------------------------------
# Interactive menu (two-step: tool then board)
# ---------------------------------------------------------------------------

@test "interactive menu: Claude Code + Jira (1 then 1)" {
  run bash -c "printf '1\n1\n' | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.claude/jira-workflow.md" ]
}

@test "interactive menu: Claude Code + Notion (1 then 2)" {
  run bash -c "printf '1\n2\n' | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
}

@test "interactive menu: Claude Code + GitHub Projects (1 then 3)" {
  run bash -c "printf '1\n3\n' | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "interactive menu: Kiro + Notion (2 then 1)" {
  run bash -c "printf '2\n1\n' | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.kiro/steering/notion-workflow.md" ]
}

@test "interactive menu: Kiro + GitHub Projects (2 then 2)" {
  run bash -c "printf '2\n2\n' | \"$TASK_INIT_DISPATCHER\""
  assert_success
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "interactive menu invalid tool choice exits non-zero" {
  run bash -c "echo 9 | \"$TASK_INIT_DISPATCHER\""
  assert_failure
  assert_output --partial "Invalid choice"
}

@test "interactive menu invalid board choice exits non-zero" {
  run bash -c "printf '1\n9\n' | \"$TASK_INIT_DISPATCHER\""
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
