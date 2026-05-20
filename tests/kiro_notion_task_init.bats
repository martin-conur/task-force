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
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$KIRO_TASK_INIT"
  assert_success
  echo "USER EDIT" >> "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  run "$KIRO_TASK_INIT"
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_output --partial "USER EDIT"
}

@test "--force overwrites existing notion-workflow.md" {
  run "$KIRO_TASK_INIT"
  assert_success
  echo "USER EDIT" >> "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  run "$KIRO_TASK_INIT" --force
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  refute_output --partial "USER EDIT"
}

@test "--force + --restore is rejected" {
  run "$KIRO_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted agent without touching workflow" {
  run "$KIRO_TASK_INIT"
  assert_success
  cp "$TARGET_DIR/.kiro/steering/notion-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs agents without writing workflow doc" {
  run "$KIRO_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "--workflow installs workflow doc without writing agents" {
  run "$KIRO_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.kiro/agents" ]
}

# ---------------------------------------------------------------------------
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .kiro/agents/ as real files" {
  run "$KIRO_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ ! -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents are copies of kiro-notion/agents/" {
  run "$KIRO_TASK_INIT"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  ln -sf /nonexistent/path "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output "stale content"
  assert [ -f "$TARGET_DIR/.kiro/agents/planner.json" ]
  assert [ -f "$TARGET_DIR/.kiro/agents/worker.json" ]
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
