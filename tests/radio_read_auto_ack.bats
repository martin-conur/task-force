#!/usr/bin/env bats
# Pins the read+ack collapse contract from #131.
# - `radio read <id>`         => print body AND mv inbox -> processed
# - `radio read --peek <id>`  => print body, leave file in inbox
# - `radio read --no-ack <id>` => same as --peek (alias)
# - `radio ack <id>` on an already-processed message => exit 0, friendly note
# - `radio read` of a message already in processed/ still prints (no move, no error)

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ
  export TASK_FORCE_ROLE=test-runner
  "$RADIO" register --role pm --tab pm --agent claude
}

teardown() {
  teardown_all
}

# Helper: send one message to pm and echo its id (basename without .md).
_send_one() {
  local intent="${1:-review-requested}"
  local body="${2:-Body content}"
  # Discard send's stdout — since #166 it prints a delivery-outcome line, and
  # this helper's own stdout must be *only* the queued message id.
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent "$intent" --body "$body" >/dev/null
  basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)" .md
}

@test "(a) read auto-acks: body prints AND file moves inbox -> processed" {
  local id
  id=$(_send_one review-requested "Auto-ack me")

  TASK_FORCE_ROLE=pm run "$RADIO" read "$id"
  assert_success
  assert_output --partial "Auto-ack me"

  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]

  # Regression of #131 root cause: subsequent check returns (no unread).
  TASK_FORCE_ROLE=pm run "$RADIO" check
  assert_output --partial "(no unread messages)"
}

@test "(b) read --peek prints body and leaves file in inbox" {
  local id
  id=$(_send_one review-requested "Peek me")

  TASK_FORCE_ROLE=pm run "$RADIO" read --peek "$id"
  assert_success
  assert_output --partial "Peek me"

  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]

  # check still lists it
  TASK_FORCE_ROLE=pm run "$RADIO" check
  assert_output --partial "Peek me"
}

@test "(c) read --no-ack is a strict alias for --peek (no move)" {
  local id
  id=$(_send_one review-requested "No-ack me")

  TASK_FORCE_ROLE=pm run "$RADIO" read --no-ack "$id"
  assert_success
  assert_output --partial "No-ack me"

  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]
}

@test "(d) ack on an already-processed id is idempotent (exit 0, friendly note)" {
  local id
  id=$(_send_one review-requested "Ack twice")

  # First read auto-acks.
  TASK_FORCE_ROLE=pm "$RADIO" read "$id"
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]

  # Legacy `ack` call should now no-op cleanly instead of erroring.
  TASK_FORCE_ROLE=pm run "$RADIO" ack "$id"
  assert_success
  assert_output --partial "already processed"
}

@test "(e) read of a message already in processed/ still prints (no move, no error)" {
  local id
  id=$(_send_one review-requested "Read me twice")

  # First read auto-acks (moves to processed/).
  TASK_FORCE_ROLE=pm "$RADIO" read "$id" >/dev/null

  # Second read still finds the body in processed/ — no error, no move (it's
  # already there), nothing to log a second time.
  TASK_FORCE_ROLE=pm run "$RADIO" read "$id"
  assert_success
  assert_output --partial "Read me twice"
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
}

@test "ack on a truly-unknown id still errors loudly" {
  TASK_FORCE_ROLE=pm run "$RADIO" ack "never-sent-this"
  assert_failure
  assert_output --partial "not in inbox"
}

@test "read flag accepted both before and after id" {
  local id
  id=$(_send_one review-requested "Flag position")

  TASK_FORCE_ROLE=pm run "$RADIO" read "$id" --peek
  assert_success
  assert_output --partial "Flag position"
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
}

@test "wrong-role read does not affect target role's inbox (#131 isolation pin)" {
  local id
  id=$(_send_one review-requested "Body for pm")

  # Register a second role and try reading pm's message as that role.
  "$RADIO" register --role worker-bar --tab w-bar --agent claude
  TASK_FORCE_ROLE=worker-bar run "$RADIO" read "$id"
  assert_failure
  assert_output --partial "not found"

  # pm's message is untouched.
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
}
