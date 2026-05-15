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

@test "copied file contains placeholder text when no values provided" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run grep -F "{PROJECT}" "$TARGET_DIR/.claude/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Flag-based substitution
# ---------------------------------------------------------------------------

@test "all flags: substitutes {OWNER}, {REPO}, {PROJECT}" {
  run "$CLAUDE_GH_TASK_INIT" --owner myorg --repo myrepo --project 42
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "myrepo"
  assert_output --partial "42"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

@test "--owner only: {REPO} and {PROJECT} remain as placeholders" {
  run "$CLAUDE_GH_TASK_INIT" --owner myorg
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

@test "--repo only: {OWNER} and {PROJECT} remain as placeholders" {
  run "$CLAUDE_GH_TASK_INIT" --repo myrepo
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "myrepo"
  assert_output --partial "{OWNER}"
  assert_output --partial "{PROJECT}"
}

@test "--project only: {OWNER} and {REPO} remain as placeholders" {
  run "$CLAUDE_GH_TASK_INIT" --project 7
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

@test "no flags (non-interactive stdin): all {placeholders} preserved" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

# ---------------------------------------------------------------------------
# Auto-detection from git remote
# ---------------------------------------------------------------------------

@test "auto-detects owner and repo from HTTPS remote" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$CLAUDE_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "auto-detects owner and repo from SSH remote" {
  git -C "$TARGET_DIR" remote add origin "git@github.com:acme/widget.git"
  run "$CLAUDE_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "--owner flag overrides auto-detected owner" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$CLAUDE_GH_TASK_INIT" --owner override-org --project 1
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "override-org"
  refute_output --partial "acme"
  refute_output --partial "{OWNER}"
}

@test "no remote: {OWNER} and {REPO} stay as placeholders" {
  run "$CLAUDE_GH_TASK_INIT" --project 5
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
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
  run "$CLAUDE_GH_TASK_INIT" --owner old
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --owner new --force
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "new"
  refute_output --partial "**Owner**: \`old\`"
}

# ---------------------------------------------------------------------------
# Project-level slash commands
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker symlinks into .claude/commands/" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  for cmd in pm planner worker; do
    assert [ -L "$TARGET_DIR/.claude/commands/$cmd.md" ]
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "project-level slash commands link into claude-gh/commands/" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run readlink "$TARGET_DIR/.claude/commands/pm.md"
  assert_output --partial "claude-gh/commands/pm.md"
}

@test "--force overwrites pre-existing project-level slash command" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  assert [ -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run readlink "$TARGET_DIR/.claude/commands/pm.md"
  assert_output --partial "claude-gh/commands/pm.md"
}

@test "without --force, pre-existing project-level slash command is preserved" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale content" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cat "$TARGET_DIR/.claude/commands/pm.md"
  assert_output "stale content"
  assert [ -L "$TARGET_DIR/.claude/commands/planner.md" ]
  assert [ -L "$TARGET_DIR/.claude/commands/worker.md" ]
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
