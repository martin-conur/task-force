#!/usr/bin/env bats
# Tests for claude-gh/bin/task-init

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

@test "copies template to .claude/gh-workflow.md" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.claude/gh-workflow.md" ]
}

@test "copied file contains placeholder text" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run grep -F "YOUR_PROJECT_NUMBER" "$TARGET_DIR/.claude/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# CLAUDE.md integration
# ---------------------------------------------------------------------------

@test "creates CLAUDE.md with @.claude/gh-workflow.md when none exists" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/CLAUDE.md" ]
  run grep -F "@.claude/gh-workflow.md" "$TARGET_DIR/CLAUDE.md"
  assert_success
}

@test "appends to existing CLAUDE.md" {
  echo "# Existing content" > "$TARGET_DIR/CLAUDE.md"
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/CLAUDE.md"
  assert_output --partial "# Existing content"
  assert_output --partial "@.claude/gh-workflow.md"
}

@test "does not duplicate the import line in CLAUDE.md" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  local count
  count=$(grep -c "@.claude/gh-workflow.md" "$TARGET_DIR/CLAUDE.md" || true)
  assert_equal "$count" "1"
}

# ---------------------------------------------------------------------------
# --force and overwrite guard
# ---------------------------------------------------------------------------

@test "fails if .claude/gh-workflow.md already exists (no --force)" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run "$CLAUDE_GH_TASK_INIT"
  assert_failure
  assert_output --partial "already exists"
}

@test "--force overwrites existing gh-workflow.md" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  assert [ -f "$TARGET_DIR/.claude/gh-workflow.md" ]
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_GH_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
