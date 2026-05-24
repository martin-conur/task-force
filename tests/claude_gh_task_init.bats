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
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$CLAUDE_GH_TASK_INIT" --owner old
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --owner ignored
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "old"
  refute_output --partial "ignored"
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

@test "--force + --restore is rejected" {
  run "$CLAUDE_GH_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted slash command without touching workflow" {
  run "$CLAUDE_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  # Snapshot workflow doc, delete one command.
  cp "$TARGET_DIR/.claude/gh-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.claude/gh-workflow.md"
  assert_success
}

@test "--restore leaves existing slash commands alone" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "custom content" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --restore
  assert_success
  run cat "$TARGET_DIR/.claude/commands/pm.md"
  assert_output "custom content"
  # And fills in the missing ones
  assert [ -f "$TARGET_DIR/.claude/commands/planner.md" ]
  assert [ -f "$TARGET_DIR/.claude/commands/worker.md" ]
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs slash commands without writing workflow doc" {
  run "$CLAUDE_GH_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.claude/gh-workflow.md" ]
  for cmd in pm planner worker; do
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "--workflow installs workflow doc without writing slash commands" {
  run "$CLAUDE_GH_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.claude/gh-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.claude/commands" ]
}

@test "--commands --force overwrites pre-existing slash commands, leaves workflow alone" {
  run "$CLAUDE_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  cp "$TARGET_DIR/.claude/gh-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  echo "stale pm" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --commands --force
  assert_success
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.claude/gh-workflow.md"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/claude-gh/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Placeholder preservation
# ---------------------------------------------------------------------------

@test "--force preserves filled-in {OWNER}/{REPO}/{PROJECT} when no flags passed" {
  run "$CLAUDE_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  # Re-run with --force and no flag values — placeholders should be carried forward.
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  assert_output --partial "**Project number**: \`7\`"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

@test "this-run flag value beats preserved value" {
  run "$CLAUDE_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --owner other --force
  assert_success
  run cat "$TARGET_DIR/.claude/gh-workflow.md"
  assert_output --partial "other"
  refute_output --partial "**Owner**: \`acme\`"
  # REPO and PROJECT still preserved
  assert_output --partial "widget"
  assert_output --partial "**Project number**: \`7\`"
}

# ---------------------------------------------------------------------------
# Project-level slash commands
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .claude/commands/ as real files" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  for cmd in pm planner worker; do
    assert [ -f "$TARGET_DIR/.claude/commands/$cmd.md" ]
    assert [ ! -L "$TARGET_DIR/.claude/commands/$cmd.md" ]
  done
}

@test "project-level slash commands are copies of claude-gh/commands/" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/claude-gh/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force overwrites pre-existing project-level slash command" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-gh/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  ln -sf /nonexistent/path "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.claude/commands/pm.md" ]
  run cmp -s "$REPO_ROOT_REAL/claude-gh/commands/pm.md" "$TARGET_DIR/.claude/commands/pm.md"
  assert_success
}

@test "without --force, pre-existing project-level slash command is preserved" {
  mkdir -p "$TARGET_DIR/.claude/commands"
  echo "stale content" > "$TARGET_DIR/.claude/commands/pm.md"
  run "$CLAUDE_GH_TASK_INIT"
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
  run "$CLAUDE_GH_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}

# ---------------------------------------------------------------------------
# radio hooks: settings.json merge
# ---------------------------------------------------------------------------

@test "writes 4 radio hook entries into .claude/settings.json" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.claude/settings.json" ]
  for event in SessionStart UserPromptSubmit Stop SessionEnd; do
    run jq -r ".hooks.$event[0].hooks[0].command" "$TARGET_DIR/.claude/settings.json"
    assert_output --partial "radio"
  done
}

@test "SessionEnd hook calls 'radio unregister' (#94)" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run jq -r '.hooks.SessionEnd[0].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  assert_output "radio unregister"
}

@test "SessionStart hook command embeds the loadout name" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  assert_output --partial "--loadout claude-gh"
  assert_output --partial "--agent claude"
}

@test "preserves a pre-existing user Stop hook when merging radio hooks" {
  mkdir -p "$TARGET_DIR/.claude"
  cat > "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "./scripts/pre-tool-lint.sh"}]}
    ]
  }
}
EOF
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  # The user's pre-existing hook must still be there.
  run jq -r '.hooks.Stop | length' "$TARGET_DIR/.claude/settings.json"
  assert_output "2"
  run jq -r '.hooks.Stop[].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  assert_output --partial "./scripts/pre-tool-lint.sh"
  assert_output --partial "radio ready"
}

@test "idempotent re-run does not duplicate radio hook entries" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  for event in SessionStart UserPromptSubmit Stop SessionEnd PermissionRequest PostToolUse; do
    run jq -r ".hooks.$event | length" "$TARGET_DIR/.claude/settings.json"
    assert_output "1"
  done
  # PreToolUse has TWO matcher entries (AskUserQuestion + ExitPlanMode) and
  # `add_radio_matcher` is per-matcher idempotent — re-run must keep both
  # without doubling them up (#119).
  run jq -r '.hooks.PreToolUse | length' "$TARGET_DIR/.claude/settings.json"
  assert_output "2"
}

# Positive coverage for the awaiting-state triggers introduced in #119. The
# previous pin (negative coverage from #114) asserted PreToolUse / Notification
# absence; #119 wires PermissionRequest + PreToolUse(AskUserQuestion,ExitPlanMode)
# → `radio awaiting` and PostToolUse → `radio busy` (reverse edge). Notification
# stays asserted-absent so the broken #112 trigger can't sneak back in.
@test "radio awaiting hooks installed: PermissionRequest, PreToolUse, PostToolUse (#119)" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success

  # PermissionRequest → radio awaiting
  run jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  assert_output "radio awaiting"

  # PreToolUse matchers AskUserQuestion + ExitPlanMode → radio awaiting
  run jq -r '[.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[0].command] | .[0]' "$TARGET_DIR/.claude/settings.json"
  assert_output "radio awaiting"
  run jq -r '[.hooks.PreToolUse[] | select(.matcher == "ExitPlanMode") | .hooks[0].command] | .[0]' "$TARGET_DIR/.claude/settings.json"
  assert_output "radio awaiting"

  # PostToolUse reverse-edge → radio busy
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$TARGET_DIR/.claude/settings.json"
  assert_output "radio busy"

  # Notification still absent (the broken #114 trigger must not return).
  run jq -r '.hooks.Notification // "absent"' "$TARGET_DIR/.claude/settings.json"
  assert_output "absent"
}

# ---------------------------------------------------------------------------
# gh read-only allow-list seeding into .claude/settings.json
# ---------------------------------------------------------------------------

@test "seeds gh read-only patterns into permissions.allow" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run jq -r '.permissions.allow[]' "$TARGET_DIR/.claude/settings.json"
  assert_output --partial "Bash(gh issue view *)"
  assert_output --partial "Bash(gh project view *)"
  assert_output --partial "Bash(gh search issues *)"
  assert_output --partial "Bash(gh pr view *)"
  assert_output --partial "Bash(radio *)"
  # Mutations must NOT be auto-allowed.
  refute_output --partial "gh issue edit"
  refute_output --partial "gh pr merge"
  refute_output --partial "gh project item-edit"
}

@test "idempotent: re-run does not duplicate gh allow-list entries" {
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  local before
  before=$(jq -r '.permissions.allow | length' "$TARGET_DIR/.claude/settings.json")
  run "$CLAUDE_GH_TASK_INIT" --force
  assert_success
  local after
  after=$(jq -r '.permissions.allow | length' "$TARGET_DIR/.claude/settings.json")
  assert_equal "$before" "$after"
}

@test "preserves a pre-existing user permissions.allow entry" {
  mkdir -p "$TARGET_DIR/.claude"
  cat > "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(custom *)"]
  }
}
EOF
  run "$CLAUDE_GH_TASK_INIT"
  assert_success
  run jq -r '.permissions.allow[]' "$TARGET_DIR/.claude/settings.json"
  assert_output --partial "Bash(custom *)"
  assert_output --partial "Bash(gh issue view *)"
}
