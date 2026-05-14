#!/usr/bin/env bats
# Tests for claude-gh/bin/task-work

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
# Slug derivation
# ---------------------------------------------------------------------------

@test "free-form slug: lowercase and sanitize" {
  run "$CLAUDE_GH_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # "abcde" x20 = 100 chars
  run "$CLAUDE_GH_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

@test "github issue URL: derives slug as issue-N" {
  run "$CLAUDE_GH_TASK_WORK" "https://github.com/owner/repo/issues/42"
  assert_success
  assert [ -d "$WORKTREE_BASE/issue-42" ]
}

@test "github issue URL with trailing params: still derives issue number" {
  run "$CLAUDE_GH_TASK_WORK" "https://github.com/owner/repo/issues/99?foo=bar"
  assert_success
  assert [ -d "$WORKTREE_BASE/issue-99" ]
}

@test "explicit slug + URL: slug takes precedence over derived" {
  run "$CLAUDE_GH_TASK_WORK" "my-explicit-slug" "https://github.com/owner/repo/issues/42"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-explicit-slug" ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/my-feature")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  assert_output --partial "parallel session"
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^my-feature'"
  assert_output "2"
}

# ---------------------------------------------------------------------------
# .info file
# ---------------------------------------------------------------------------

@test "writes .info file with BASE_BRANCH=current branch" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  local info="$WORKTREE_BASE/.my-feature.info"
  assert [ -f "$info" ]
  source "$info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$CLAUDE_GH_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

@test ".info records GH_URL when URL is provided" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$GH_URL" "$url"
}

@test ".info GH_URL is empty for free-form slugs" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${GH_URL:-}" ""
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "new-tab --name my-feature"
}

@test "--no-launch: opens tab but does not inject claude command" {
  run "$CLAUDE_GH_TASK_WORK" --no-launch my-feature
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude command includes task URL when provided" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "Implement task: $url"
}

@test "claude command uses /worker for free-form slugs" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  # Bare `claude "/worker"` (no URL suffix)
  assert_stub_called zellij 'claude "/worker"'
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --base missing its value" {
  run "$CLAUDE_GH_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}

@test "fails on unknown flag" {
  run "$CLAUDE_GH_TASK_WORK" --unknown-flag
  assert_failure
}
