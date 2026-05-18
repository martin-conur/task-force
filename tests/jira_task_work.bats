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

@test "branch collision: warns and reuses when task branch already exists" {
  git -C "$MAIN_REPO" branch task/stale-feature
  echo "newer" > "$MAIN_REPO/newfile.txt"
  git -C "$MAIN_REPO" add newfile.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"

  run "$JIRA_TASK_WORK" stale-feature
  assert_success
  assert_output --partial "Branch task/stale-feature already exists. Reusing it."
  assert_output --partial "Current HEAD on main"
  assert_output --partial "Divergence:"
  assert_output --partial "0 ahead, 1 behind main"

  local wt_head main_head
  wt_head=$(git -C "$WORKTREE_BASE/stale-feature" rev-parse HEAD)
  main_head=$(git -C "$MAIN_REPO" rev-parse main)
  [[ "$wt_head" != "$main_head" ]]
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
# Permission-mode flags: --plan / --auto (and their mutex)
# ---------------------------------------------------------------------------

@test "--plan: launches claude in plan mode running /planner" {
  run "$JIRA_TASK_WORK" --plan my-task
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--plan with Jira key: passes key to /planner" {
  run "$JIRA_TASK_WORK" --plan PROJ-10
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner PROJ-10"'
}

@test "-p alias works the same as --plan" {
  run "$JIRA_TASK_WORK" -p my-task
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--auto: launches claude in auto mode running /worker" {
  run "$JIRA_TASK_WORK" --auto my-task
  assert_success
  assert_stub_called zellij 'claude --permission-mode auto "/worker"'
}

@test "--auto with Jira key: keeps /worker Implement Jira issue prefix" {
  run "$JIRA_TASK_WORK" --auto PROJ-10
  assert_success
  assert_stub_called zellij 'claude --permission-mode auto "/worker Implement Jira issue: PROJ-10"'
}

@test "--auto --plan: errors out (mutually exclusive)" {
  run "$JIRA_TASK_WORK" --auto --plan my-task
  assert_failure
  assert_output --partial "--auto and --plan are mutually exclusive"
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
