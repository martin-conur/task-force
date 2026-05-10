#!/usr/bin/env bats
# Tests for kiro-notion/bin/task-init

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

@test "copies template to .kiro/steering/notion-workflow.md" {
  run "$KIRO_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
}

@test "copied file contains placeholder text" {
  run "$KIRO_TASK_INIT"
  assert_success
  run grep -F "YOUR_TASKS_DATA_SOURCE_ID" "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Post-install guidance
# ---------------------------------------------------------------------------

@test "prints Notion ID discovery guide after setup" {
  run "$KIRO_TASK_INIT"
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert_output --partial "kiro"
}

# ---------------------------------------------------------------------------
# --help-ids flag
# ---------------------------------------------------------------------------

@test "--help-ids prints guide without running setup" {
  run "$KIRO_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert [ ! -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
}

@test "--help-ids works outside a git repo" {
  cd /tmp
  run "$KIRO_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
}

# ---------------------------------------------------------------------------
# --force and overwrite guard
# ---------------------------------------------------------------------------

@test "fails if .kiro/steering/notion-workflow.md already exists (no --force)" {
  run "$KIRO_TASK_INIT"
  assert_success
  run "$KIRO_TASK_INIT"
  assert_failure
  assert_output --partial "already exists"
}

@test "--force overwrites existing notion-workflow.md" {
  run "$KIRO_TASK_INIT"
  assert_success
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$KIRO_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
