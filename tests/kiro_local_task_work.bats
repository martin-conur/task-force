#!/usr/bin/env bats
# Tests for kiro-local/bin/task-work

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  cd "$MAIN_REPO"
  # kiro-local needs a tasks/ dir for board regen. Create it.
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
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "task file path: works with absolute path" {
  _make_task_file "$MAIN_REPO/tasks/042-refactor-auth.md" 042 "Refactor auth"
  run "$KIRO_LOCAL_TASK_WORK" "$MAIN_REPO/tasks/042-refactor-auth.md"
  assert_success
  assert [ -d "$WORKTREE_BASE/refactor-auth" ]
}

@test "free-form slug: still works without a task file" {
  run "$KIRO_LOCAL_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # 100 chars
  run "$KIRO_LOCAL_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/add-login")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
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

  run "$KIRO_LOCAL_TASK_WORK" stale-feature
  assert_success
  assert_output --partial "Branch task/stale-feature already exists. Reusing it."
  assert_output --partial "Current HEAD on main"
  assert_output --partial "Divergence:"
  assert_output --partial "0 ahead, 1 behind main"

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
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  source "$WORKTREE_BASE/.add-login.info"
  assert_equal "$TASK_FILE" "$MAIN_REPO/tasks/001-add-login.md"
}

@test ".info TASK_FILE is empty for free-form slugs" {
  run "$KIRO_LOCAL_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${TASK_FILE:-}" ""
}

@test ".info BASE_BRANCH defaults to current branch" {
  run "$KIRO_LOCAL_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$KIRO_LOCAL_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

@test "writes an entry to .git/task-force/state.json" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/.git/task-force/state.json" ]
  run grep -F '"slug":"add-login"' "$MAIN_REPO/.git/task-force/state.json"
  assert_success
}

@test "state.json entry includes branch, worktree, started_at, task_file" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  local line
  line=$(cat "$MAIN_REPO/.git/task-force/state.json")
  echo "$line" | grep -qF '"branch":"task/add-login"'
  echo "$line" | grep -qF '"worktree"'
  echo "$line" | grep -qF '"started_at"'
  echo "$line" | grep -qF '"task_file"'
}

@test "second run on the same task creates a parallel session entry" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  # Second run creates a parallel session with a -HASH suffix, so the two
  # state.json entries have distinct slugs.
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  local n
  n=$(grep -c '"slug"' "$MAIN_REPO/.git/task-force/state.json")
  assert_equal "$n" "2"
}

# ---------------------------------------------------------------------------
# Board regeneration
# ---------------------------------------------------------------------------

@test "regenerates tasks/_board.md after creating worktree" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output --partial "In Progress"
  assert_output --partial "Add login"
}

# task-work resolves task-board from $PATH first and only then from its own
# sibling copy. The suite runs with $PATH out of reach of ~/.local/bin (#223), so
# without this the $PATH branch would be exercised by nobody on any machine —
# which is the state the bug grew in. Test it on purpose instead.
@test "board regen: \$PATH's task-board is preferred over the sibling copy" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  local bin="$BATS_TEST_TMPDIR/path-bin"
  mkdir -p "$bin"
  cat > "$bin/task-board" <<'BOARD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS_DIR/task-board.calls"
mkdir -p "$2/tasks"
echo "rendered by the PATH copy" > "$2/tasks/_board.md"
BOARD
  chmod +x "$bin/task-board"

  PATH="$bin:$PATH" run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called task-board "--repo $(cd "$MAIN_REPO" && pwd -P)"
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output "rendered by the PATH copy"
}

# A task-board that fails must say so. $PATH takes precedence over the sibling
# copy, so ~/.local/bin's symlink into another checkout is what runs on an
# installed machine — and under the `|| true` this replaces, its failure produced
# no output at all, only a board that silently never appeared (#223).
@test "task-board failing is loud, and does not sink task-work" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  local bin="$BATS_TEST_TMPDIR/foreign-bin"
  mkdir -p "$bin"
  cat > "$bin/task-board" <<'BOARD'
#!/usr/bin/env bash
echo "Error: no workflow doc found (foreign checkout)" >&2
exit 1
BOARD
  chmod +x "$bin/task-board"

  PATH="$bin:$PATH" run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  # The worktree and tab are what task-work is for; a board that did not render
  # is a warning, not a reason to abort after they exist.
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
  assert_output --partial "task-board failed"
  assert_output --partial "$bin/task-board"
  # The failing copy's own diagnostics reach the user rather than /dev/null.
  assert_output --partial "no workflow doc found"
  # And it names this checkout's own copy as the way to render it by hand.
  assert_output --partial "$KIRO_LOCAL_TASK_BOARD --repo"
  assert [ ! -f "$MAIN_REPO/tasks/_board.md" ]
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "new-tab --name add-login"
}

@test "--no-launch: opens tab but does not inject kiro-cli command" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" --no-launch tasks/001-add-login.md
  assert_success
  assert_output --partial "kiro NOT launched"
  run grep -F "kiro-cli" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro-cli command includes task file path when provided" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "Implement task: $MAIN_REPO/tasks/001-add-login.md"
}

@test "kiro-cli command is bare worker invocation for free-form slugs" {
  run "$KIRO_LOCAL_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker"
  # No "Implement task:" payload when there's no task file.
  run grep -F "Implement task:" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Kiro CLI flags
# ---------------------------------------------------------------------------

@test "--model flag is passed to kiro-cli" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" --model claude-opus-4.6 tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "--model claude-opus-4.6"
}

@test "--trust-all flag passes --trust-all-tools to kiro-cli" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run "$KIRO_LOCAL_TASK_WORK" --trust-all tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}

@test "TASK_WORK_MODEL env var sets default model" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  TASK_WORK_MODEL=claude-sonnet-4.6 run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "--model claude-sonnet-4.6"
}

@test "TASK_WORK_TRUST_ALL=1 enables --trust-all-tools by default" {
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  TASK_WORK_TRUST_ALL=1 run "$KIRO_LOCAL_TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$KIRO_LOCAL_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --base missing its value" {
  run "$KIRO_LOCAL_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}

@test "fails when --model missing its value" {
  run "$KIRO_LOCAL_TASK_WORK" --model
  assert_failure
  assert_output --partial "--model requires a value"
}

@test "fails on unknown flag" {
  run "$KIRO_LOCAL_TASK_WORK" --unknown-flag
  assert_failure
}
