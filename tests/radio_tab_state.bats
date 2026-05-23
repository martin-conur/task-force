#!/usr/bin/env bats
# Tests for _rename_tab — the idle/busy emoji prefix on the zellij tab name
# and the matching TAB= sync in the session file (#95). Post-#102, the
# rename is scoped to the role's stable tab id (`rename-tab-by-id`) instead
# of the focused tab, so we assert against the seeded fixture's id.
#
# `_rename_tab` is a private helper; we exercise it indirectly through
# `radio register` (first-paint idle prefix) and `radio busy` / `radio ready`
# (state-driven flips). The zellij stub records every invocation so we can
# assert that rename-tab-by-id fires with the expected emoji-prefixed name.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# The visible-name emojis. Kept as constants so the assertions read clearly
# and we don't repeat the literal UTF-8 sequences across cases.
PAUSE='⏸️ '
PLAY='▶️ '
WAIT='❓︎ '

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  # Bypass the no-role dispatcher gate on `register` (#93); per-test overrides
  # set TASK_FORCE_ROLE where the value matters.
  export TASK_FORCE_ROLE=test-runner
  # The $ZELLIJ_TAB safeguard in _rename_tab compares against TAB= and bails
  # on a mismatch; we don't want the dev shell's inherited value to fire it
  # for tests that aren't exercising the safeguard explicitly.
  unset ZELLIJ_TAB
  # pm gets tab_id=7, pane_id=700.
  seed_zellij_tabs pm
}

teardown() {
  teardown_all
}

# ----- no-op paths ----------------------------------------------------------

@test "register: no rename when \$ZELLIJ is unset" {
  unset ZELLIJ
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run stub_calls zellij
  refute_output --partial "rename-tab"
  # And TAB= stays at the bare slug.
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=pm"
}

@test "register: no rename when zellij is not on PATH" {
  # Drop the stub dir from PATH so `command -v zellij` fails.
  PATH="/usr/bin:/bin" TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run stub_calls zellij
  refute_output --partial "rename-tab"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=pm"
}

@test "busy/ready: no rename when session file has no TAB= field" {
  # Hand-craft a session file with no TAB= line.
  mkdir -p "$TASK_FORCE_HOME/radio/sessions"
  printf 'ROLE=pm\nSTATE=idle\nLAST_HEARTBEAT=2020-01-01T00:00:00Z\nAGENT=claude\nLOADOUT=\n' \
    > "$TASK_FORCE_HOME/radio/sessions/pm.info"
  TASK_FORCE_ROLE=pm "$RADIO" busy
  run stub_calls zellij
  refute_output --partial "rename-tab"
}

@test "busy/ready: rename still works when list-tabs would now be empty (TAB_ID= drives it)" {
  # With TAB_ID= captured at register, subsequent flips no longer need to
  # query list-tabs at all — they use the persisted id directly. This is
  # the key invariant from the #102 review: stale or missing list-tabs
  # output must not break wake-ups on a tab that still exists.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_TABS_JSON='[]'
  TASK_FORCE_ROLE=pm "$RADIO" busy
  # Two rename-tab-by-id calls landed on the same persisted tab_id=7
  # (one at register first-paint, one for the busy flip).
  run bash -c "grep -c 'action rename-tab-by-id 7' '$STUB_CALLS_DIR/zellij.calls'"
  assert_output "2"
}

# ----- first paint at register ---------------------------------------------

@test "register paints the idle prefix on the role's tab id and syncs TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  # Per-tab API targets the role's stable id, not the focused tab.
  assert_stub_called zellij "action rename-tab-by-id 7 ${PAUSE}pm"
  # No focus-changing call sneaks through.
  run stub_calls zellij
  refute_output --partial "action rename-tab "    # the old, unsafe form
  refute_output --partial "go-to-tab-name"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- busy / ready flips ---------------------------------------------------

@test "busy flips tab to the play prefix and updates TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  assert_stub_called zellij "action rename-tab-by-id 7 ${PLAY}pm"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PLAY}pm"
}

@test "ready flips tab back to the pause prefix and updates TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- no prefix stacking ---------------------------------------------------

@test "consecutive idle→busy→idle flips do not stack emoji prefixes" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready

  # Final TAB= should be exactly "<pause> pm", not "<pause><play> pm" etc.
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"

  # And the most recent rename-tab-by-id call should target the same name.
  run bash -c "grep 'rename-tab-by-id' '$STUB_CALLS_DIR/zellij.calls' | tail -1"
  assert_output "zellij action rename-tab-by-id 7 ${PAUSE}pm"
}

# ----- TAB= sync keeps wake-up working --------------------------------------

@test "send finds the recipient's tab after rename (TAB= sync verified)" {
  # Register pm — first-paint rewrites TAB= to "<pause> pm". The seeded
  # fixture maps both `pm` and `⏸️ pm` to tab_id=7 (pane_id=700), so the
  # post-rename TAB= still resolves.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude

  # Worker sends to pm; wake-up reads TAB= from pm.info, resolves tab_id=7,
  # picks pane_id=700, and writes "radio check" there. If TAB= sync were
  # broken the lookup against `pm` (no prefix) would still hit tab_id=7 thanks
  # to the multi-name fixture, so the assertion below is the real signal
  # that wake-up uses the renamed name.
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

# ----- $ZELLIJ_TAB safeguard (#102 defense in depth) -----------------------

@test "_rename_tab skips when \$ZELLIJ_TAB names a different tab than the role's" {
  # Simulate `TASK_FORCE_ROLE=pm radio ready` invoked from a worker's pane:
  # the caller's $ZELLIJ_TAB points at the worker's slug, but the role is pm.
  # Even if the per-tab API call below were to regress to focused-tab
  # behaviour, the safeguard skips the rename outright.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  # Clear the call log so the assertion below is unambiguous.
  : > "$STUB_CALLS_DIR/zellij.calls"
  ZELLIJ_TAB=worker-foo TASK_FORCE_ROLE=pm "$RADIO" busy
  run stub_calls zellij
  refute_output --partial "rename-tab-by-id"
  # The state update still went through.
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=busy"
}

@test "_rename_tab proceeds when \$ZELLIJ_TAB matches the role's bare slug" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  ZELLIJ_TAB=pm TASK_FORCE_ROLE=pm "$RADIO" busy
  assert_stub_called zellij "action rename-tab-by-id 7 ${PLAY}pm"
}

# ----- awaiting state (#106) ------------------------------------------------

@test "awaiting writes STATE=awaiting and paints the question-mark prefix" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=awaiting"
  assert_stub_called zellij "action rename-tab-by-id 7 ${WAIT}pm"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${WAIT}pm"
}

@test "busy → awaiting → busy round-trip strips and repaints cleanly" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  TASK_FORCE_ROLE=pm "$RADIO" busy

  # Final TAB= should be exactly "<play> pm", not "<play><question> pm" etc.
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PLAY}pm"

  # And the most recent rename-tab-by-id call should target the same name.
  run bash -c "grep 'rename-tab-by-id' '$STUB_CALLS_DIR/zellij.calls' | tail -1"
  assert_output "zellij action rename-tab-by-id 7 ${PLAY}pm"
}

@test "awaiting → idle via cmd_ready paints the pause prefix" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  TASK_FORCE_ROLE=pm "$RADIO" ready
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=idle"
}

@test "awaiting → busy via cmd_busy paints the play prefix" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  TASK_FORCE_ROLE=pm "$RADIO" busy
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PLAY}pm"
}

@test "_rename_tab skips awaiting paint when \$ZELLIJ_TAB names a different tab" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"
  ZELLIJ_TAB=worker-foo TASK_FORCE_ROLE=pm "$RADIO" awaiting
  run stub_calls zellij
  refute_output --partial "rename-tab-by-id"
  # State update still went through.
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=awaiting"
}
