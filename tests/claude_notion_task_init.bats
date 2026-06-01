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
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  echo "USER EDIT" >> "$TARGET_DIR/.claude/notion-workflow.md"
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.claude/notion-workflow.md"
  assert_output --partial "USER EDIT"
}

@test "--force overwrites existing notion-workflow.md" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  echo "USER EDIT" >> "$TARGET_DIR/.claude/notion-workflow.md"
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  run cat "$TARGET_DIR/.claude/notion-workflow.md"
  refute_output --partial "USER EDIT"
}

@test "--force + --restore is rejected" {
  run "$CLAUDE_NOTION_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted slash command without touching workflow" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  cp "$TARGET_DIR/.claude/notion-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_NOTION_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.claude/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs slash commands without writing workflow doc" {
  run "$CLAUDE_NOTION_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.claude/notion-workflow.md" ]
  for cmd in pm planner worker; do
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "--workflow installs workflow doc without writing slash commands" {
  run "$CLAUDE_NOTION_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.claude/notion-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.claude/commands" ]
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
# Project-level slash commands
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .claude/commands/ as real files" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  for cmd in pm planner worker; do
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
    assert [ ! -L "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "project-level slash commands are copies of claude-notion/commands/" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/claude-notion/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force overwrites pre-existing project-level slash command" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-notion/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  ln -sf /nonexistent/path "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-notion/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "without --force, pre-existing project-level slash command is preserved" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale content" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_NOTION_TASK_INIT"
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
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}

# ---------------------------------------------------------------------------
# Notion read-only allow-list seeding into .claude/settings.json
# ---------------------------------------------------------------------------

@test "seeds mcp__notion__* read tools into permissions.allow" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run jq -r '.permissions.allow[]' "$TARGET_DIR/.claude/settings.json"
  assert_output --partial "mcp__notion__notion-search"
  assert_output --partial "mcp__notion__notion-fetch"
  assert_output --partial "mcp__notion__notion-query-data-sources"
  assert_output --partial "Bash(radio *)"
  # Shared read-only tool/shell allow-list (#141).
  assert_output --partial "Read"
  assert_output --partial "Grep"
  assert_output --partial "Glob"
  assert_output --partial "Bash(find *)"
  assert_output --partial "Bash(ls *)"
  assert_output --partial "Bash(cat *)"
  assert_output --partial "Bash(rg *)"
  # Writes must NOT be auto-allowed.
  refute_output --partial "notion-create-pages"
  refute_output --partial "notion-update-page"
  refute_output --partial "notion-move-pages"
  refute_output --partial "notion-create-comment"
}

@test "idempotent: re-run does not duplicate Notion allow-list entries" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  local before
  before=$(jq -r '.permissions.allow | length' "$TARGET_DIR/.claude/settings.json")
  run "$CLAUDE_NOTION_TASK_INIT" --force
  assert_success
  local after
  after=$(jq -r '.permissions.allow | length' "$TARGET_DIR/.claude/settings.json")
  assert_equal "$before" "$after"
}

@test "SessionStart hook command embeds the loadout name (env-overridable)" {
  run "$CLAUDE_NOTION_TASK_INIT"
  assert_success
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  # The hook uses ${TASK_FORCE_LOADOUT:-claude-notion} so per-role launchers like
  # task-reviewer can override LOADOUT= without re-running task-init.
  assert_output --partial "--loadout \${TASK_FORCE_LOADOUT:-claude-notion}"
  assert_output --partial "--agent claude"
}
