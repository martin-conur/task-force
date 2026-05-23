#!/usr/bin/env bats
# Unit tests for bin/radio: register / send / check / read / ack / ready / busy
# / unregister / orphans. Mailbox is rooted at a tempdir via $TASK_FORCE_HOME.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ                       # no wakeup attempts in unit tests
  # Default to a non-empty role so `register` calls flow through the
  # dispatcher's no-role gate (#93). Tests that need the gate to fire (the
  # plain-`claude` hook scenario) override with `env -u TASK_FORCE_ROLE`;
  # tests that check `_require_role` rejection override with a specific value.
  export TASK_FORCE_ROLE=test-runner
}

teardown() {
  teardown_all
}

# ----- register / ready / busy / unregister ---------------------------------

@test "register writes a session file with STATE=idle and the right fields" {
  run "$RADIO" register --role pm --tab pm --repo /tmp/foo --agent claude --loadout claude-gh
  assert_success
  local sess="$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert [ -f "$sess" ]
  run cat "$sess"
  assert_output --partial "ROLE=pm"
  assert_output --partial "TAB=pm"
  assert_output --partial "REPO=/tmp/foo"
  assert_output --partial "STATE=idle"
  assert_output --partial "AGENT=claude"
  assert_output --partial "LOADOUT=claude-gh"
  assert_output --partial "LAST_HEARTBEAT="
}

@test "register --role and --agent are required" {
  run "$RADIO" register --tab pm
  assert_failure
  assert_output --partial "--role required"
  run "$RADIO" register --role pm --tab pm
  assert_failure
  assert_output --partial "--agent required"
}

@test "ready toggles STATE to idle; busy toggles STATE to busy" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=busy"
  TASK_FORCE_ROLE=pm "$RADIO" ready
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=idle"
}

@test "awaiting toggles STATE to awaiting" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  run grep "^STATE=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "STATE=awaiting"
}

@test "unregister removes the session file" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" unregister
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/pm.info" ]
}

@test "lifecycle: register → unregister leaves the sessions dir empty (#94)" {
  # Guards against orphan accumulation. The SessionEnd hook + task-done both
  # call `radio unregister`; this test pins the contract that a clean cycle
  # leaves no session file behind.
  "$RADIO" register --role worker-foo --tab w-foo --agent claude --loadout claude-gh
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/worker-foo.info" ]
  TASK_FORCE_ROLE=worker-foo "$RADIO" unregister
  run bash -c "ls '$TASK_FORCE_HOME/radio/sessions/' 2>/dev/null | wc -l | tr -d ' '"
  assert_output "0"
}

# ----- silent no-op when $TASK_FORCE_ROLE is unset (#93) --------------------
# Hook-invoked commands (radio busy/ready/check/unregister and `register --role ""`
# from the SessionStart hook) must NOT block a plain `claude` session in a
# task-force-equipped repo. They have nothing to mutate when no role is set, so
# they exit 0 silently. Conversely, user-invoked commands (read/ack) keep
# erroring loudly because missing role there is a genuine usage bug.

@test "busy is a silent no-op when TASK_FORCE_ROLE is unset" {
  run env -u TASK_FORCE_ROLE "$RADIO" busy
  assert_success
  [ -z "$output" ]
}

@test "ready is a silent no-op when TASK_FORCE_ROLE is unset" {
  run env -u TASK_FORCE_ROLE "$RADIO" ready
  assert_success
  [ -z "$output" ]
}

@test "check is a silent no-op when TASK_FORCE_ROLE is unset" {
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  [ -z "$output" ]
}

@test "unregister is a silent no-op when TASK_FORCE_ROLE is unset" {
  run env -u TASK_FORCE_ROLE "$RADIO" unregister
  assert_success
  [ -z "$output" ]
}

@test "awaiting is a silent no-op when TASK_FORCE_ROLE is unset" {
  run env -u TASK_FORCE_ROLE "$RADIO" awaiting
  assert_success
  [ -z "$output" ]
}

@test "register --role '' is a silent no-op (SessionStart hook with empty TASK_FORCE_ROLE)" {
  run env -u TASK_FORCE_ROLE "$RADIO" register --role "" --tab "" --agent claude --loadout claude-gh
  assert_success
  [ -z "$output" ]
  # No session file should have been written.
  run bash -c "ls '$TASK_FORCE_HOME/radio/sessions/' 2>/dev/null | wc -l | tr -d ' '"
  assert_output "0"
}

@test "register still errors loudly when TASK_FORCE_ROLE is set but --role is empty (user typo, not hook)" {
  # Option 1 dispatcher gate fires only on missing env var, NOT on empty --role.
  # If a user runs `radio register --role ""` in a task-work / task-pm session
  # (where $TASK_FORCE_ROLE is set), that's a real typo and should fail loudly.
  TASK_FORCE_ROLE=pm run "$RADIO" register --role "" --tab pm --agent claude
  assert_failure
  assert_output --partial "--role required"
}

@test "read without TASK_FORCE_ROLE still errors loudly (user-invoked, not hook-invoked)" {
  run env -u TASK_FORCE_ROLE "$RADIO" read some-id
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
}

@test "ack without TASK_FORCE_ROLE still errors loudly (user-invoked, not hook-invoked)" {
  run env -u TASK_FORCE_ROLE "$RADIO" ack some-id
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
}

# ----- send / check / read / ack --------------------------------------------

@test "send writes a message into the recipient's inbox with the expected frontmatter" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send \
    --to pm --intent review-requested --pr 42 --body "PR up, CI green"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md"
  assert_success
  local msg
  msg=$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)
  run cat "$msg"
  assert_output --partial "from: worker-foo"
  assert_output --partial "to: pm"
  assert_output --partial "intent: review-requested"
  assert_output --partial "pr: 42"
  assert_output --partial "PR up, CI green"
}

@test "send accepts body via stdin when --body is omitted" {
  TASK_FORCE_ROLE=worker-bar "$RADIO" send --to pm --intent ping <<<"hello via stdin"
  local msg
  msg=$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)
  run cat "$msg"
  assert_output --partial "hello via stdin"
}

@test "send queues silently when recipient has no session file" {
  # No `register` for pm — but with $ZELLIJ set we still hit the no-session branch.
  export ZELLIJ=fake-session
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent ping --body "queue me"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md 2>/dev/null | wc -l"
  assert_output --partial "1"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no session for pm"
}

@test "check lists unread messages and prints (no unread messages) when empty" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm run "$RADIO" check
  assert_output --partial "(no unread messages)"

  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR ready"
  TASK_FORCE_ROLE=pm run "$RADIO" check
  assert_output --partial "from=worker-foo"
  assert_output --partial "intent=review-requested"
  assert_output --partial "PR ready"
}

@test "read prints the full message body; ack moves it to processed/" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "Body content"
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)" .md)

  TASK_FORCE_ROLE=pm run "$RADIO" read "$id"
  assert_success
  assert_output --partial "from: worker-foo"
  assert_output --partial "Body content"

  TASK_FORCE_ROLE=pm "$RADIO" ack "$id"
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]
}

@test "ack of an unknown message returns non-zero" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm run "$RADIO" ack "does-not-exist"
  assert_failure
  assert_output --partial "not in inbox"
}

# ----- role sanitization (path-traversal defense) --------------------------

@test "register rejects a role containing '..' (path traversal)" {
  run "$RADIO" register --role "../escape" --tab pm --agent claude
  assert_failure
  assert_output --partial "invalid role"
}

@test "register rejects a role containing '/' (path separator)" {
  run "$RADIO" register --role "pm/sub" --tab pm --agent claude
  assert_failure
  assert_output --partial "invalid role"
}

@test "send rejects a recipient role containing '..'" {
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to "../escape" --intent ping --body x
  assert_failure
  assert_output --partial "invalid role"
}

@test "self-identifying commands reject a malformed \$TASK_FORCE_ROLE" {
  TASK_FORCE_ROLE="pm/../escape" run "$RADIO" check
  assert_failure
  assert_output --partial "invalid role"
}

# ----- orphans --------------------------------------------------------------

@test "orphans lists sessions whose LAST_HEARTBEAT is older than 1 hour" {
  "$RADIO" register --role pm                           --tab pm           --agent claude
  "$RADIO" register --role worker-old --tab worker-old  --agent claude
  # Backdate worker-old's LAST_HEARTBEAT by 2 hours.
  local old_file="$TASK_FORCE_HOME/radio/sessions/worker-old.info"
  awk '
    /^LAST_HEARTBEAT=/ {print "LAST_HEARTBEAT=2020-01-01T00:00:00Z"; next}
    {print}
  ' "$old_file" > "${old_file}.tmp" && mv "${old_file}.tmp" "$old_file"

  run "$RADIO" orphans
  assert_success
  assert_output --partial "worker-old"
  refute_output --partial $'pm\t'
}
