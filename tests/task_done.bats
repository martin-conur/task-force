#!/usr/bin/env bats
# Tests for task-done (both kiro-notion and claude-jira versions).
# The two scripts share identical logic except for Jira-key PR title casing,
# so most tests run against both.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SLUG="my-feature"

# Run a task-done script from inside the worktree, auto-confirming prompts.
# Usage: run_task_done <script> [extra args...]
run_task_done() {
  local script="$1"; shift
  # Pipe "y\n" to confirm the "Remove worktree?" prompt
  run bash -c "echo y | $script $*"
}

setup() {
  setup_repo
  setup_stubs
  setup_worktree "$SLUG"
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

@test "kiro: fails when run from main repo" {
  cd "$MAIN_REPO"
  run "$KIRO_TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

@test "jira: fails when run from main repo" {
  cd "$MAIN_REPO"
  run "$JIRA_TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------

@test "kiro: shows branch and base branch" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "jira: shows branch and base branch" {
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "kiro: reads custom BASE_BRANCH from .info file" {
  # Overwrite the info file with a different base
  printf 'BASE_BRANCH=develop\nSLUG=%s\nNOTION_URL=\n' "$SLUG" \
    > "$WORKTREE_BASE/.$SLUG.info"
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Base:     develop"
}

@test "kiro: shows commit count ahead of base" {
  # Make a commit in the worktree
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Commits ahead of main: 1"
}

@test "kiro: shows diff shortstat when there are commits" {
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Changes:"
}

# ---------------------------------------------------------------------------
# PR section
# ---------------------------------------------------------------------------

@test "kiro: shows gh pr create with correct --base when no PR exists" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "gh pr create --base main --head task/$SLUG"
}

@test "kiro: shows existing PR URL instead of create command" {
  export GH_STUB_PR_URL="https://github.com/org/repo/pull/42"
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "PR: https://github.com/org/repo/pull/42"
  refute_output --partial "gh pr create"
}

@test "jira: PR title uppercases Jira key slug" {
  setup_worktree "proj-99"
  cd "$WORKTREE_BASE/proj-99"
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial '"PROJ-99"'
}

@test "jira: PR title uses raw slug for non-Jira branches" {
  run_task_done "$JIRA_TASK_DONE" --force
  assert_output --partial '"my-feature"'
}

# ---------------------------------------------------------------------------
# --remove-worktree flag
# ---------------------------------------------------------------------------

@test "kiro: --remove-worktree skips PR section" {
  run_task_done "$KIRO_TASK_DONE" --remove-worktree
  refute_output --partial "gh pr create"
  refute_output --partial "To create a PR"
}

@test "jira: --remove-worktree skips PR section" {
  run_task_done "$JIRA_TASK_DONE" --remove-worktree
  refute_output --partial "gh pr create"
}

@test "kiro: --remove-worktree --force skips all prompts" {
  run "$KIRO_TASK_DONE" --remove-worktree --force
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "kiro: --remove-worktree alone exits 0 without reading stdin" {
  # No --force, no piped input. Bug was that the "Remove worktree?" prompt
  # still fired and would hang reading stdin.
  run "$KIRO_TASK_DONE" --remove-worktree </dev/null
  assert_success
  refute_output --partial "Remove worktree and close tab?"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "jira: --remove-worktree alone exits 0 without reading stdin" {
  run "$JIRA_TASK_DONE" --remove-worktree </dev/null
  assert_success
  refute_output --partial "Remove worktree and close tab?"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

@test "kiro: removes worktree directory" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "kiro: deletes .info file after removal" {
  run_task_done "$KIRO_TASK_DONE" --force
  assert [ ! -f "$WORKTREE_BASE/.$SLUG.info" ]
}

@test "kiro: skips zellij close-tab when no radio session (no \$ZELLIJ env)" {
  # Without ZELLIJ + a session file with TAB_ID=, task-done now skips the
  # close-tab call entirely rather than falling back to the focused-tab
  # `close-tab` (#107). See task_done_close_tab.bats for the close path.
  run_task_done "$KIRO_TASK_DONE" --force
  assert_output --partial "Skipping zellij close-tab"
  run stub_calls zellij
  refute_output --partial "close-tab"
}

@test "kiro: no prompt when --force is set" {
  # With --force, should not block waiting for stdin
  run "$KIRO_TASK_DONE" --force
  assert_success
}

# ---------------------------------------------------------------------------
# Uncommitted changes warning
# ---------------------------------------------------------------------------

@test "kiro: warns about uncommitted changes" {
  echo "dirty" > "$WORKTREE_BASE/$SLUG/dirty.txt"
  git -C "$WORKTREE_BASE/$SLUG" add dirty.txt
  # Don't commit — leave staged

  run bash -c "echo y | $KIRO_TASK_DONE --force"
  assert_output --partial "Uncommitted changes"
}

# ---------------------------------------------------------------------------
# claude-notion task-done (identical logic to kiro — no Jira uppercase slug)
# ---------------------------------------------------------------------------

@test "claude-notion: fails when run from main repo" {
  cd "$MAIN_REPO"
  run "$CLAUDE_NOTION_TASK_DONE"
  assert_failure
  assert_output --partial "main repo"
}

@test "claude-notion: shows branch and base branch" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "Branch:   task/$SLUG"
  assert_output --partial "Base:     main"
}

@test "claude-notion: reads custom BASE_BRANCH from .info file" {
  printf 'BASE_BRANCH=develop\nSLUG=%s\nNOTION_URL=\n' "$SLUG" \
    > "$WORKTREE_BASE/.$SLUG.info"
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "Base:     develop"
}

@test "claude-notion: shows commit count ahead of base" {
  touch "$WORKTREE_BASE/$SLUG/newfile.txt"
  git -C "$WORKTREE_BASE/$SLUG" add newfile.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "add file"

  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "Commits ahead of main: 1"
}

@test "claude-notion: shows gh pr create with correct --base when no PR exists" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "gh pr create --base main --head task/$SLUG"
}

@test "claude-notion: shows existing PR URL instead of create command" {
  export GH_STUB_PR_URL="https://github.com/org/repo/pull/42"
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "PR: https://github.com/org/repo/pull/42"
  refute_output --partial "gh pr create"
}

@test "claude-notion: --remove-worktree skips PR section" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --remove-worktree
  refute_output --partial "gh pr create"
  refute_output --partial "To create a PR"
}

@test "claude-notion: --remove-worktree --force skips all prompts" {
  run "$CLAUDE_NOTION_TASK_DONE" --remove-worktree --force
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "claude-notion: --remove-worktree alone exits 0 without reading stdin" {
  run "$CLAUDE_NOTION_TASK_DONE" --remove-worktree </dev/null
  assert_success
  refute_output --partial "Remove worktree and close tab?"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "claude-notion: removes worktree directory" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "claude-notion: deletes .info file after removal" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert [ ! -f "$WORKTREE_BASE/.$SLUG.info" ]
}

@test "claude-notion: skips zellij close-tab when no radio session (no \$ZELLIJ env)" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_output --partial "Skipping zellij close-tab"
  run stub_calls zellij
  refute_output --partial "close-tab"
}

@test "claude-notion: no prompt when --force is set" {
  run "$CLAUDE_NOTION_TASK_DONE" --force
  assert_success
}

@test "claude-notion: warns about uncommitted changes" {
  echo "dirty" > "$WORKTREE_BASE/$SLUG/dirty.txt"
  git -C "$WORKTREE_BASE/$SLUG" add dirty.txt

  run bash -c "echo y | $CLAUDE_NOTION_TASK_DONE --force"
  assert_output --partial "Uncommitted changes"
}

# ---------------------------------------------------------------------------
# Local branch deletion after worktree removal
# ---------------------------------------------------------------------------

@test "kiro: deletes local branch when fully merged (no new commits)" {
  # Fresh branch with no commits ahead of main is trivially merged.
  run_task_done "$KIRO_TASK_DONE" --force
  assert_success
  assert_output --partial "Deleted local branch 'task/$SLUG'"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output ""
}

@test "kiro: keeps local branch when it has unmerged commits" {
  # Commit on the task branch — now it's ahead of main and not merged.
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_success
  assert_output --partial "still has unmerged commits"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output --partial "task/$SLUG"
}

@test "jira: deletes local branch when fully merged (no new commits)" {
  run_task_done "$JIRA_TASK_DONE" --force
  assert_success
  assert_output --partial "Deleted local branch 'task/$SLUG'"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output ""
}

@test "jira: keeps local branch when it has unmerged commits" {
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done "$JIRA_TASK_DONE" --force
  assert_success
  assert_output --partial "still has unmerged commits"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output --partial "task/$SLUG"
}

@test "claude-notion: deletes local branch when fully merged (no new commits)" {
  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
  assert_success
  assert_output --partial "Deleted local branch 'task/$SLUG'"
  run git -C "$MAIN_REPO" branch --list "task/$SLUG"
  assert_output ""
}

@test "claude-notion: keeps local branch when it has unmerged commits" {
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
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

@test "kiro: removes worktree containing initialized submodules without warning" {
  add_submodule_to_worktree "$WORKTREE_BASE/$SLUG"

  run_task_done "$KIRO_TASK_DONE" --force
  assert_success
  refute_output --partial "could not remove worktree cleanly"
  refute_output --partial "removal failed"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "jira: removes worktree containing initialized submodules without warning" {
  add_submodule_to_worktree "$WORKTREE_BASE/$SLUG"

  run_task_done "$JIRA_TASK_DONE" --force
  assert_success
  refute_output --partial "could not remove worktree cleanly"
  refute_output --partial "removal failed"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}

@test "claude-notion: removes worktree containing initialized submodules without warning" {
  add_submodule_to_worktree "$WORKTREE_BASE/$SLUG"

  run_task_done "$CLAUDE_NOTION_TASK_DONE" --force
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
# task-done removes it. Uses the real radio binary on PATH and an isolated
# $TASK_FORCE_HOME tempdir so the host's session dir is untouched.
assert_task_done_unregisters() {
  local script="$1"
  local role="worker-task-force-$SLUG"

  setup_task_force_home
  cp "$RADIO" "$STUB_BIN/radio"
  chmod +x "$STUB_BIN/radio"
  export TASK_FORCE_ROLE="$role"

  "$RADIO" register --role "$role" --tab "$role" --agent claude --loadout claude-gh
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]

  run bash -c "echo y | $script --force"
  assert_success
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]
}

@test "kiro: task-done unregisters the radio session" {
  assert_task_done_unregisters "$KIRO_TASK_DONE"
}

@test "jira: task-done unregisters the radio session" {
  assert_task_done_unregisters "$JIRA_TASK_DONE"
}

@test "claude-notion: task-done unregisters the radio session" {
  assert_task_done_unregisters "$CLAUDE_NOTION_TASK_DONE"
}

@test "claude-gh: task-done unregisters the radio session" {
  assert_task_done_unregisters "$CLAUDE_GH_TASK_DONE"
}

@test "kiro-gh: task-done unregisters the radio session" {
  assert_task_done_unregisters "$KIRO_GH_TASK_DONE"
}

@test "claude-local: task-done unregisters the radio session" {
  assert_task_done_unregisters "$CLAUDE_LOCAL_TASK_DONE"
}

@test "kiro-local: task-done unregisters the radio session" {
  assert_task_done_unregisters "$KIRO_LOCAL_TASK_DONE"
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
  local script="$1"
  setup_reviewer_worktree 42
  cd "$WORKTREE_BASE/$RSLUG"

  run "$script" --remove-worktree --force
  assert_success
  assert_output --partial "Deleted reviewer branch 'task/$RSLUG'"
  refute_output --partial "still has unmerged commits"
  run git -C "$MAIN_REPO" branch --list "task/$RSLUG"
  assert_output ""
}

@test "claude-gh: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$CLAUDE_GH_TASK_DONE"
}

@test "claude-jira: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$JIRA_TASK_DONE"
}

@test "claude-notion: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$CLAUDE_NOTION_TASK_DONE"
}

@test "claude-local: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$CLAUDE_LOCAL_TASK_DONE"
}

@test "kiro-gh: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$KIRO_GH_TASK_DONE"
}

@test "kiro: (kiro-notion) reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$KIRO_TASK_DONE"
}

@test "kiro-local: reviewer worktree force-deletes branch (PR_NUMBER set)" {
  assert_reviewer_branch_force_deleted "$KIRO_LOCAL_TASK_DONE"
}

@test "claude-gh: worker worktree (no PR_NUMBER) still uses safe-delete -d" {
  # Regression: BASE_BRANCH set, PR_NUMBER absent → unmerged commits leave the
  # branch behind with the manual-cleanup message, unchanged from pre-#148.
  touch "$WORKTREE_BASE/$SLUG/unmerged.txt"
  git -C "$WORKTREE_BASE/$SLUG" add unmerged.txt
  git -C "$WORKTREE_BASE/$SLUG" commit -q -m "unmerged work"

  run_task_done "$CLAUDE_GH_TASK_DONE" --force
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
  local script="$1"

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
  assert_ambient_pr_number_does_not_force_delete "$CLAUDE_GH_TASK_DONE"
}

@test "claude-local: ambient PR_NUMBER export does NOT trigger force-delete on worker" {
  # Cross-drift-group coverage — the zero-init lives in worktree-context which
  # task-done-std and task-done-local check separately.
  assert_ambient_pr_number_does_not_force_delete "$CLAUDE_LOCAL_TASK_DONE"
}

@test "task-done cleanup tolerates radio binary missing from PATH (#94)" {
  # The `|| true` safety net: if radio isn't installed (or PATH doesn't
  # include it), cleanup must still succeed.
  setup_task_force_home
  export TASK_FORCE_ROLE="worker-task-force-$SLUG"
  # Note: deliberately do NOT install radio into $STUB_BIN here.

  run bash -c "echo y | $CLAUDE_GH_TASK_DONE --force"
  assert_success
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
}
