#!/usr/bin/env bats
# Tests for claude-jira/bin/task-init

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
# Placeholder substitution via flags
# ---------------------------------------------------------------------------

@test "all flags: substitutes {SITE}, {KEY}, {BOARD}" {
  run "$JIRA_TASK_INIT" --site "https://acme.atlassian.net" --key ML --board "My Board"
  assert_success
  run cat "$TARGET_DIR/.claude/jira-workflow.md"
  assert_output --partial "https://acme.atlassian.net"
  assert_output --partial "ML-123"
  assert_output --partial "My Board"
  refute_output --partial "{SITE}"
  refute_output --partial "{KEY}"
  refute_output --partial "{BOARD}"
}

@test "--site only: {KEY} and {BOARD} remain as placeholders" {
  run "$JIRA_TASK_INIT" --site "https://acme.atlassian.net"
  assert_success
  run cat "$TARGET_DIR/.claude/jira-workflow.md"
  assert_output --partial "https://acme.atlassian.net"
  assert_output --partial "{KEY}"
  assert_output --partial "{BOARD}"
}

@test "--key only: {SITE} and {BOARD} remain as placeholders" {
  run "$JIRA_TASK_INIT" --key MYPROJ
  assert_success
  run cat "$TARGET_DIR/.claude/jira-workflow.md"
  assert_output --partial "MYPROJ-123"
  assert_output --partial "{SITE}"
  assert_output --partial "{BOARD}"
}

@test "no flags (non-interactive stdin): all {placeholders} preserved" {
  # stdin is not a terminal here, so prompts are skipped and nothing is substituted
  run "$JIRA_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.claude/jira-workflow.md"
  assert_output --partial "{SITE}"
  assert_output --partial "{KEY}"
  assert_output --partial "{BOARD}"
}

# ---------------------------------------------------------------------------
# CLAUDE.md integration
# ---------------------------------------------------------------------------

@test "creates CLAUDE.md with @.claude/jira-workflow.md when none exists" {
  run "$JIRA_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/CLAUDE.md" ]
  run grep -F "@.claude/jira-workflow.md" "$TARGET_DIR/CLAUDE.md"
  assert_success
}

@test "appends to existing CLAUDE.md" {
  echo "# Existing content" > "$TARGET_DIR/CLAUDE.md"
  run "$JIRA_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/CLAUDE.md"
  assert_output --partial "# Existing content"
  assert_output --partial "@.claude/jira-workflow.md"
}

@test "does not duplicate the import line in CLAUDE.md" {
  run "$JIRA_TASK_INIT"
  assert_success
  run "$JIRA_TASK_INIT" --force
  assert_success
  local count
  count=$(grep -c "@.claude/jira-workflow.md" "$TARGET_DIR/CLAUDE.md" || true)
  assert_equal "$count" "1"
}

# ---------------------------------------------------------------------------
# --force and overwrite guard
# ---------------------------------------------------------------------------

@test "fails if .claude/jira-workflow.md already exists (no --force)" {
  run "$JIRA_TASK_INIT"
  assert_success
  run "$JIRA_TASK_INIT"
  assert_failure
  assert_output --partial "already exists"
}

@test "--force overwrites existing jira-workflow.md" {
  run "$JIRA_TASK_INIT" --key OLD
  assert_success
  run "$JIRA_TASK_INIT" --key NEW --force
  assert_success
  run cat "$TARGET_DIR/.claude/jira-workflow.md"
  assert_output --partial "NEW-123"
  refute_output --partial "OLD-123"
}

# ---------------------------------------------------------------------------
# Project-level slash commands
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .claude/commands/ as real files" {
  run "$JIRA_TASK_INIT"
  assert_success
  for cmd in pm planner worker; do
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
    assert [ ! -L "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "project-level slash commands are copies of claude-jira/commands/" {
  run "$JIRA_TASK_INIT"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/claude-jira/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force overwrites pre-existing project-level slash command" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$JIRA_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-jira/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  ln -sf /nonexistent/path "$TARGET_DIR/.claude/commands/pm.md"
  run "$JIRA_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-jira/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "without --force, pre-existing project-level slash command is preserved" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale content" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$JIRA_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.claude/commands/pm.md"
  assert_output "stale content"
  assert [ -f "$TARGET_DIR/.claude/commands/planner.md" ]
  assert [ -f "$TARGET_DIR/.claude/commands/worker.md" ]
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$JIRA_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
