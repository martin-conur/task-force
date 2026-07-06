#!/usr/bin/env bats
# Tests for `radio prompt-hook` (#164) — the UserPromptSubmit-hook entrypoint
# that replaces plain `radio busy`.
#
# Background: an idle agent fires no hooks, so if the send-time zellij wake
# fails (no writable pane, stale TAB_ID, missing session file) the queued
# message stays invisible until a later wake happens to succeed. Unlike Stop,
# a UserPromptSubmit hook's stdout IS injected into the model's context — so
# `radio prompt-hook` marks the role busy (preserving the old behavior) and
# prints a compact summary of any unread inbox, making every human prompt a
# reliable delivery point. Empty inbox prints nothing: zero context noise.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ                       # no wakeup attempts in unit tests
  export TASK_FORCE_ROLE=worker-foo
}

teardown() {
  teardown_all
}

# Queue one message into worker-foo's inbox without waking anyone
# ($ZELLIJ is unset, so cmd_send just writes the file).
_queue_message() {
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-foo --intent "${2:-changes-requested}" ${3:+--pr "$3"} ${4:+--issue "$4"} --body "${1:-fix the thing}"
}

# ----- no-role gate (#93 semantics) ------------------------------------------

@test "prompt-hook with no TASK_FORCE_ROLE is a silent exit 0 (plain claude session)" {
  run bash -c "echo '{}' | env -u TASK_FORCE_ROLE '$RADIO' prompt-hook"
  assert_success
  assert_output ""
}

# ----- busy transition (radio busy behavior preserved) ------------------------

@test "prompt-hook marks the role busy" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=busy"
}

# ----- empty inbox: zero context noise ----------------------------------------

@test "prompt-hook with empty inbox exits 0 with no output" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  assert_output ""
}

# ----- pending mail surfaces into context -------------------------------------

@test "prompt-hook with 2 queued messages lists both in one summary line" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message "first"  changes-requested   41
  _queue_message "second" approved-and-merged 43
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  assert_output --partial "[radio] 2 unread message(s):"
  assert_output --partial "from=pm intent=changes-requested pr=41"
  assert_output --partial "from=pm intent=approved-and-merged pr=43"
  assert_output --partial " | "
  assert_output --partial 'Process with `radio check` / `radio read <id>`'
  # One compact line — the injected context must not sprawl.
  [ "${#lines[@]}" -eq 1 ]
}

@test "prompt-hook summary includes the message ids radio read expects" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/worker-foo/inbox"/*.md)" .md)
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  assert_output --partial "$id"
}

@test "prompt-hook shows issue= when set and omits pr= when absent" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message "spec is ready" spec-ready "" 7
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  assert_output --partial "intent=spec-ready issue=7"
  refute_output --partial "pr="
}

@test "prompt-hook does not consume the inbox — messages stay for radio check/read" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/worker-foo/inbox'/*.md | wc -l | tr -d ' '"
  assert_output "1"
}

# ----- resilience: exactly the failure modes the hook exists for ---------------

@test "prompt-hook surfaces the inbox even when the session file is missing" {
  # The unregister cascade (#140) can leave mail queued against a role with
  # no .info file — the send-time wake already failed, and no ZELLIJ_TAB means
  # the re-seed fails too. The summary must still reach the model.
  _queue_message "stranded"
  unset ZELLIJ_TAB
  run bash -c "echo '{}' | '$RADIO' prompt-hook"
  assert_success
  assert_output --partial "[radio] 1 unread message(s):"
  assert_output --partial "intent=changes-requested"
}

@test "prompt-hook without a stdin payload works (manual invocation)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run "$RADIO" prompt-hook </dev/null
  assert_success
  assert_output --partial "[radio] 1 unread message(s):"
}

# ----- usage ------------------------------------------------------------------

@test "usage lists prompt-hook" {
  run "$RADIO" --help
  assert_success
  assert_output --partial "prompt-hook"
}
