#!/usr/bin/env bats
# Tests for the root task-work dispatcher (bin/task-work)
# The dispatcher auto-detects which impl to run based on the project's
# workflow doc, with --impl / AW_IMPL as overrides.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails when not in a git repo" {
  cd /tmp
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails with no impl configured" {
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_failure
  assert_output --partial "no agentic-workflow impl configured"
  assert_output --partial "task-init"
}

@test "fails when multiple impls are configured" {
  mkdir -p "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_failure
  assert_output --partial "multiple"
  assert_output --partial "claude-notion"
  assert_output --partial "kiro-notion"
}

@test "fails on unknown --impl value" {
  run "$TASK_WORK_DISPATCHER" --impl bogus my-feature
  assert_failure
  assert_output --partial "unknown impl"
}

@test "--impl without a value fails" {
  run "$TASK_WORK_DISPATCHER" --impl
  assert_failure
  assert_output --partial "--impl requires a value"
}

# ---------------------------------------------------------------------------
# Auto-detection per workflow doc
# ---------------------------------------------------------------------------

@test "auto-routes to kiro-notion when .kiro/steering/notion-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  # kiro-notion's task-work writes the `kiro-cli` command to zellij.
  assert_stub_called zellij "kiro-cli"
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "auto-routes to kiro-gh when .kiro/steering/gh-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  assert_stub_called zellij "kiro-cli"
  # kiro-gh writes GH_URL= into the info file (tracker-specific var name)
  run grep -q '^GH_URL=' "$WORKTREE_BASE/.my-feature.info"
  assert_success
}

@test "auto-routes to claude-notion when .claude/notion-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  # claude-notion writes `claude "/worker"` to zellij
  assert_stub_called zellij '/worker'
  run grep -q '^NOTION_URL=' "$WORKTREE_BASE/.my-feature.info"
  assert_success
}

@test "auto-routes to claude-gh when .claude/gh-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  assert_stub_called zellij '/worker'
  run grep -q '^GH_URL=' "$WORKTREE_BASE/.my-feature.info"
  assert_success
}

@test "auto-routes to claude-jira when .claude/jira-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/jira-workflow.md"
  run "$TASK_WORK_DISPATCHER" PROJ-123
  assert_success
  assert_stub_called zellij '/worker'
  run grep -F 'JIRA_REF=PROJ-123' "$WORKTREE_BASE/.proj-123.info"
  assert_success
}

@test "auto-routes to claude-local when .claude/local-workflow.md exists" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/local-workflow.md"
  run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  assert_stub_called zellij '/worker'
  run grep -q '^TASK_FILE=' "$WORKTREE_BASE/.my-feature.info"
  assert_success
}

# ---------------------------------------------------------------------------
# Overrides
# ---------------------------------------------------------------------------

@test "--impl overrides auto-detection" {
  # Project has claude-notion configured…
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  # …but we force kiro-notion.
  run "$TASK_WORK_DISPATCHER" --impl kiro-notion my-feature
  assert_success
  assert_stub_called zellij "kiro-cli"
}

@test "--impl=value syntax works" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" --impl=kiro-notion my-feature
  assert_success
  assert_stub_called zellij "kiro-cli"
}

@test "AW_IMPL env var picks the impl when none is auto-detected" {
  AW_IMPL=kiro-notion run "$TASK_WORK_DISPATCHER" my-feature
  assert_success
  assert_stub_called zellij "kiro-cli"
}

@test "--impl beats AW_IMPL" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  AW_IMPL=claude-notion run "$TASK_WORK_DISPATCHER" --impl kiro-notion my-feature
  assert_success
  assert_stub_called zellij "kiro-cli"
}

# ---------------------------------------------------------------------------
# Argument passthrough
# ---------------------------------------------------------------------------

@test "passes positional args through to the impl script" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" "My Feature Task"
  assert_success
  # kiro-notion sanitizes the slug; the impl creates the worktree at that path
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "passes --base through to the impl script" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

@test "passes impl-specific flag (kiro-notion --trust-all) through" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_WORK_DISPATCHER" --trust-all my-feature
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}
