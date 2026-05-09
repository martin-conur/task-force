#!/usr/bin/env bats
# Tests for task-done (both kiro-notion and claude-jira versions).
# The two scripts share identical logic except for Jira-key PR title casing,
# so most tests run against both.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SLUG="my-feature"

# Run a task-done script from inside the worktree, auto-confirming prompts.
# Usage: run_task_done <script> [extra args...]
run_task_done() {
  local script="$1"; shift
  # Pipe "y\n" to confirm the "Remove worktree?" prompt
  run bash -c "echo y | $script $*"
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
# Guard: must be in a worktree
# ---------------------------------------------------------------------------

@test "kiro: fails when run from main repo" {
  cd "$MAIN_REPO"
  run "$KIRO_TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

@test "jira: fails when run from main repo" {
  cd "$MAIN_REPO"
  run "$JIRA_TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------

@test "kiro: shows branch and base branch" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "jira: shows branch and base branch" {
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "kiro: reads custom BASE_BRANCH from .info file" {
  # Overwrite the info file with a different base
  printf 'BASE_BRANCH=develop\nSLUG=%s\nNOTION_URL=\n' "$SLUG" \
    > "$WORKTREE_BASE/.$SLUG.info"
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Base:     develop"
}

@test "kiro: shows commit count ahead of base" {
  # Make a commit in the worktree
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Commits ahead of main: 1"
}

@test "kiro: shows diff shortstat when there are commits" {
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Changes:"
}

# ---------------------------------------------------------------------------
# PR section
# ---------------------------------------------------------------------------

@test "kiro: shows gh pr create with correct --base when no PR exists" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "gh pr create --base main --head task/$SLUG"
}

@test "kiro: shows existing PR URL instead of create command" {
  export GH_STUB_PR_URL="https://github.com/org/repo/pull/42"
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "PR: https://github.com/org/repo/pull/42"
  refute_output --partial "gh pr create"
}

@test "jira: PR title uppercases Jira key slug" {
  setup_worktree "proj-99"
  cd "$WORKTREE_BASE/proj-99"
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial '"PROJ-99"'
}

@test "jira: PR title uses raw slug for non-Jira branches" {
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial '"my-feature"'
}

# ---------------------------------------------------------------------------
# --remove-worktree flag
# ---------------------------------------------------------------------------

@test "kiro: --remove-worktree skips PR section" {
  run_task_done "$KIRO_TASK_DONE" --remove-worktree
  refute_output --partial "gh pr create"
  refute_output --partial "To create a PR"
}

@test "jira: --remove-worktree skips PR section" {
  run_task_done "$JIRA_TASK_DONE" --remove-worktree
  refute_output --partial "gh pr create"
}

@test "kiro: --remove-worktree --force skips all prompts" {
  run "$KIRO_TASK_DONE" --remove-worktree --force
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

@test "kiro: removes worktree directory" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "kiro: deletes .info file after removal" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert [ ! -f "$WORKTREE_BASE/.$SLUG.info" ]
}

@test "kiro: closes zellij tab" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert_stub_called zellij "close-tab"
}

@test "kiro: no prompt when --force is set" {
  # With --force, should not block waiting for stdin
  run "$KIRO_TASK_DONE" --force
  assert_success
}

# ---------------------------------------------------------------------------
# Uncommitted changes warning
# ---------------------------------------------------------------------------

@test "kiro: warns about uncommitted changes" {
  echo "dirty" > "$WORKTREE_BASE/$SLUG/dirty.txt"
  git -C "$WORKTREE_BASE/$SLUG" add dirty.txt
  # Don't commit — leave staged

  run bash -c "echo y | $KIRO_TASK_DONE --force"
  assert_output --partial "Uncommitted changes"
}
