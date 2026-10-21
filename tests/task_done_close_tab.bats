#!/usr/bin/env bats
# Tests for task-done's close-tab step (#107).
#
# Background: task-done used to end with the unscoped `zellij action close-tab`,
# which targets the *focused* tab. If the user switched focus to a different
# tab (e.g. PM) while cleanup was running, the wrong tab got closed —
# destroying an active session. This is the same focused-tab bug class we
# fixed for `radio` in #102/#103, in a separate binary.
#
# The fix is to drive close-tab by the worker's stable zellij tab_id, which
# `radio register` already persists into the session file as TAB_ID= (#103).
# task-done captures TAB_ID *before* `radio unregister` wipes the session
# file, then uses `zellij action close-tab-by-id <id>` at the end.
#
# All four acceptance scenarios from the spec are covered below against the
# canonical bin/task-done, pinned to claude-gh. Pinning any loadout would do:
# close-tab lives in the shared body and there is no tracker or agent hook
# anywhere near it, so since #236 there is exactly one copy to get right. The
# six drift-manifest entries that used to hold the other loadouts byte-identical
# here are retired along with their files.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SLUG="my-feature"
ROLE="worker-task-force-$SLUG"

setup() {
  setup_repo
  setup_stubs
  setup_worktree "$SLUG"
  setup_task_force_home
  cd "$WORKTREE_BASE/$SLUG"
  # Make the real radio binary available so the unregister step inside
  # task-done's cleanup region runs against it (matches assert_task_done_unregisters
  # in task_done.bats). TAB_ID capture in task-done happens *before*
  # unregister deletes the session file.
  cp "$RADIO" "$STUB_BIN/radio"
  chmod +x "$STUB_BIN/radio"
}

teardown() {
  [[ -z "${NOJQ_PATH_DIR:-}" ]] || rm -rf "$NOJQ_PATH_DIR"
  teardown_all
}

# A PATH that is the current one with jq taken out: one directory of symlinks to
# every command on $PATH except jq, first hit winning as it would on $PATH.
# task-done needs git, the stubs and most of coreutils, so the bash+coreutils
# make_nojq_bin is too small here.
path_without_jq() {
  local d dir f name
  d=$(mktemp -d)
  local IFS=:
  for dir in $PATH; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*; do
      name=${f##*/}
      [[ "$name" == jq || -e "$d/$name" || ! -x "$f" ]] && continue
      ln -s "$f" "$d/$name"
    done
  done
  printf '%s' "$d"
}

# Write a session file with the given TAB_ID= value (empty allowed) at the
# location task-done's TAB_ID-capture block reads from.
write_session_file() {
  local tab_id="$1"
  mkdir -p "$TASK_FORCE_HOME/radio/sessions"
  printf 'ROLE=%s\nTAB=%s\nTAB_ID=%s\nREPO=test\nSTATE=idle\nLAST_HEARTBEAT=2020-01-01T00:00:00Z\nAGENT=claude\nLOADOUT=claude-gh\n' \
    "$ROLE" "$ROLE" "$tab_id" \
    > "$TASK_FORCE_HOME/radio/sessions/$ROLE.info"
}

# Append TAB_ID= to the worktree's $INFO_FILE. setup_worktree pre-seeds the
# file with BASE_BRANCH/SLUG/NOTION_URL; the Layer 2 task-work change appends
# TAB_ID= after the tab is opened, so the file ends up with TAB_ID as the
# last line (which is what task-done's awk parser picks up by exit-on-first-
# match).
write_info_tab_id() {
  local tab_id="$1"
  printf 'TAB_ID=%s\n' "$tab_id" >> "$WORKTREE_BASE/.$SLUG.info"
}

# Seed the zellij stub's list-tabs with one tab per "<id>:<name>" argument.
# task-done reads it to confirm the tab at TAB_ID is still this worker's before
# closing it (#260), so every test that expects a close has to say what tab
# that id belongs to.
seed_tabs() {
  local entries='' pair
  for pair in "$@"; do
    [[ -z "$entries" ]] || entries+=','
    entries+="{\"name\": \"${pair#*:}\", \"tab_id\": ${pair%%:*}}"
  done
  export STUB_ZELLIJ_TABS_JSON="[${entries}]"
}

# Returns the set of close-tab-flavored calls made against the zellij stub,
# one per line.
zellij_close_calls() {
  grep -E '^zellij action close-tab' "$STUB_CALLS_DIR/zellij.calls" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Acceptance #1: worker tab focused → close-tab-by-id with worker's tab_id
# ---------------------------------------------------------------------------

@test "close-tab uses worker's TAB_ID (worker tab focused)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_session_file 7
  seed_tabs "7:$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  # Per-id close lands on the worker's persisted tab_id.
  assert_stub_called zellij "action close-tab-by-id 7"
  # And the unscoped, focused-tab form must never fire — that's the #107 bug.
  run zellij_close_calls
  refute_output --partial "action close-tab"$'\n'
  assert_output --partial "action close-tab-by-id 7"
}

# ---------------------------------------------------------------------------
# Acceptance #2: other tab focused → close-tab-by-id STILL with worker's id
#
# The regression scenario. With per-id targeting, focus state is irrelevant
# at call time — task-done captured TAB_ID at register, persisted across
# any focus changes the user makes during cleanup. The seeded zellij fixture
# advertises a *different* tab as focused; task-done must still close the
# worker's tab (id=7), not the focused one (id=99).
# ---------------------------------------------------------------------------

@test "close-tab uses worker's TAB_ID even when another tab is focused (#107 regression)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_session_file 7
  # Seed the stub so list-tabs/list-panes would report a different,
  # currently-focused tab (id=99). With the bug, an unscoped `close-tab`
  # would have hit that one; with the fix, we still close 7.
  seed_tabs "99:pm" "7:$SLUG"
  export STUB_ZELLIJ_PANES_JSON='[{"id":9900,"is_plugin":false,"is_focused":true,"tab_id":99}]'

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 7"
  # Defense in depth: assert the close call was by id 7, not id 99 or
  # an unscoped form.
  run zellij_close_calls
  refute_output --partial "close-tab-by-id 99"
  refute_output --partial "action close-tab"$'\n'
}

# ---------------------------------------------------------------------------
# Acceptance #3: missing TAB_ID → no zellij close-tab call, exit 0
# ---------------------------------------------------------------------------

@test "close-tab is skipped when TAB_ID= is empty in the session file" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_session_file ""   # TAB_ID= present but empty

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Skipping zellij close-tab"
  # Worktree cleanup still completes.
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
  run zellij_close_calls
  assert_output ""
}

# ---------------------------------------------------------------------------
# Acceptance #4: missing session file → no zellij close-tab call, exit 0
# ---------------------------------------------------------------------------

@test "close-tab is skipped when the radio session file is missing" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  # Deliberately do NOT create the session file.

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Skipping zellij close-tab"
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
  run zellij_close_calls
  assert_output ""
}

# ---------------------------------------------------------------------------
# Defense in depth: $ZELLIJ unset path (e.g., plain shell or CI) — also
# covered by the updated tests in task_done.bats, but re-asserted here so
# all close-tab edge cases are documented in one place.
# ---------------------------------------------------------------------------

@test "close-tab is skipped when \$ZELLIJ is unset (non-zellij shell / CI)" {
  unset ZELLIJ || true
  export TASK_FORCE_ROLE="$ROLE"
  write_session_file 7

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Skipping zellij close-tab"
  run zellij_close_calls
  assert_output ""
}

# ---------------------------------------------------------------------------
# Layer 2: $INFO_FILE is the authoritative TAB_ID source (#117)
#
# task-work now writes TAB_ID= into $INFO_FILE at tab-creation time, where
# the radio binary never touches it. task-done reads from $INFO_FILE first
# and only falls back to the radio session file. This protects close-tab
# from any mid-session SessionStart re-register that clobbered the radio
# session file's TAB_ID — the #117 regression scenario.
# ---------------------------------------------------------------------------

@test "close-tab prefers \$INFO_FILE TAB_ID over the radio session file (#117)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  # Simulate the #117 mid-life clobber: radio session file's TAB_ID was
  # wiped to empty by a re-register, but $INFO_FILE still has the right id.
  write_info_tab_id 12
  write_session_file ""
  seed_tabs "12:$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 12"
  run zellij_close_calls
  refute_output --partial "action close-tab"$'\n'
}

@test "close-tab falls back to radio session file when \$INFO_FILE has no TAB_ID (pre-fix worker)" {
  # Worker started before the Layer 2 task-work change → $INFO_FILE doesn't
  # carry TAB_ID. task-done should still recover the id via the radio
  # session file (Layer 2 fallback).
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  # Do NOT call write_info_tab_id — $INFO_FILE has BASE_BRANCH/SLUG only.
  write_session_file 7
  seed_tabs "7:$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 7"
}

@test "close-tab uses \$INFO_FILE TAB_ID even when the radio session file is missing entirely (#117)" {
  # Defense in depth: \$INFO_FILE alone is enough to close the right tab.
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 12
  seed_tabs "12:$SLUG"
  # No write_session_file call → no radio session file on disk.

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 12"
}

# ---------------------------------------------------------------------------
# A stale TAB_ID must not close somebody else's tab (#260)
#
# 2026-10-18: zellij restarted and renumbered its tabs. A worker resumed in
# place kept its sidecar's TAB_ID=2; a new worker launched afterwards got id 2;
# the old worker's task-done then closed the new worker's tab by that id. A tab
# id is only valid within one zellij server's lifetime, so task-done now checks
# the name of the tab at that id before acting on it.
# ---------------------------------------------------------------------------

@test "a stale TAB_ID naming another worker's tab is not closed (#260)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 2
  # Our own tab came back as id 1; id 2 is now an unrelated worker's.
  seed_tabs "1:⏸️ $SLUG" "2:▶️ model-defaults"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Not closing zellij tab id=2: it is now '▶️ model-defaults', not '$SLUG'"
  # Cleanup itself still completes.
  assert [ ! -d "$WORKTREE_BASE/$SLUG" ]
  run zellij_close_calls
  assert_output ""
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "tab-close: id 2 is now ▶️ model-defaults, not $SLUG"
}

@test "an emoji-prefixed name of this worker's own slug still matches (#260)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 4
  seed_tabs "4:⏸️ $SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 4"
}

@test "a tab whose name merely ends in the slug's characters is not ours (#260)" {
  # Match on the space-delimited tail, not on a raw suffix: `not-my-feature`
  # ends in `my-feature` but belongs to a different worker.
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 5
  seed_tabs "5:▶️ not-$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Not closing zellij tab id=5"
  run zellij_close_calls
  assert_output ""
}

@test "a TAB_ID no tab holds any more is not closed (#260)" {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 9
  seed_tabs "1:pm" "2:$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "no tab has id=9 any more"
  run zellij_close_calls
  assert_output ""
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "tab-close: id 9 is gone"
}

@test "an id that cannot be verified (list-tabs returns nothing) is not closed (#260)" {
  # Refusing is the safe direction: a tab left open costs a keystroke, closing
  # the wrong one kills a session.
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 7
  unset STUB_ZELLIJ_TABS_JSON

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "could not list zellij tabs to confirm tab id=7"
  assert_output --partial "list-tabs --json returned nothing parseable"
  refute_output --partial "jq is not installed"
  run zellij_close_calls
  assert_output ""
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "tab-close: id 7 unverified (list-tabs unreadable)"
}

@test "with jq missing the id is not closed, and the refusal says jq is why (#260)" {
  # Fails closed exactly like an unreadable list-tabs, so the message has to say
  # which it was or "jq is not installed" reads as "zellij is broken".
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 7
  seed_tabs "7:$SLUG"   # would verify fine — if jq were there to read it
  NOJQ_PATH_DIR=$(path_without_jq)
  run env PATH="$NOJQ_PATH_DIR" bash -c 'command -v jq'
  assert_failure

  run env PATH="$NOJQ_PATH_DIR" AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "jq is not installed"
  run zellij_close_calls
  assert_output ""
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "tab-close: id 7 unverified (no-jq)"
}

# ---------------------------------------------------------------------------
# A worktree that vanished before task-done ran (#271)
#
# `gh pr merge --delete-branch` (gh 2.101) deletes the local branch and, when a
# worktree has it checked out, the worktree too. The worker then drains
# `approved-and-merged` from a cwd that no longer exists, and every git call in
# task-done used to fail there — leaving the tab, the radio session and the
# mailbox behind. These live here rather than in task_done.bats because what
# they have to prove is precisely the tab / session / mailbox cleanup.
# ---------------------------------------------------------------------------

# Do what gh does: remove the worktree and its branch from the main checkout,
# while the test's own cwd is still inside the worktree.
vanish_worktree() {
  git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_BASE/$SLUG"
  git -C "$MAIN_REPO" branch -D -q "task/$SLUG"
}

# Seed every piece of state a live worker leaves behind.
seed_live_worker_state() {
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$1"
  write_info_tab_id 7
  seed_tabs "1:pm" "7:$SLUG"
  mkdir -p "$TASK_FORCE_HOME/radio/sessions" "$TASK_FORCE_HOME/radio/mailbox/$1/inbox"
  printf 'ROLE=%s\nTAB_ID=7\n' "$1" > "$TASK_FORCE_HOME/radio/sessions/$1.info"
  printf 'approved-and-merged\n' > "$TASK_FORCE_HOME/radio/mailbox/$1/inbox/msg.md"
}

# mktemp names the fixture repo `tmp.XXXX`, and radio rejects a role with a dot
# in it — so would the mailbox sweep — which would leave a role-derived test
# unable to prove the session and mailbox went. Rebuild the fixture under a
# dot-free name for the tests whose role embeds $REPO_NAME.
use_dotless_repo() {
  git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_BASE/$SLUG"
  rm -rf "$WORKTREE_BASE"
  local renamed="${MAIN_REPO%/*}/$(basename "$MAIN_REPO" | tr . -)"
  mv "$MAIN_REPO" "$renamed"
  MAIN_REPO="$renamed"
  REPO_NAME=$(basename "$MAIN_REPO")
  WORKTREE_BASE="${MAIN_REPO}/../${REPO_NAME}-worktrees"
  git -C "$MAIN_REPO" branch -D -q "task/$SLUG"
  setup_worktree "$SLUG"
}

assert_leftovers_cleaned() {
  local role="$1"
  assert_stub_called zellij "action close-tab-by-id 7"
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/$role" ]
  assert [ ! -f "$WORKTREE_BASE/.$SLUG.info" ]
}

@test "task-done run from a vanished worktree cwd still cleans up tab, session, mailbox and sidecar (#271)" {
  seed_live_worker_state "$ROLE"
  vanish_worktree
  [[ ! -d "$PWD" ]]

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "This worktree no longer exists"
  assert_output --partial "Local branch 'task/$SLUG' is already gone"
  refute_output --partial "not in a git repo"
  assert_leftovers_cleaned "$ROLE"
}

@test "a vanished worktree whose registration git still holds is pruned (#271)" {
  # rm -rf rather than `git worktree remove`: the registration survives it.
  seed_live_worker_state "$ROLE"
  rm -rf "${WORKTREE_BASE:?}/$SLUG"
  run git -C "$MAIN_REPO" worktree list --porcelain
  assert_output --partial "/$SLUG"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  run git -C "$MAIN_REPO" worktree list --porcelain
  refute_output --partial "/$SLUG"
  # The branch survived an rm -rf, so the normal safe delete applies to it.
  run git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/task/$SLUG"
  assert_failure
}

@test "from the main checkout, a worker role whose worktree vanished is cleaned up (#271)" {
  # An agent harness resets a shell whose cwd is gone, so the worker may be
  # dropped back into the main checkout before it ever runs task-done.
  use_dotless_repo
  local role="worker-$REPO_NAME-$SLUG"
  seed_live_worker_state "$role"
  vanish_worktree
  cd "$MAIN_REPO"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "This worktree no longer exists"
  refute_output --partial "you're in the main repo"
  assert_leftovers_cleaned "$role"
}

@test "from the main checkout, a worker role whose worktree still exists is refused as before (#271)" {
  local role="worker-$REPO_NAME-$SLUG"
  seed_live_worker_state "$role"
  cd "$MAIN_REPO"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_failure
  assert_output --partial "you're in the main repo"
  assert [ -d "$WORKTREE_BASE/$SLUG" ]
  run zellij_close_calls
  assert_output ""
}

@test "from the main checkout, a role naming a worktree that never existed is refused (#271)" {
  # No sidecar and no registration: nothing says this was ever a worktree, so
  # there is nothing of ours to clean up.
  local role="worker-$REPO_NAME-never-was"
  export TASK_FORCE_ROLE="$role"
  cd "$MAIN_REPO"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_failure
  assert_output --partial "you're in the main repo"
}

@test "a vanished cwd outside any <repo>-worktrees directory is refused, not guessed at (#271)" {
  local gone
  gone=$(mktemp -d)
  cd "$gone"
  rmdir "$gone"

  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_failure
  assert_output --partial "no longer exists, and it is not a task-work worktree"
}
