#!/usr/bin/env bats
# Tests for kiro-gh/bin/task-init

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

@test "copies template to .kiro/steering/gh-workflow.md" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
}

@test "copied file contains placeholder text when no values provided" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run grep -F "{PROJECT}" "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Flag-based substitution
# ---------------------------------------------------------------------------

@test "all flags: substitutes {OWNER}, {REPO}, {PROJECT}" {
  run "$KIRO_GH_TASK_INIT" --owner myorg --repo myrepo --project 42
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "myrepo"
  assert_output --partial "42"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

@test "--owner only: {REPO} and {PROJECT} remain as placeholders" {
  run "$KIRO_GH_TASK_INIT" --owner myorg
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

@test "no flags (non-interactive stdin): all {placeholders} preserved" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

# ---------------------------------------------------------------------------
# Auto-detection from git remote
# ---------------------------------------------------------------------------

@test "auto-detects owner and repo from HTTPS remote" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "auto-detects owner and repo from SSH remote" {
  git -C "$TARGET_DIR" remote add origin "git@github.com:acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "--owner flag overrides auto-detected owner" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --owner override-org --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "override-org"
  refute_output --partial "acme"
  refute_output --partial "{OWNER}"
}

@test "no remote: {OWNER} and {REPO} stay as placeholders" {
  run "$KIRO_GH_TASK_INIT" --project 5
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
}

# ---------------------------------------------------------------------------
# --force and overwrite guard
# ---------------------------------------------------------------------------

@test "fails if .kiro/steering/gh-workflow.md already exists (no --force)" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run "$KIRO_GH_TASK_INIT"
  assert_failure
  assert_output --partial "already exists"
}

@test "--force overwrites existing gh-workflow.md" {
  run "$KIRO_GH_TASK_INIT" --owner old
  assert_success
  run "$KIRO_GH_TASK_INIT" --owner new --force
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "new"
  refute_output --partial "**Owner**: \`old\`"
}

# ---------------------------------------------------------------------------
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker symlinks into .kiro/agents/" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents link into kiro-gh/agents/" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run readlink "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output --partial "kiro-gh/agents/pm.json"
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  assert [ -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run readlink "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output --partial "kiro-gh/agents/pm.json"
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT"
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
  run "$KIRO_GH_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
