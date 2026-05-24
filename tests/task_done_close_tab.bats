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
# All four acceptance scenarios from the spec are covered below against
# claude-gh/bin/task-done. Drift check (tools/check-drift.sh) keeps the
# other 6 loadouts byte-identical in the templated region.

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
  teardown_all
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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
  export STUB_ZELLIJ_TABS_JSON='[{"name":"pm","tab_id":99}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id":9900,"is_plugin":false,"is_focused":true,"tab_id":99}]'

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
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

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 7"
}

@test "close-tab uses \$INFO_FILE TAB_ID even when the radio session file is missing entirely (#117)" {
  # Defense in depth: \$INFO_FILE alone is enough to close the right tab.
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE="$ROLE"
  write_info_tab_id 12
  # No write_session_file call → no radio session file on disk.

  run "$CLAUDE_GH_TASK_DONE" --remove-worktree --force
  assert_success
  assert_stub_called zellij "action close-tab-by-id 12"
}
