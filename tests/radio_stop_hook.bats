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

@test "stop-hook with an invalid TASK_FORCE_ROLE is a logged silent exit 0 (#164)" {
  run bash -c "echo '{}' | env TASK_FORCE_ROLE='worker-my.app-issue-7' '$RADIO' stop-hook"
  assert_success
  assert_output ""
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "invalid role"
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
  local nojq_bin
  nojq_bin=$(make_nojq_bin)
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

@test "stop-hook with stop_hook_active=true and no recorded block set allows the stop" {
  # Nothing recorded the ids that supposedly caused this continuation (no
  # prior block in this session), so there is no evidence to weigh against
  # the loop-breaker — it wins, exactly as it did before #197.
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  "$RADIO" busy
  _queue_message
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
  # ... but it still flips STATE to idle.
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no recorded block set"
  assert_output --partial "1 still unread"
}

# ----- blocked-id set comparison (#197) ---------------------------------------

@test "a block records the ids that caused it on the session file (#197)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/worker-foo/inbox"/*.md)" .md)
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '"decision": "block"'
  run grep "^BLOCKED_IDS=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "BLOCKED_IDS=$id"
}

@test "a message arriving during the drain turn earns one more block, then the loop-breaker stops it (#197)" {
  # The live 2026-09-14 sequence: PR merged → approved-and-merged queued while
  # the worker was busy → Stop with stop_hook_active=true. Pre-#197 the worker
  # went idle with that message unread in its own mailbox, forever.
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message "first"

  # Turn ends with mail pending → block #1.
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '1 unread message(s)'

  # The agent drains nothing and a second message lands mid-continuation.
  _queue_message "approved-and-merged"
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '"decision": "block"'
  assert_output --partial '2 unread message(s)'
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=busy"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "new message(s) arrived during the drain turn"

  # Same two ids ignored again → no new arrival → the stop is allowed (no loop).
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "STATE=idle"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no new message since the block"
}

@test "an agent that ignores the same message twice still stops (#197 keeps the loop guard)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '"decision": "block"'
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
  # And a third Stop in the same chain doesn't resurrect the block either.
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
}

@test "draining the inbox clears the recorded block set (#197)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/worker-foo/inbox"/*.md)" .md)
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  run grep -c "^BLOCKED_IDS=." "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "1"

  # The agent does what the block asked.
  "$RADIO" read "$id" >/dev/null
  run bash -c "echo '{\"stop_hook_active\": true}' | '$RADIO' stop-hook"
  assert_success
  assert_output ""
  run grep -c "^BLOCKED_IDS=." "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_failure
  assert_output "0"
}

@test "the recorded block set dies with the session file — no leak across sessions (#197)" {
  # Deliberately not a sidecar: #188 sidecars outlive unregister, and a stale
  # set could suppress a legitimate block for a later session of this role.
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  _queue_message
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  run grep -c "^BLOCKED_IDS=." "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output "1"

  "$RADIO" unregister --manual
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  run grep -c "^BLOCKED_IDS=." "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_failure
  assert_output "0"

  # The still-unread message blocks the new session's first stop, as it should.
  run bash -c "echo '{\"stop_hook_active\": false}' | '$RADIO' stop-hook"
  assert_success
  assert_output --partial '"decision": "block"'
}

# ----- usage string honesty (#163) --------------------------------------------

@test "usage: ready no longer claims it processes pending; stop-hook is listed" {
  run "$RADIO" --help
  assert_success
  refute_output --partial "(and process pending)"
  assert_output --partial "stop-hook"
}
