#!/usr/bin/env bats
# Tests for claude-notion/bin/task-init

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

TARGET_DIR=""

setup() {
  setup_repo
  TARGET_DIR="$MAIN_REPO"
  cd "$TARGET_DIR"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# File creation
# ---------------------------------------------------------------------------

@test "copies template to .claude/notion-workflow.md" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.claude/notion-workflow.md" ]
}

@test "copied file contains placeholder text" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run grep -F "YOUR_TASKS_DATA_SOURCE_ID" "$TARGET_DIR/.claude/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# CLAUDE.md integration
# ---------------------------------------------------------------------------

@test "creates CLAUDE.md with @.claude/notion-workflow.md when none exists" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/CLAUDE.md" ]
  run grep -F "@.claude/notion-workflow.md" "$TARGET_DIR/CLAUDE.md"
  assert_success
}

@test "appends to existing CLAUDE.md" {
  echo "# Existing content" > "$TARGET_DIR/CLAUDE.md"
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/CLAUDE.md"
  assert_output --partial "# Existing content"
  assert_output --partial "@.claude/notion-workflow.md"
}

@test "does not duplicate the import line in CLAUDE.md" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  local count
  count=$(grep -c "@.claude/notion-workflow.md" "$TARGET_DIR/CLAUDE.md" || true)
  assert_equal "$count" "1"
}

# ---------------------------------------------------------------------------
# --force and overwrite guard
# ---------------------------------------------------------------------------

@test "fails if .claude/notion-workflow.md already exists (no --force)" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_failure
  assert_output --partial "already exists"
}

@test "--force overwrites existing notion-workflow.md" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  assert [ -f "$TARGET_DIR/.claude/notion-workflow.md" ]
}

# ---------------------------------------------------------------------------
# Post-install guidance
# ---------------------------------------------------------------------------

@test "prints Notion ID discovery guide after setup" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert_output --partial "claude"
}

# ---------------------------------------------------------------------------
# --help-ids flag
# ---------------------------------------------------------------------------

@test "--help-ids prints guide without running setup" {
  run "$CLAUDE_NOTION_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert [ ! -f "$TARGET_DIR/.claude/notion-workflow.md" ]
}

@test "--help-ids works outside a git repo" {
  cd /tmp
  run "$CLAUDE_NOTION_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
