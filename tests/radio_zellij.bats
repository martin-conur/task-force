#!/usr/bin/env bats
# Integration tests for bin/radio against a mocked zellij stub. Asserts that
# `radio send` resolves the recipient's tab/pane and calls
# `zellij action write-chars --pane-id <pane> "radio check\n"` when the
# recipient is idle, without yanking the user's focus via `go-to-tab-name`
# (#102); and does NOT call zellij when the recipient is busy.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session-name
  # Bypass the no-role dispatcher gate on `register` (#93); tests still set
  # TASK_FORCE_ROLE per-invocation where the value matters.
  export TASK_FORCE_ROLE=test-runner
  # Don't let the dev shell's $ZELLIJ_TAB fire the _rename_tab safeguard
  # during the `radio register` call each test makes.
  unset ZELLIJ_TAB
  # pm gets tab_id=7, pane_id=700; worker-foo gets tab_id=8, pane_id=800.
  seed_zellij_tabs pm worker-foo
}

teardown() {
  teardown_all
}

# ----- idle: should write "radio check\n" straight to the recipient's pane --

@test "send to idle recipient writes 'radio check' to recipient's pane by id" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  # Per-pane write — no focus switch leaks across panes (#102).
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
  run stub_calls zellij
  refute_output --partial "go-to-tab-name"
}

# ----- busy: no zellij wake calls at all -----------------------------------

@test "send to busy recipient does not call zellij wake actions" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  run stub_calls zellij
  refute_output --partial "go-to-tab-name"
  refute_output --partial "write-chars"

  # And the message should still be queued for the recipient.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}

# ----- ZELLIJ unset: graceful no-op ----------------------------------------

@test "send is a silent no-op when \$ZELLIJ is unset (recipient still queues)" {
  unset ZELLIJ
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent ping --body "queue me"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}

# ----- recipient's tab no longer exists in zellij --------------------------

@test "send queues silently when recipient's tab cannot be resolved (#102)" {
  # Register pm, then wipe the tab fixture so list-tabs returns []. The
  # session file still claims TAB=⏸️ pm, but zellij no longer reports a
  # matching tab — this is the corrupted-state scenario the PM's repro
  # describes. Wake-up must skip rather than spray the focused tab.
  "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_TABS_JSON='[]'
  export STUB_ZELLIJ_PANES_JSON='[]'

  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "not found in zellij"
}
