#!/usr/bin/env bash
# Shared setup/teardown helpers for all test suites.
# Source this from the setup() / teardown() functions in each .bats file.

REPO_ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIRO_TASK_WORK="$REPO_ROOT_REAL/kiro-notion/bin/task-work"
JIRA_TASK_WORK="$REPO_ROOT_REAL/claude-jira/bin/task-work"
KIRO_TASK_DONE="$REPO_ROOT_REAL/kiro-notion/bin/task-done"
JIRA_TASK_DONE="$REPO_ROOT_REAL/claude-jira/bin/task-done"
JIRA_TASK_INIT="$REPO_ROOT_REAL/claude-jira/bin/task-init"
JIRA_TEMPLATE="$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md"
CLAUDE_NOTION_TASK_WORK="$REPO_ROOT_REAL/claude-notion/bin/task-work"
CLAUDE_NOTION_TASK_DONE="$REPO_ROOT_REAL/claude-notion/bin/task-done"
CLAUDE_NOTION_TASK_INIT="$REPO_ROOT_REAL/claude-notion/bin/task-init"
CLAUDE_NOTION_TEMPLATE="$REPO_ROOT_REAL/claude-notion/steering/notion-workflow.example.md"
KIRO_TASK_INIT="$REPO_ROOT_REAL/kiro-notion/bin/task-init"
KIRO_TEMPLATE="$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"

# Creates a temp directory with a git repo, sets up $MAIN_REPO,
# $REPO_NAME, and $WORKTREE_BASE.
setup_repo() {
  MAIN_REPO=$(mktemp -d)
  REPO_NAME=$(basename "$MAIN_REPO")
  WORKTREE_BASE="${MAIN_REPO}/../${REPO_NAME}-worktrees"

  git -C "$MAIN_REPO" init -q -b main
  git -C "$MAIN_REPO" config user.email "test@test.local"
  git -C "$MAIN_REPO" config user.name "Test"
  touch "$MAIN_REPO/README.md"
  git -C "$MAIN_REPO" add README.md
  git -C "$MAIN_REPO" commit -q -m "init"
}

# Creates a git worktree + .info file, simulating what task-work would do.
# Usage: setup_worktree <slug> [base_branch]
setup_worktree() {
  local slug="$1"
  local base="${2:-main}"
  local branch="task/$slug"

  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "$branch"

  printf 'BASE_BRANCH=%s\nSLUG=%s\nNOTION_URL=\n' "$base" "$slug" \
    > "$WORKTREE_BASE/.$slug.info"
}

# Puts stub scripts first on PATH and sets STUB_CALLS_DIR for recording.
setup_stubs() {
  STUB_BIN=$(mktemp -d)
  STUB_CALLS_DIR=$(mktemp -d)
  export STUB_BIN STUB_CALLS_DIR

  for stub in zellij gh kiro-cli claude; do
    cp "$REPO_ROOT_REAL/tests/helpers/stubs/$stub" "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
  done

  export PATH="$STUB_BIN:$PATH"
}

teardown_all() {
  # Remove temp repos; git prune first to avoid "not a git worktree" errors
  if [[ -n "${MAIN_REPO:-}" && -d "$MAIN_REPO" ]]; then
    git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
    rm -rf "$MAIN_REPO"
  fi
  [[ -n "${WORKTREE_BASE:-}" ]] && rm -rf "$WORKTREE_BASE" || true
  [[ -n "${STUB_BIN:-}"      ]] && rm -rf "$STUB_BIN"      || true
  [[ -n "${STUB_CALLS_DIR:-}" ]] && rm -rf "$STUB_CALLS_DIR" || true
}

# Read the recorded calls for a stub command.
# Usage: stub_calls zellij
stub_calls() {
  local cmd="$1"
  cat "$STUB_CALLS_DIR/$cmd.calls" 2>/dev/null || true
}

# Assert a stub was called with args matching a substring.
# Usage: assert_stub_called zellij "new-tab"
assert_stub_called() {
  local cmd="$1"
  local pattern="$2"
  local calls
  calls=$(stub_calls "$cmd")
  if ! echo "$calls" | grep -qF -- "$pattern"; then
    echo "Expected $cmd to be called with '$pattern', but got:"
    echo "$calls"
    return 1
  fi
}
