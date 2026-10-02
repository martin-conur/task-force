#!/usr/bin/env bats
# Tests for task-done — one canonical bin/task-done since #236, composing one
# tracker module out of lib/trackers/.
#
# Each test pins a loadout with AW_IMPL, because a task worktree has no workflow
# doc for detection to find. The prefix on a test name says what it is for:
#
#   shared:        the one canonical assertion for shared-body behaviour. Pinned
#                  to kiro-notion arbitrarily — any impl would do, which is
#                  precisely why asserting it seven times proved nothing.
#   <impl>:        an impl-DISTINGUISHING observable, which a failed module load
#                  could not produce. jira -> the uppercased Jira-key PR title;
#                  claude-local -> tasks/_board.md regenerated and the
#                  state.json entry struck.
#   all seven      the `unregisters the radio session` table is deliberately
#                  kept at seven rows: it is the only place every impl runs the
#                  full script end to end, so it is what would catch a module
#                  that loads but never fires.
#
# That last distinction is the #206 lesson — a region can be byte-identical and
# still inert. tests/loadout_modules.bats proves every module LOADS; only this
# file proves the right one RAN. Before #236 this suite asserted the shared body
# up to seven times and the per-tracker difference once; 32 of those 67 cases
# were retired with the six files they duplicated (see the PR body for the
# name-by-name table).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SLUG="my-feature"

# Run task-done from inside the worktree, auto-confirming prompts.
# Usage: run_task_done <impl> [extra args...]
#
# There is one task-done since #236; the loadout is which tracker module it
# composes, pinned with AW_IMPL because a test worktree has no workflow doc to
# detect from. Pre-#236 this took a path to one of seven per-loadout copies.
run_task_done() {
  local impl="$1"; shift
  # Pipe "y\n" to confirm the "Remove worktree?" prompt
  run bash -c "echo y | env AW_IMPL=$impl $TASK_DONE $*"
}

setup() {
  setup_repo
  setup_stubs
  setup_worktree "$SLUG"
  # task-done runs `radio unregister --manual`, which wipes a session file
  # unconditionally by design. Without an isolated radio home that lands on the
  # live session of whoever ran the suite (#203).
  setup_task_force_home
  cd "$WORKTREE_BASE/$SLUG"
}

teardown() {
  teardown_all
  if [[ -f "$BATS_TEST_TMPDIR/.submodule_src" ]]; then
    local src
    src=$(cat "$BATS_TEST_TMPDIR/.submodule_src")
    [[ -d "$src" ]] && rm -rf "$src"
  fi
}

# ---------------------------------------------------------------------------
# Guard: must be in a worktree
# ---------------------------------------------------------------------------

@test "shared: fails when run from main repo" {
  cd "$MAIN_REPO"
  run env AW_IMPL=kiro-notion "$TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------

@test "shared: shows branch and base branch" {
  run_task_done kiro-notion --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "shared: reads custom BASE_BRANCH from .info file" {
  # Overwrite the info file with a different base
  printf 'BASE_BRANCH=develop\nSLUG=%s\nNOTION_URL=\n' "$SLUG" \
    > "$WORKTREE_BASE/.$SLUG.info"
  run_task_done kiro-notion --force
  assert_output --partial "Base:     develop"
}

@test "shared: shows commit count ahead of base" {
  # Make a commit in the worktree
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done kiro-notion --force
  assert_output --partial "Commits ahead of main: 1"
}

@test "shared: shows diff shortstat when there are commits" {
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done kiro-notion --force
  assert_output --partial "Changes:"
}

# ---------------------------------------------------------------------------
# PR section
# ---------------------------------------------------------------------------

@test "shared: shows gh pr create with correct --base when no PR exists" {
  run_task_done kiro-notion --force
  assert_output --partial "gh pr create --base main --head task/$SLUG"
}

@test "shared: shows existing PR URL instead of create command" {
  export GH_STUB_PR_URL="https://github.com/org/repo/pull/42"
  run_task_done kiro-notion --force
  assert_output --partial "PR: https://github.com/org/repo/pull/42"
  refute_output --partial "gh pr create"
}

@test "jira: PR title uppercases Jira key slug" {
  setup_worktree "proj-99"
  cd "$WORKTREE_BASE/proj-99"
  run_task_done claude-jira --force
  assert_output --partial '"PROJ-99"'
}

@test "jira: PR title uses raw slug for non-Jira branches" {
  run_task_done claude-jira --force
  assert_output --partial '"my-feature"'
}

# ---------------------------------------------------------------------------
# --remove-worktree flag
# ---------------------------------------------------------------------------

@test "shared: --remove-worktree skips PR section" {
  run_task_done kiro-notion --remove-worktree
  refute_output --partial "gh pr create"
  refute_output --partial "To create a PR"
}

@test "shared: --remove-worktree --force skips all prompts" {
  run env AW_IMPL=kiro-notion "$TASK_DONE" --remove-worktree --force
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "shared: --remove-worktree alone exits 0 without reading stdin" {
  # No --force, no piped input. Bug was that the "Remove worktree?" prompt
  # still fired and would hang reading stdin.
  run env AW_IMPL=kiro-notion "$TASK_DONE" --remove-worktree </dev/null
  assert_success
  refute_output --partial "Remove worktree and close tab?"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

@test "shared: removes worktree directory" {
  run_task_done kiro-notion --force
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "shared: deletes .info file after removal" {
  run_task_done kiro-notion --force
  assert [ ! -f "$WORKTREE_BASE/.$SLUG.info" ]
}

@test "shared: skips zellij close-tab when no radio session (no \$ZELLIJ env)" {
  # Without ZELLIJ + a session file with TAB_ID=, task-done now skips the
  # close-tab call entirely rather than falling back to the focused-tab
  # `close-tab` (#107). See task_done_close_tab.bats for the close path.
  run_task_done kiro-notion --force
  assert_output --partial "Skipping zellij close-tab"
  run stub_calls zellij
  refute_output --partial "close-tab"
}

@test "shared: no prompt when --force is set" {
  # With --force, should not block waiting for stdin
  run env AW_IMPL=kiro-notion "$TASK_DONE" --force
  assert_success
}

# ---------------------------------------------------------------------------
# Uncommitted changes warning
# ---------------------------------------------------------------------------

@test "shared: warns about uncommitted changes" {
  echo "dirty" > "$WORKTREE_BASE/$SLUG/dirty.txt"
  git -C "$WORKTREE_BASE/$SLUG" add dirty.txt
  # Don't commit — leave staged

  run bash -c "echo y | env AW_IMPL=kiro-notion $TASK_DONE --force"
  assert_output --partial "Uncommitted changes"
}

# ---------------------------------------------------------------------------
# Local branch deletion after worktree removal
# ---------------------------------------------------------------------------

@test "shared: deletes local branch when fully merged (no new commits)" {
  # Fresh branch with no commits ahead of main is trivially merged.
  run_task_done kiro-notion --force
  assert_success
  assert_output --partial "Deleted local branch 'task/$SLUG'"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output ""
}

@test "shared: keeps local branch when it has unmerged commits" {
  # Commit on the task branch — now it's ahead of main and not merged.
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done kiro-notion --force
  assert_success
  assert_output --partial "still has unmerged commits"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output --partial "task/$SLUG"
}

# ---------------------------------------------------------------------------
# Submodule cleanup (issue #35)
# Without the deinit step, `git worktree remove` refuses with
# "fatal: working trees containing submodules cannot be moved or removed".
# ---------------------------------------------------------------------------

# Initialize a real submodule inside the current worktree.
# Creates a separate source repo and adds it as a submodule named "lib".
add_submodule_to_worktree() {
  local worktree="$1"
  local submodule_src
  submodule_src=$(mktemp -d)
  git -C "$submodule_src" init -q -b main
  git -C "$submodule_src" config user.email "test@test.local"
  git -C "$submodule_src" config user.name "Test"
  touch "$submodule_src/sub.txt"
  git -C "$submodule_src" add sub.txt
  git -C "$submodule_src" commit -q -m "init submodule"

  # protocol.file.allow=always is required by modern git for local-path submodules.
  git -C "$worktree" -c protocol.file.allow=always submodule add -q "$submodule_src" lib
  git -C "$worktree" commit -q -m "add submodule"
  # Stash for cleanup; teardown() reads this marker.
  echo "$submodule_src" > "$BATS_TEST_TMPDIR/.submodule_src"
}

@test "shared: removes worktree containing initialized submodules without warning" {
  add_submodule_to_worktree "$WORKTREE_BASE/$SLUG"

  run_task_done kiro-notion --force
  assert_success
  refute_output --partial "could not remove worktree cleanly"
  refute_output --partial "removal failed"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

# ---------------------------------------------------------------------------
# Radio session unregister on cleanup (issue #94)
# task-done must call `radio unregister` so worker session files don't
# accumulate as orphans in ~/.task-force/radio/sessions/.
# ---------------------------------------------------------------------------

# Pre-register a radio session for the current "worker" role, then assert
# task-done removes it. Uses the real radio binary on PATH; setup()'s isolated
# $TASK_FORCE_HOME keeps the host's session dir untouched.
assert_task_done_unregisters() {
  local impl="$1"
  local script="env AW_IMPL=$impl $TASK_DONE"
  local role="worker-task-force-$SLUG"

  cp "$RADIO" "$STUB_BIN/radio"
  chmod +x "$STUB_BIN/radio"
  export TASK_FORCE_ROLE="$role"

  "$RADIO" register --role "$role" --tab "$role" --agent claude --loadout claude-gh
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]

  run bash -c "echo y | $script --force"
  assert_success
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]
}

@test "kiro-notion: task-done unregisters the radio session" {
  assert_task_done_unregisters kiro-notion
}

@test "jira: task-done unregisters the radio session" {
  assert_task_done_unregisters claude-jira
}

@test "claude-notion: task-done unregisters the radio session" {
  assert_task_done_unregisters claude-notion
}

@test "claude-gh: task-done unregisters the radio session" {
  assert_task_done_unregisters claude-gh
}

@test "kiro-gh: task-done unregisters the radio session" {
  assert_task_done_unregisters kiro-gh
}

@test "claude-local: task-done unregisters the radio session" {
  assert_task_done_unregisters claude-local
}

@test "kiro-local: task-done unregisters the radio session" {
  assert_task_done_unregisters kiro-local
}

# ---------------------------------------------------------------------------
# Board regeneration on the local loadouts (#223)
# ---------------------------------------------------------------------------

# task-done re-renders tasks/_board.md from the main worktree on the way out.
# It resolves task-board the same way task-work does — $PATH first, then the
# sibling copy — so the suite has to be out of reach of ~/.local/bin for this to
# be testing the checkout it thinks it is (see tests/helpers/path_isolation.bash).
assert_task_done_regenerates_board() {
  local impl="$1"
  mkdir -p "$MAIN_REPO/tasks"
  cat > "$MAIN_REPO/tasks/001-add-login.md" <<'TASK'
---
id: 001
title: Add login
status: todo
priority: P2
tags: []
created: 2026-05-15
branch: ""
pr: ""
---

## Problem

A test problem.
TASK
  run_task_done "$impl" --force
  assert_success
  # Checked against task-done's own output, before $output is replaced below.
  refute_output --partial "task-board failed"
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output --partial "Add login"
}

@test "claude-local: task-done regenerates tasks/_board.md" {
  assert_task_done_regenerates_board claude-local
}

@test "kiro-local: task-done regenerates tasks/_board.md" {
  assert_task_done_regenerates_board kiro-local
}

# ---------------------------------------------------------------------------
# Reviewer-worktree branch cleanup (issue #148)
# A reviewer worktree (created by task-reviewer) writes PR_NUMBER= into its
# $INFO_FILE. The branch (task/review-pr<N>) is pure scaffolding forked from
# the PR's head ref — it's never going to merge into main, so the safe-delete
# `git branch -d` always fails and leaves an orphan that blocks the next
# `task-reviewer <N>` dispatch. task-done must force-delete (`git branch -D`)
# when PR_NUMBER is set; worker behavior (BASE_BRANCH set, no PR_NUMBER) must
# stay unchanged.
# ---------------------------------------------------------------------------

# Set up a fake reviewer worktree: branch with a commit not in main, plus a
# PR_NUMBER marker in the .info file. Sets $RSLUG so tests can cd into it.
setup_reviewer_worktree() {
  local pr_num="${1:-42}"
  RSLUG="review-pr${pr_num}"

  # The reviewer branch carries a commit not in main, so `git branch -d` would
  # refuse (this is the production case — branch forks from the PR's head ref).
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$RSLUG" -b "task/$RSLUG"
  touch "$WORKTREE_BASE/$RSLUG/scaffold.txt"
  git -C "$WORKTREE_BASE/$RSLUG" add scaffold.txt
  git -C "$WORKTREE_BASE/$RSLUG" commit -q -m "scaffold commit (simulated PR head)"

  printf 'BASE_BRANCH=main\nSLUG=%s\nPR_NUMBER=%s\nISSUE_NUMBER=\n' \
    "$RSLUG" "$pr_num" > "$WORKTREE_BASE/.$RSLUG.info"
}

assert_reviewer_branch_force_deleted() {
  local impl="$1"
  setup_reviewer_worktree 42
  cd "$WORKTREE_BASE/$RSLUG"

  run env AW_IMPL="$impl" "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Deleted reviewer branch 'task/$RSLUG'"
  refute_output --partial "still has unmerged commits"
  run git -C "$MAIN_REPO" branch --list "task/$RSLUG"
  assert_output ""
}

@test "claude-gh: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted claude-gh
}

@test "claude-gh: worker worktree (no PR_NUMBER) still uses safe-delete -d" {
  # Regression: BASE_BRANCH set, PR_NUMBER absent → unmerged commits leave the
  # branch behind with the manual-cleanup message, unchanged from pre-#148.
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done claude-gh --force
  assert_success
  assert_output --partial "still has unmerged commits"
  refute_output --partial "Deleted reviewer branch"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output --partial "task/$SLUG"
}

# Ambient-export regression — without `PR_NUMBER=` zero-init before sourcing
# the worker's $INFO_FILE, an exported PR_NUMBER from the surrounding shell
# (e.g., left over from a prior task-reviewer session) leaks into the
# force-delete guard and triggers `git branch -D` on a worker branch with
# unmerged commits — silently destroying them. The fix initializes
# `PR_NUMBER=` right before the source call (mirroring `BASE_BRANCH="main"`),
# so a worker .info file that contains no PR_NUMBER= line ends up with
# PR_NUMBER empty regardless of ambient environment.
assert_ambient_pr_number_does_not_force_delete() {
  local impl="$1"
  local script="env AW_IMPL=$impl $TASK_DONE"

  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged worker commit (must survive)"

  # Capture commit sha so we can confirm the branch object still exists after
  # cleanup (i.e., -d refused to drop it).
  local sha
  sha=$(git -C "$WORKTREE_BASE/$SLUG" rev-parse HEAD)

  # Ambient export — simulates user having run `task-reviewer 42` earlier in
  # the same shell with the env still set when they cd'd into the worker.
  export PR_NUMBER=42

  run bash -c "echo y | $script --force"

  unset PR_NUMBER

  assert_success
  assert_output --partial "still has unmerged commits"
  refute_output --partial "Deleted reviewer branch"
  refute_output --partial "(-D, scaffold-only)"

  # Branch must still exist and still point at the unmerged commit.
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output --partial "task/$SLUG"
  run git -C "$MAIN_REPO" rev-parse "task/$SLUG"
  assert_output "$sha"
}

@test "claude-gh: ambient PR_NUMBER export does NOT trigger force-delete on worker" {
  assert_ambient_pr_number_does_not_force_delete claude-gh
}

@test "task-done cleanup tolerates radio binary missing from PATH (#94)" {
  # The `|| true` safety net: if radio isn't installed (or PATH doesn't
  # include it), cleanup must still succeed.
  export TASK_FORCE_ROLE="worker-task-force-$SLUG"
  # Note: deliberately do NOT install radio into $STUB_BIN here.

  run bash -c "echo y | env AW_IMPL=claude-gh $TASK_DONE --force"
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

# ---------------------------------------------------------------------------
# Radio mailbox sweep on cleanup (#169)
# ---------------------------------------------------------------------------

@test "claude-gh: --remove-worktree sweeps its own radio mailbox" {
  export TASK_FORCE_ROLE="worker-task-force-$SLUG"
  local mbx="$TASK_FORCE_HOME/radio/mailbox/$TASK_FORCE_ROLE"
  mkdir -p "$mbx/inbox" "$mbx/processed"
  printf 'stranded approved-and-merged\n' > "$mbx/inbox/msg.md"

  run bash -c "echo y | env AW_IMPL=claude-gh $TASK_DONE --force --remove-worktree"
  assert_success
  assert [ ! -d "$mbx" ]
}

@test "claude-gh: mailbox sweep is a no-op (keeps mailbox root) when role is unset" {
  unset TASK_FORCE_ROLE
  mkdir -p "$TASK_FORCE_HOME/radio/mailbox/some-other-role"

  run bash -c "echo y | env AW_IMPL=claude-gh $TASK_DONE --force --remove-worktree"
  assert_success
  # An empty/unsafe role must never rm -rf the whole mailbox root.
  assert [ -d "$TASK_FORCE_HOME/radio/mailbox/some-other-role" ]
}
