#!/usr/bin/env bash
# Shared setup/teardown helpers for all test suites.
# Source this from the setup() / teardown() functions in each .bats file.
# shellcheck disable=SC2034  # path vars are used by the .bats files that load this helper

REPO_ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIRO_TASK_WORK="$REPO_ROOT_REAL/kiro-notion/bin/task-work"
JIRA_TASK_WORK="$REPO_ROOT_REAL/claude-jira/bin/task-work"
KIRO_TASK_DONE="$REPO_ROOT_REAL/kiro-notion/bin/task-done"
JIRA_TASK_DONE="$REPO_ROOT_REAL/claude-jira/bin/task-done"
JIRA_TASK_INIT="$REPO_ROOT_REAL/claude-jira/bin/task-init"
TASK_INIT_DISPATCHER="$REPO_ROOT_REAL/task-init"
TASK_WORK_DISPATCHER="$REPO_ROOT_REAL/bin/task-work"
TASK_DONE_DISPATCHER="$REPO_ROOT_REAL/bin/task-done"
JIRA_TEMPLATE="$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md"
CLAUDE_NOTION_TASK_WORK="$REPO_ROOT_REAL/claude-notion/bin/task-work"
CLAUDE_NOTION_TASK_DONE="$REPO_ROOT_REAL/claude-notion/bin/task-done"
CLAUDE_NOTION_TASK_INIT="$REPO_ROOT_REAL/claude-notion/bin/task-init"
CLAUDE_NOTION_TEMPLATE="$REPO_ROOT_REAL/claude-notion/steering/notion-workflow.example.md"
KIRO_TASK_INIT="$REPO_ROOT_REAL/kiro-notion/bin/task-init"
KIRO_TEMPLATE="$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
CLAUDE_GH_TASK_WORK="$REPO_ROOT_REAL/claude-gh/bin/task-work"
CLAUDE_GH_TASK_DONE="$REPO_ROOT_REAL/claude-gh/bin/task-done"
CLAUDE_GH_TASK_INIT="$REPO_ROOT_REAL/claude-gh/bin/task-init"
CLAUDE_GH_TEMPLATE="$REPO_ROOT_REAL/claude-gh/steering/gh-workflow.example.md"
KIRO_GH_TASK_WORK="$REPO_ROOT_REAL/kiro-gh/bin/task-work"
KIRO_GH_TASK_DONE="$REPO_ROOT_REAL/kiro-gh/bin/task-done"
KIRO_GH_TASK_INIT="$REPO_ROOT_REAL/kiro-gh/bin/task-init"
KIRO_GH_TEMPLATE="$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
CLAUDE_LOCAL_TASK_WORK="$REPO_ROOT_REAL/claude-local/bin/task-work"
CLAUDE_LOCAL_TASK_DONE="$REPO_ROOT_REAL/claude-local/bin/task-done"
CLAUDE_LOCAL_TASK_INIT="$REPO_ROOT_REAL/claude-local/bin/task-init"
CLAUDE_LOCAL_TASK_BOARD="$REPO_ROOT_REAL/claude-local/bin/task-board"
CLAUDE_LOCAL_TEMPLATE="$REPO_ROOT_REAL/claude-local/steering/local-workflow.example.md"
KIRO_LOCAL_TASK_WORK="$REPO_ROOT_REAL/kiro-local/bin/task-work"
KIRO_LOCAL_TASK_DONE="$REPO_ROOT_REAL/kiro-local/bin/task-done"
KIRO_LOCAL_TASK_INIT="$REPO_ROOT_REAL/kiro-local/bin/task-init"
KIRO_LOCAL_TASK_BOARD="$REPO_ROOT_REAL/kiro-local/bin/task-board"
KIRO_LOCAL_TEMPLATE="$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
RADIO="$REPO_ROOT_REAL/claude-gh/bin/radio"
TASK_PM_CLAUDE="$REPO_ROOT_REAL/claude-gh/bin/task-pm"
TASK_PM_KIRO="$REPO_ROOT_REAL/kiro-gh/bin/task-pm"
TASK_PM_DISPATCHER="$REPO_ROOT_REAL/bin/task-pm"
TASK_REVIEWER_CLAUDE="$REPO_ROOT_REAL/claude-gh/bin/task-reviewer"
TASK_REVIEWER_KIRO="$REPO_ROOT_REAL/kiro-gh/bin/task-reviewer"
TASK_REVIEWER_DISPATCHER="$REPO_ROOT_REAL/bin/task-reviewer"

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

# Creates a tempdir for $TASK_FORCE_HOME (radio mailbox root) and exports it.
# Pair with teardown_all() which cleans it up.
setup_task_force_home() {
  TASK_FORCE_HOME=$(mktemp -d)
  export TASK_FORCE_HOME
}

# Puts stub scripts first on PATH and sets STUB_CALLS_DIR for recording.
setup_stubs() {
  STUB_BIN=$(mktemp -d)
  STUB_CALLS_DIR=$(mktemp -d)
  export STUB_BIN STUB_CALLS_DIR

  for stub in zellij gh kiro-cli claude fzf gum; do
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
  [[ -z "${WORKTREE_BASE:-}"   ]] || rm -rf "$WORKTREE_BASE"
  [[ -z "${STUB_BIN:-}"        ]] || rm -rf "$STUB_BIN"
  [[ -z "${STUB_CALLS_DIR:-}"  ]] || rm -rf "$STUB_CALLS_DIR"
  [[ -z "${TASK_FORCE_HOME:-}" ]] || rm -rf "$TASK_FORCE_HOME"
}

# Seed the zellij stub with a JSON snapshot of tabs / panes for the radio
# helpers (`_zellij_tab_id_by_name`, `_zellij_pane_in_tab`) to consume.
# Usage: seed_zellij_tabs role1 [role2 ...]
# Each role gets tab_id 7,8,9,… and pane_id = tab_id*100, with three name
# entries per role (bare slug + ⏸️ / ▶️ prefixed) so any lookup against
# whatever's currently persisted in TAB= resolves to the same tab id.
seed_zellij_tabs() {
  local entries='' panes='' id=7
  for role in "$@"; do
    [[ -z "$entries" ]] || entries+=','
    entries+="
    {\"name\": \"$role\", \"tab_id\": $id},
    {\"name\": \"⏸️ $role\", \"tab_id\": $id},
    {\"name\": \"▶️ $role\", \"tab_id\": $id}"
    [[ -z "$panes" ]] || panes+=','
    panes+="
    {\"id\": $(( id * 100 )), \"is_plugin\": false, \"is_focused\": true, \"tab_id\": $id}"
    id=$(( id + 1 ))
  done
  export STUB_ZELLIJ_TABS_JSON="[${entries}
  ]"
  export STUB_ZELLIJ_PANES_JSON="[${panes}
  ]"
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
