#!/usr/bin/env bats
# Tests for kiro-notion/bin/task-work

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
  run "$KIRO_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # "abcde" x20 = 100 chars
  run "$KIRO_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

@test "notion URL with title: derives slug from title segment" {
  run "$KIRO_TASK_WORK" "https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "notion URL bare hex: uses first 8 chars" {
  run "$KIRO_TASK_WORK" "https://www.notion.so/abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/abc123de" ]
}

@test "explicit slug + URL: slug takes precedence over derived" {
  run "$KIRO_TASK_WORK" "my-explicit-slug" "https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-explicit-slug" ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/my-feature")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  assert_output --partial "parallel session"
  # Hash-suffixed sibling directory must exist alongside the original
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^my-feature'"
  assert_output "2"
}

@test "branch collision: warns and reuses when task branch already exists" {
  git -C "$MAIN_REPO" branch task/stale-feature
  echo "newer" > "$MAIN_REPO/newfile.txt"
  git -C "$MAIN_REPO" add newfile.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"

  run "$KIRO_TASK_WORK" stale-feature
  assert_success
  assert_output --partial "Branch task/stale-feature already exists. Reusing it."
  assert_output --partial "Current HEAD on main"

  local wt_head main_head
  wt_head=$(git -C "$WORKTREE_BASE/stale-feature" rev-parse HEAD)
  main_head=$(git -C "$MAIN_REPO" rev-parse main)
  [[ "$wt_head" != "$main_head" ]]
}

# ---------------------------------------------------------------------------
# .info file
# ---------------------------------------------------------------------------

@test "writes .info file with BASE_BRANCH=current branch" {
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  local info="$WORKTREE_BASE/.my-feature.info"
  assert [ -f "$info" ]
  source "$info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$KIRO_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

@test ".info records NOTION_URL when URL is provided" {
  local url="https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  run "$KIRO_TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$NOTION_URL" "$url"
}

@test ".info NOTION_URL is empty for free-form slugs" {
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${NOTION_URL:-}" ""
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  run "$KIRO_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "new-tab --name my-feature"
}

@test "--no-launch: opens tab but does not inject kiro command" {
  run "$KIRO_TASK_WORK" --no-launch my-feature
  assert_success
  assert_output --partial "kiro NOT launched"
  # zellij.calls must not mention kiro-cli at all
  run grep -F "kiro-cli" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro command includes --model when -m is set" {
  run "$KIRO_TASK_WORK" -m claude-opus-4.6 my-feature
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker --model claude-opus-4.6"
}

@test "kiro command includes --trust-all-tools when -a is set" {
  run "$KIRO_TASK_WORK" -a my-feature
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}

@test "kiro command includes task URL when provided" {
  local url="https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  run "$KIRO_TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "Implement task: $url"
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$KIRO_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --model missing its value" {
  run "$KIRO_TASK_WORK" --model
  assert_failure
  assert_output --partial "--model requires a value"
}

@test "fails on unknown flag" {
  run "$KIRO_TASK_WORK" --unknown-flag
  assert_failure
}
