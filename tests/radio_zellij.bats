#!/usr/bin/env bats
# Integration tests for bin/radio against a mocked zellij stub. Asserts that
# `radio send` calls `zellij action go-to-tab-name <tab>` then
# `zellij action write-chars "radio check\n"` when the recipient is idle, and
# does NOT call zellij when the recipient is busy.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session-name
}

teardown() {
  teardown_all
}

# ----- idle: should focus tab + write "radio check\n" ----------------------

@test "send to idle recipient calls go-to-tab-name and write-chars" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  assert_stub_called zellij "action go-to-tab-name pm"
  assert_stub_called zellij "action write-chars radio check"
}

# ----- busy: no zellij calls at all ----------------------------------------

@test "send to busy recipient does not call zellij" {
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
  refute_output --partial "go-to-tab-name"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}
