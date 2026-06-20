#!/usr/bin/env bats
# Tests for claude-notion/bin/task-work

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
  run "$CLAUDE_NOTION_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # "abcde" x20 = 100 chars
  run "$CLAUDE_NOTION_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

@test "notion URL with title: derives slug from title segment" {
  run "$CLAUDE_NOTION_TASK_WORK" "https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "notion URL bare hex: uses first 8 chars" {
  run "$CLAUDE_NOTION_TASK_WORK" "https://www.notion.so/abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/abc123de" ]
}

@test "explicit slug + URL: slug takes precedence over derived" {
  run "$CLAUDE_NOTION_TASK_WORK" "my-explicit-slug" "https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-explicit-slug" ]
}

# Regression (#158): Notion serves workspace/page links — and the Notion MCP
# fetch/search tools return them — as app.notion.com URLs. is_notion_url() must
# recognize these or the URL is silently dropped (slug-only fallthrough).
@test "app.notion.com URL: single arg derives slug from /p/<32hex> tail" {
  run "$CLAUDE_NOTION_TASK_WORK" "https://app.notion.com/p/384d9a72260f81f5b3c1c639a1f78d1f"
  assert_success
  assert [ -d "$WORKTREE_BASE/384d9a72" ]
}

@test "app.notion.com URL: explicit slug + URL records NOTION_URL" {
  local url="https://app.notion.com/p/384d9a72260f81f5b3c1c639a1f78d1f"
  run "$CLAUDE_NOTION_TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$NOTION_URL" "$url"
}

@test "app.notion.com URL: claude command includes task URL" {
  local url="https://app.notion.com/p/384d9a72260f81f5b3c1c639a1f78d1f"
  run "$CLAUDE_NOTION_TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "Implement task: $url"
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/my-feature")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  assert_output --partial "parallel session"
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^my-feature'"
  assert_output "2"
}

@test "branch collision: warns and reuses when task branch already exists" {
  git -C "$MAIN_REPO" branch task/stale-feature
  echo "newer" > "$MAIN_REPO/newfile.txt"
  git -C "$MAIN_REPO" add newfile.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"

  run "$CLAUDE_NOTION_TASK_WORK" stale-feature
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

@test "writes .info file with BASE_BRANCH=current branch" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  local info="$WORKTREE_BASE/.my-feature.info"
  assert [ -f "$info" ]
  source "$info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$CLAUDE_NOTION_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

@test ".info records NOTION_URL when URL is provided" {
  local url="https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  run "$CLAUDE_NOTION_TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$NOTION_URL" "$url"
}

@test ".info NOTION_URL is empty for free-form slugs" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${NOTION_URL:-}" ""
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "new-tab --name my-feature"
}

@test "--no-launch: opens tab but does not inject claude command" {
  run "$CLAUDE_NOTION_TASK_WORK" --no-launch my-feature
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude command includes task URL when provided" {
  local url="https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"
  run "$CLAUDE_NOTION_TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "Implement task: $url"
}

@test "claude command uses /worker for free-form slugs" {
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_success
  # Bare `claude "/worker"` (no URL suffix)
  assert_stub_called zellij 'claude "/worker"'
}

# ---------------------------------------------------------------------------
# Permission-mode flags: --plan / --auto (and their mutex)
# ---------------------------------------------------------------------------

@test "--plan: launches claude in plan mode running /planner" {
  run "$CLAUDE_NOTION_TASK_WORK" --plan my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--plan with URL: passes URL to /planner" {
  local url="https://www.notion.so/My-Task-abc123def456abc123def456abc123de"
  run "$CLAUDE_NOTION_TASK_WORK" --plan my-feature "$url"
  assert_success
  assert_stub_called zellij "claude --permission-mode plan \"/planner $url\""
}

@test "-p alias works the same as --plan" {
  run "$CLAUDE_NOTION_TASK_WORK" -p my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--auto: launches claude in auto mode running /worker" {
  run "$CLAUDE_NOTION_TASK_WORK" --auto my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode auto "/worker"'
}

@test "--auto with URL: keeps /worker Implement task prefix" {
  local url="https://www.notion.so/My-Task-abc123def456abc123def456abc123de"
  run "$CLAUDE_NOTION_TASK_WORK" --auto my-feature "$url"
  assert_success
  assert_stub_called zellij "claude --permission-mode auto \"/worker Implement task: $url\""
}

@test "--auto --plan: errors out (mutually exclusive)" {
  run "$CLAUDE_NOTION_TASK_WORK" --auto --plan my-feature
  assert_failure
  assert_output --partial "--auto and --plan are mutually exclusive"
}

@test "--no-launch with --plan: opens tab without invoking claude (mode flag is a no-op)" {
  run "$CLAUDE_NOTION_TASK_WORK" --no-launch --plan my-feature
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_NOTION_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --base missing its value" {
  run "$CLAUDE_NOTION_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}

@test "fails on unknown flag" {
  run "$CLAUDE_NOTION_TASK_WORK" --unknown-flag
  assert_failure
}
