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
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$KIRO_GH_TASK_INIT" --owner old
  assert_success
  run "$KIRO_GH_TASK_INIT" --owner ignored
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "old"
  refute_output --partial "ignored"
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

@test "--force + --restore is rejected" {
  run "$KIRO_GH_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted agent without touching workflow" {
  run "$KIRO_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  cp "$TARGET_DIR/.kiro/steering/gh-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs agents without writing workflow doc" {
  run "$KIRO_GH_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "--workflow installs workflow doc without writing agents" {
  run "$KIRO_GH_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.kiro/agents" ]
}

# ---------------------------------------------------------------------------
# Placeholder preservation
# ---------------------------------------------------------------------------

@test "--force preserves filled-in {OWNER}/{REPO}/{PROJECT} when no flags passed" {
  run "$KIRO_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  assert_output --partial "**Project number**: \`7\`"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

# ---------------------------------------------------------------------------
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .kiro/agents/ as real files" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ ! -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents are copies of kiro-gh/agents/" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run cmp -s "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  ln -sf /nonexistent/path "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" "$TARGET_DIR/.kiro/agents/pm.json"
  assert_success
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT"
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
  run "$KIRO_GH_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}
