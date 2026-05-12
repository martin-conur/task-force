#!/usr/bin/env bats
# Tests for claude-jira/bin/task-work

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Input parsing
# ---------------------------------------------------------------------------

@test "bare Jira key: lowercase slug, JIRA_REF set" {
  run "$JIRA_TASK_WORK" PROJ-123
  assert_success
  assert [ -d "$WORKTREE_BASE/proj-123" ]
  source "$WORKTREE_BASE/.proj-123.info"
  assert_equal "$JIRA_REF" "PROJ-123"
}

@test "Jira URL: extracts key, sets JIRA_REF to full URL" {
  local url="https://acme.atlassian.net/browse/PROJ-456"
  run "$JIRA_TASK_WORK" "$url"
  assert_success
  assert [ -d "$WORKTREE_BASE/proj-456" ]
  source "$WORKTREE_BASE/.proj-456.info"
  assert_equal "$JIRA_REF" "$url"
}

@test "free-form slug: no JIRA_REF" {
  run "$JIRA_TASK_WORK" add-store-filtering
  assert_success
  assert [ -d "$WORKTREE_BASE/add-store-filtering" ]
  source "$WORKTREE_BASE/.add-store-filtering.info"
  assert_equal "${JIRA_REF:-}" ""
}

@test "slug truncated to 50 chars" {
  local long_input
  long_input=$(python3 -c "print('A' * 60 + '-1')")  # long Jira-like key
  run "$JIRA_TASK_WORK" "$long_input"
  # Should not error — just truncate
  assert [ "$(ls "$WORKTREE_BASE" | head -1 | wc -c)" -le 51 ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  run "$JIRA_TASK_WORK" PROJ-10
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/proj-10")
  assert [ -n "$branches" ]
}

@test "parallel session: appends hash when worktree exists" {
  run "$JIRA_TASK_WORK" PROJ-10
  assert_success
  run "$JIRA_TASK_WORK" PROJ-10
  assert_success
  assert_output --partial "parallel session"
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^proj-10'"
  assert_output "2"
}

# ---------------------------------------------------------------------------
# .info file
# ---------------------------------------------------------------------------

@test "writes .info with BASE_BRANCH=current branch" {
  run "$JIRA_TASK_WORK" PROJ-10
  assert_success
  source "$WORKTREE_BASE/.proj-10.info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag stored in .info" {
  run "$JIRA_TASK_WORK" --base develop PROJ-10
  assert_success
  source "$WORKTREE_BASE/.proj-10.info"
  assert_equal "$BASE_BRANCH" "develop"
}

# ---------------------------------------------------------------------------
# Zellij + claude invocation
# ---------------------------------------------------------------------------

@test "injects claude /worker command with Jira ref" {
  run "$JIRA_TASK_WORK" PROJ-10
  assert_success
  assert_stub_called zellij "/worker Implement Jira issue: PROJ-10"
}

@test "injects claude /worker without ref for free-form slugs" {
  run "$JIRA_TASK_WORK" my-task
  assert_success
  # Bare `claude "/worker"` (no Jira ref)
  assert_stub_called zellij 'claude "/worker"'
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$JIRA_TASK_WORK" PROJ-1
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "--base requires a value" {
  run "$JIRA_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}
