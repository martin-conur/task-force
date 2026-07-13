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

@test "awaiting toggles STATE to awaiting (#119)" {
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

@test "awaiting is a silent no-op when TASK_FORCE_ROLE is unset (#119)" {
  run env -u TASK_FORCE_ROLE "$RADIO" awaiting
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

@test "send queues (logs no-session) when recipient has no session file" {
  # No `register` for pm — but with $ZELLIJ set we still hit the no-session branch.
  export ZELLIJ=fake-session
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent ping --body "queue me" >/dev/null
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md 2>/dev/null | wc -l"
  assert_output --partial "1"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no session for pm"
}

# ----- honest delivery feedback on stdout (#166) ----------------------------

@test "send to absent recipient prints the no-session WARNING but still exits 0 (#166)" {
  # No `register` for pm — the message queues, but the sender must be *told*
  # nobody is listening rather than assuming delivery.
  export ZELLIJ=fake-session
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --pr 42 --body "PR up"
  assert_success   # queuing is legitimate — exit 0
  assert_output --partial "radio: WARNING — no session for pm"
  assert_output --partial "message queued but nobody is listening"
  # And the message is still queued for whenever pm shows up.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md 2>/dev/null | wc -l | tr -d ' '"
  assert_output "1"
}

@test "send to busy recipient prints the queued-busy line, exit 0 (#166)" {
  export ZELLIJ=fake-session
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is busy; it will drain on its next Stop"
}

@test "send to idle recipient with no zellij prints the queued idle-wake-failed line, exit 0 (#166)" {
  # pm is registered and idle, but the sender is not inside a zellij session, so
  # there's no live pane to wake — the message surfaces on pm's next prompt.
  unset ZELLIJ
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed"
  assert_output --partial "will surface on its next prompt/register"
}

@test "send to a kiro recipient softens the redelivery promise (no prompt-hook there) (#166)" {
  # kiro has neither prompt-hook nor register-drain injection (#146), so the
  # wake-failed line must not promise "prompt/register" — it says "check/register".
  unset ZELLIJ
  "$RADIO" register --role pm --tab pm --agent kiro
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed"
  assert_output --partial "will surface on its next check/register"
  refute_output --partial "prompt/register"
}

@test "send to an awaiting recipient names the state honestly (not 'busy') (#166)" {
  # An awaiting agent's turn is over — no Stop is coming. The line must not
  # promise a next-Stop drain; the honest path is prompt-hook on the next prompt.
  export ZELLIJ=fake-session
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" awaiting
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is awaiting user input; it will surface via prompt-hook when next prompted"
  refute_output --partial "next Stop"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md 2>/dev/null | wc -l | tr -d ' '"
  assert_output "1"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "is awaiting (state=awaiting)"
}

@test "send to a dead-but-busy recipient warns instead of promising a next-Stop drain (#166)" {
  # A crashed tab leaves STATE=busy with a frozen heartbeat (the `radio orphans`
  # case). Promising "drains on its next Stop" would be a lie — no Stop is coming.
  # A heartbeat older than the 1h orphan threshold must escalate to a warning.
  export ZELLIJ=fake-session
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  # Freeze pm's heartbeat 3h into the past — well past the 3600s orphan cutoff.
  local stale
  stale=$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)
  awk -v h="LAST_HEARTBEAT=$stale" \
    '/^LAST_HEARTBEAT=/{print h; next} {print}' \
    "$TASK_FORCE_HOME/radio/sessions/pm.info" > "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp"
  mv "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp" "$TASK_FORCE_HOME/radio/sessions/pm.info"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: WARNING — pm looks dead"
  assert_output --partial "state=busy"
  assert_output --partial "radio orphans"
  refute_output --partial "next Stop"
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

@test "read prints the full message body and auto-acks (moves to processed/) (#131)" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "Body content"
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)" .md)

  TASK_FORCE_ROLE=pm run "$RADIO" read "$id"
  assert_success
  assert_output --partial "from: worker-foo"
  assert_output --partial "Body content"

  # Default `read` now auto-acks — see issue #131.
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/${id}.md" ]
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/pm/processed/${id}.md" ]

  # Legacy paired `ack` is idempotent on an already-processed id.
  TASK_FORCE_ROLE=pm run "$RADIO" ack "$id"
  assert_success
  assert_output --partial "already processed"
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
