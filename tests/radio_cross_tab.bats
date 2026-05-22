#!/usr/bin/env bats
# Regression tests for #102 — both `_rename_tab` (state flips) and
# `cmd_send` (wake-up) must scope their zellij side-effects to the role's
# own tab, independent of whichever tab the user happens to have focused.
#
# Bug 1 (symptom 1 in the issue): with PM focused, a worker auto-unregister
# fires `radio ready` from the worker's pane. The pre-#102 code called
# `zellij action rename-tab "▶️ pm"` which targets the focused tab, so PM's
# tab name got clobbered. With per-tab targeting we should rename only the
# worker's own tab id.
#
# Bug 2 (symptom 2 in the issue): with worker-a focused, worker-b runs
# `radio send --to pm`. The pre-#102 code did `go-to-tab-name pm` +
# `write-chars`; the focus switch wasn't atomic and "radio check" could land
# on worker-a (or worker-b). With per-pane targeting the write goes to PM's
# pane regardless of who's focused.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

PAUSE='⏸️ '
PLAY='▶️ '

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE=test-runner
  # Don't let the dev shell's $ZELLIJ_TAB fire the _rename_tab safeguard
  # during the initial registers; the bug-1 test re-sets it per-call to
  # simulate worker-a's pane context.
  unset ZELLIJ_TAB
  # pm=tab 7 pane 700; worker-a=tab 8 pane 800; worker-b=tab 9 pane 900.
  seed_zellij_tabs pm worker-a worker-b
}

teardown() {
  teardown_all
}

# ----- Bug 1: rename does not leak to the focused tab ----------------------

@test "worker-a's ready/busy renames worker-a's tab id, never pm's (#102 bug 1)" {
  # Register both roles so each has a session file with TAB= set.
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  # Clear the call log so we only inspect what the worker's flip emits.
  : > "$STUB_CALLS_DIR/zellij.calls"

  # Simulate: user is focused on PM. Worker-a fires its ready hook from its
  # own pane (so ZELLIJ_TAB=worker-a per the env that task-work set on the
  # pane). The rename must hit tab_id=8 (worker-a), never tab_id=7 (pm).
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" busy

  run stub_calls zellij
  # Only the worker's tab id appears in any rename-tab-by-id call.
  assert_output --partial "action rename-tab-by-id 8 ${PLAY}worker-a"
  refute_output --partial "action rename-tab-by-id 7"
  # And the unsafe focused-tab form (`rename-tab <name>` with no `-by-id`)
  # never appears.
  run bash -c "grep -E 'action rename-tab [^-]' '$STUB_CALLS_DIR/zellij.calls' || true"
  assert_output ""
}

@test "pm.info TAB= is untouched when a different role's _rename_tab runs (#102 bug 1)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude

  # After both registers, both session files have TAB= set to their idle
  # paint. Now run the worker through busy → ready and verify pm's TAB=
  # never changes.
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" busy
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" ready

  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- Bug 2: wake-up does not leak to the focused tab ---------------------

@test "send writes 'radio check' to pm's pane regardless of which tab is focused (#102 bug 2)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  TASK_FORCE_ROLE=worker-b  "$RADIO" register --role worker-b  --tab worker-b  --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  # User focused on worker-a; worker-b runs `radio send --to pm`. The pane-id
  # write must target pm's pane (700), never worker-a's (800) or worker-b's
  # (900). And the previous focus-stealing `go-to-tab-name` must not appear.
  TASK_FORCE_ROLE=worker-b "$RADIO" send --to pm --intent review-requested --pr 1 --body "PR up"

  run stub_calls zellij
  assert_output --partial "action write-chars --pane-id 700 radio check"
  refute_output --partial "--pane-id 800"
  refute_output --partial "--pane-id 900"
  refute_output --partial "go-to-tab-name"
}

@test "send still no-ops to a busy recipient even with multiple workers focused (#102 bug 2)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=pm        "$RADIO" busy
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  TASK_FORCE_ROLE=worker-b  "$RADIO" register --role worker-b  --tab worker-b  --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-b "$RADIO" send --to pm --intent ping --body "queue"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  # Message still queued for pm.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}
