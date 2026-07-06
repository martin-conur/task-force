#!/usr/bin/env bats
# Tests for `radio stop-hook` (#163) — the Stop-hook entrypoint that replaces
# `radio ready && radio check`.
#
# Background: `radio send` makes exactly one wake attempt, at send time. If
# the recipient is busy/awaiting, the message queues with zero redelivery —
# and the old Stop hook couldn't help, because Stop-hook stdout goes to the
# hook subshell, never to the model. `radio stop-hook` closes that gap: it
# marks the role idle, and if the inbox has unread messages it emits
# `{"decision": "block", ...}` on stdout so Claude Code forces the agent to
# continue and drain the queue at the end of its turn. A payload with
# `stop_hook_active: true` never re-blocks (no infinite continue loop).

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
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-foo --intent changes-requested --pr 5 --body "${1:-fix the thing}"
}

# ----- no-role gate (#93 semantics) ------------------------------------------

@test "stop-hook with no TASK_FORCE_ROLE is a silent exit 0 (plain claude session)" {
  run bash -c "echo '{}' | env -u TASK_FORCE_ROLE '$RADIO' stop-hook"
  assert_success
  assert_output ""
}

# ----- idle transition --------------------------------------------------------

@test "stop-hook marks the role idle" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  "$RADIO" busy
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=busy"
  run bash -c "echo '{}' | '$RADIO' stop-hook"
  assert_success
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
}

@test "stop-hook with empty inbox exits 0 with no output (normal stop)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  run bash -c "echo '{}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
}

# ----- block on pending mail --------------------------------------------------

@test "stop-hook with pending messages emits block JSON and exits 0" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message "first"
  _queue_message "second"
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '"decision": "block"'
  assert_output --partial '2 unread message(s)'
  assert_output --partial 'radio check'
  assert_output --partial 'radio read'
}

@test "stop-hook block output is valid JSON with decision=block" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{}' | '$RADIO' stop-hook | jq -er '.decision'"
  assert_success
  assert_output "block"
}

@test "stop-hook does not consume the inbox — messages stay for radio check/read" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{}' | '$RADIO' stop-hook"
  assert_success
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/worker-foo/inbox'/*.md | wc -l | tr -d ' '"
  assert_output "1"
}

@test "stop-hook marks busy when it blocks — the agent is about to continue" {
  # No UserPromptSubmit fires on a hook-forced continuation, so if we painted
  # idle here cmd_send could write-chars into the running pane mid-drain
  # (#172 review).
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{}' | '$RADIO' stop-hook"
  assert_success
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=busy"
}

@test "stop-hook without jq fails safe: no block, idle, exit 0" {
  # jq absent means stop_hook_active is unreadable; blocking blind could
  # re-block on every Stop forever, so stop-hook degrades to queue-only.
  # Build a PATH of symlinks to everything radio needs, minus jq.
  local nojq_bin
  nojq_bin=$(mktemp -d)
  for cmd in bash cat mkdir mv rm awk grep cut head tr date dirname basename ls sed env; do
    ln -s "$(command -v $cmd)" "$nojq_bin/$cmd"
  done
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  "$RADIO" busy
  _queue_message
  run bash -c "echo '{}' | env PATH='$nojq_bin' '$RADIO' stop-hook"
  rm -rf "$nojq_bin"
  assert_success
  assert_output ""
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "jq unavailable — not blocking"
}

@test "stop-hook without a stdin payload still blocks on pending mail (manual invocation)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run "$RADIO" stop-hook </dev/null
  assert_success
  assert_output --partial '"decision": "block"'
}

# ----- stop_hook_active guard (no continue loop) ------------------------------

@test "stop-hook with stop_hook_active=true never re-blocks, even with pending mail" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  "$RADIO" busy
  _queue_message
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
  # ... but it still flips STATE to idle.
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
  # The stranded count is logged — a message arriving during the drain turn
  # is otherwise invisible until #164/#168 close that path.
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "1 still unread"
}

# ----- usage string honesty (#163) --------------------------------------------

@test "usage: ready no longer claims it processes pending; stop-hook is listed" {
  run "$RADIO" --help
  assert_success
  refute_output --partial "(and process pending)"
  assert_output --partial "stop-hook"
}
