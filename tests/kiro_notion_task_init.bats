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
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker symlinks into .kiro/agents/" {
  run "$KIRO_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents link into kiro-notion/agents/" {
  run "$KIRO_TASK_INIT"
  assert_success
  run readlink "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output --partial "kiro-notion/agents/pm.json"
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run readlink "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output --partial "kiro-notion/agents/pm.json"
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT"
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cat "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output "stale content"
  assert [ -L "$TARGET_DIR/.kiro/agents/planner.json" ]
  assert [ -L "$TARGET_DIR/.kiro/agents/worker.json" ]
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
