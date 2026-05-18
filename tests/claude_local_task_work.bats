#!/usr/bin/env bats
# Tests for claude-local/bin/task-work

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  # task-local needs a tasks/ dir for board regen. Create it.
  mkdir -p "$MAIN_REPO/tasks"
}

teardown() {
  teardown_all
}

# Helper: create a task file with frontmatter.
_make_task_file() {
  local path="$1" id="$2" title="$3" status="${4:-todo}"
  cat > "$path" <<EOF
---
id: $id
title: $title
status: $status
priority: P2
tags: []
created: 2026-05-15
branch: ""
pr: ""
---

## Problem

A test problem.
EOF
}

# ---------------------------------------------------------------------------
# Slug derivation
# ---------------------------------------------------------------------------

@test "task file path: derives slug by stripping NNN- and .md" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "task file path: works with absolute path" {
  _make_task_file "$MAIN_REPO/tasks/042-refactor-auth.md" 042 "Refactor auth"
  run "$CLAUDE_LOCAL_TASK_WORK" "$MAIN_REPO/tasks/042-refactor-auth.md"
  assert_success
  assert [ -d "$WORKTREE_BASE/refactor-auth" ]
}

@test "free-form slug: still works without a task file" {
  run "$CLAUDE_LOCAL_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # 100 chars
  run "$CLAUDE_LOCAL_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/add-login")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_output --partial "parallel session"
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^add-login'"
  assert_output "2"
}

@test "branch collision: warns and reuses when task branch already exists" {
  git -C "$MAIN_REPO" branch task/stale-feature
  echo "newer" > "$MAIN_REPO/newfile.txt"
  git -C "$MAIN_REPO" add newfile.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"

  run "$CLAUDE_LOCAL_TASK_WORK" stale-feature
  assert_success
  assert_output --partial "Branch task/stale-feature already exists. Reusing it."
  assert_output --partial "Current HEAD on main"

  local wt_head main_head
  wt_head=$(git -C "$WORKTREE_BASE/stale-feature" rev-parse HEAD)
  main_head=$(git -C "$MAIN_REPO" rev-parse main)
  [[ "$wt_head" != "$main_head" ]]
}

# ---------------------------------------------------------------------------
# .info file
# ---------------------------------------------------------------------------

@test ".info records TASK_FILE absolute path" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  source "$WORKTREE_BASE/.add-login.info"
  assert_equal "$TASK_FILE" "$MAIN_REPO/tasks/001-add-login.md"
}

@test ".info TASK_FILE is empty for free-form slugs" {
  run "$CLAUDE_LOCAL_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${TASK_FILE:-}" ""
}

@test ".info BASE_BRANCH defaults to current branch" {
  run "$CLAUDE_LOCAL_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$CLAUDE_LOCAL_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

@test "writes an entry to .git/task-force/state.json" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/.git/task-force/state.json" ]
  run grep -F '"slug":"add-login"' "$MAIN_REPO/.git/task-force/state.json"
  assert_success
}

@test "state.json entry includes branch, worktree, started_at, task_file" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  local line
  line=$(cat "$MAIN_REPO/.git/task-force/state.json")
  echo "$line" | grep -qF '"branch":"task/add-login"'
  echo "$line" | grep -qF '"worktree"'
  echo "$line" | grep -qF '"started_at"'
  echo "$line" | grep -qF '"task_file"'
}

@test "running twice does not duplicate the slug entry" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  # Second run creates a parallel session with a -HASH suffix, so the
  # original slug entry is gone but a new hashed slug entry exists.
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  # There should be exactly 1 "add-login" base + 1 hashed slug = 2 lines total.
  local n
  n=$(grep -c '"slug"' "$MAIN_REPO/.git/task-force/state.json")
  assert_equal "$n" "2"
}

# ---------------------------------------------------------------------------
# Board regeneration
# ---------------------------------------------------------------------------

@test "regenerates tasks/_board.md after creating worktree" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
  # Task should appear in the In Progress section because state.json overrides
  # the frontmatter "todo" status.
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output --partial "In Progress"
  assert_output --partial "Add login"
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "new-tab --name add-login"
}

@test "--no-launch: opens tab but does not inject claude command" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" --no-launch tasks/001-add-login.md
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude command includes task file path when provided" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$CLAUDE_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "/worker $MAIN_REPO/tasks/001-add-login.md"
}

@test "claude command uses bare /worker for free-form slugs" {
  run "$CLAUDE_LOCAL_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij 'claude "/worker"'
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_LOCAL_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --base missing its value" {
  run "$CLAUDE_LOCAL_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}

@test "fails on unknown flag" {
  run "$CLAUDE_LOCAL_TASK_WORK" --unknown-flag
  assert_failure
}
