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

# ----- delivered: sender is told the wake landed (#166) ---------------------

@test "send to idle recipient prints the delivered outcome on stdout (#166)" {
  # pm registered with tab_id=7; a successful write-chars must report back so
  # the sending agent knows the ping actually woke pm (not just queued).
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
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

@test "send queues silently when recipient's tab has no writable panes (#102)" {
  # Register pm so TAB_ID=7 is captured, then wipe the panes fixture so the
  # `list-panes --json --tab` lookup returns []. The session file's TAB_ID=
  # is still resolvable on paper, but there's no pane to write to — this is
  # the "zellij tab was closed out from under us" case. Wake-up must queue
  # rather than fall through to a focused-tab write.
  "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_PANES_JSON='[]'

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"

  # Idle recipient but no pane to wake → honest queued/idle-wake-failed line (#166).
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (no writable pane on its tab)"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no writable pane on tab_id=7"
}
