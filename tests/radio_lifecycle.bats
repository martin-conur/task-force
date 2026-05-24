#!/usr/bin/env bats
# Tests for radio session lifecycle — the SessionEnd payload filter in
# `radio unregister`, and the self-healing re-seed in busy/ready (#107
# follow-up).
#
# Background: Claude Code's SessionEnd hook fires on intra-session events
# (`/clear` → reason=clear, `/compact` and resume → reason=resume) as well
# as real exit (reason=logout|prompt_input_exit|other). The hook command is
# `radio unregister`, so without filtering we wipe the session file mid-
# life — empirically observed as bursts of 40+ unregister calls in ~25s
# (#107 expanded scope, acceptance criteria #8/#9/#10).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ
  export TASK_FORCE_ROLE=test-runner
}

teardown() {
  teardown_all
}

# ----- SessionEnd payload filter --------------------------------------------

@test "unregister skips when stdin payload has reason=clear (intra-session /clear)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert [ -f "$sess" ]
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"clear\"}' | '$RADIO' unregister"
  assert_success
  # Session file MUST still exist.
  assert [ -f "$sess" ]
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "skipping (reason=clear"
}

@test "unregister skips when stdin payload has reason=resume (/compact, session resume)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"resume\"}' | '$RADIO' unregister"
  assert_success
  assert [ -f "$sess" ]
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "skipping (reason=resume"
}

@test "unregister proceeds when stdin payload has reason=logout (real exit)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"logout\"}' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
}

@test "unregister proceeds when stdin payload has reason=prompt_input_exit (process EOF)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"prompt_input_exit\"}' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
}

@test "unregister proceeds when stdin payload has reason=other (catch-all real exit)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"other\"}' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
}

@test "unregister proceeds when stdin is empty (manual invocation from task-done)" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  # task-done calls `radio unregister 2>/dev/null || true`. Its stdin is
  # whatever the calling shell has — typically not piped. Simulate that by
  # closing stdin so jq sees nothing.
  TASK_FORCE_ROLE=worker-foo run bash -c "'$RADIO' unregister < /dev/null"
  assert_success
  assert [ ! -f "$sess" ]
}

@test "unregister proceeds when stdin payload is not valid JSON" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo 'not json' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
}

@test "unregister proceeds when payload JSON has no reason field" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"other_field\":\"value\"}' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
}

# ----- register-if-missing (self-healing) -----------------------------------

@test "busy re-seeds the session file from \$TASK_FORCE_ROLE + \$ZELLIJ_TAB if it was wiped" {
  # Initial state: registered, then file is wiped (simulating an
  # unfiltered SessionEnd that slipped past the matcher).
  "$RADIO" register --role worker-foo --tab w-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  rm -f "$sess"
  assert [ ! -f "$sess" ]

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=w-foo run "$RADIO" busy
  assert_success
  # File was re-seeded with the new STATE.
  assert [ -f "$sess" ]
  run cat "$sess"
  assert_output --partial "ROLE=worker-foo"
  assert_output --partial "TAB=w-foo"
  assert_output --partial "STATE=busy"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "ensure_session: re-seeded worker-foo"
}

@test "ready re-seeds the session file from env vars if it was wiped" {
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  rm -f "$sess"

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=w-foo run "$RADIO" ready
  assert_success
  assert [ -f "$sess" ]
  run cat "$sess"
  assert_output --partial "STATE=idle"
}

@test "re-seed is a no-op when \$ZELLIJ_TAB is unset (no identity to rebuild from)" {
  # Plain `claude` session with $TASK_FORCE_ROLE set but no $ZELLIJ_TAB
  # (e.g. user typed TASK_FORCE_ROLE=foo in a shell). Nothing to rebuild
  # from, so re-seed bails and the command exits 0 without writing.
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert [ ! -f "$sess" ]

  TASK_FORCE_ROLE=worker-foo run env -u ZELLIJ_TAB "$RADIO" busy
  assert_success
  assert [ ! -f "$sess" ]
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "ZELLIJ_TAB unset"
}

# ----- end-to-end lifecycle scenario (#107 acceptance #10) ------------------

@test "lifecycle: register → SessionEnd(reason=clear) → busy keeps session valid (#107)" {
  # Simulates the offending event chain documented in #107:
  #   1. Worker registers at SessionStart.
  #   2. User runs /clear → Claude fires SessionEnd with reason=clear → our
  #      unregister hook receives a JSON payload and skips (filter).
  #   3. User submits a prompt → UserPromptSubmit fires `radio busy`.
  #      Even if the filter had failed, _ensure_session_file would re-seed.
  # Outcome: session file remains intact end-to-end, with TAB_ID populated
  # (when zellij is reachable).
  "$RADIO" register --role worker-foo --tab w-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert [ -f "$sess" ]

  # SessionEnd hook with reason=clear → filter must skip.
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"clear\"}' | '$RADIO' unregister"
  assert_success
  assert [ -f "$sess" ]

  # UserPromptSubmit → busy.
  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=w-foo run "$RADIO" busy
  assert_success
  assert [ -f "$sess" ]

  # Stop hook → ready.
  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=w-foo run "$RADIO" ready
  assert_success
  assert [ -f "$sess" ]
  run cat "$sess"
  assert_output --partial "ROLE=worker-foo"
  assert_output --partial "STATE=idle"
}

@test "lifecycle: re-seed after spurious wipe restores TAB_ID when zellij is reachable" {
  setup_stubs
  seed_zellij_tabs worker-foo
  export ZELLIJ=fake

  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output --partial "TAB_ID=7"

  # Simulate a spurious wipe (e.g. the matcher slipped, or an old radio
  # without the stdin filter was deployed mid-session).
  rm -f "$sess"

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run "$RADIO" busy
  assert_success
  assert [ -f "$sess" ]
  run grep "^TAB_ID=" "$sess"
  # Same tab id as the original register call — re-seed re-resolved by name.
  assert_output --partial "TAB_ID=7"
}

# ----- re-register preserves TAB_ID on zellij lookup miss (#117) ------------
#
# The #117 failure mode: a worker's $ZELLIJ_TAB env var sticks to the bare
# slug captured at pane creation, but the visible tab name has since been
# painted to "⏸️ <slug>" / "▶️ <slug>" by _rename_tab. When SessionStart
# fires a second time (because of /compact, /clear, /resume, or a fresh
# `claude` in the same tab), the hook re-runs `radio register --tab $ZELLIJ_TAB`
# with the bare slug and the literal-name lookup in zellij misses. Pre-fix,
# we'd blindly rewrite TAB_ID= to empty — killing _rename_tab and cmd_send
# for the rest of the worker's life, and finally leaking the tab when
# task-done read the now-empty TAB_ID.

@test "register: re-register preserves existing TAB_ID when zellij list-tabs misses (#117)" {
  setup_stubs
  seed_zellij_tabs worker-foo
  export ZELLIJ=fake

  # First register: finds tab_id=7 by name and persists it.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output --partial "TAB_ID=7"

  # Now simulate the second SessionStart: the visible tab has been painted
  # to "▶️ worker-foo", so the bare-name lookup misses. Re-seed the stub
  # fixture so only the prefixed entry is advertised.
  export STUB_ZELLIJ_TABS_JSON='[{"name":"▶️ worker-foo","tab_id":7}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id":700,"is_plugin":false,"is_focused":true,"tab_id":7}]'

  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  # TAB_ID must still be 7 — preserved, not clobbered to empty.
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "preserving existing TAB_ID=7"
  refute_output --partial "could not resolve tab_id for tab=worker-foo"
}

@test "register: first-time lookup miss with no existing file still logs the resolve-failure (#117)" {
  # Layer 1 must not change first-time behavior: a brand-new register for a
  # role with no prior session file, when zellij can't resolve the tab,
  # should still write TAB_ID= empty and log the "could not resolve" line.
  setup_stubs
  export ZELLIJ=fake
  # No stub fixture → list-tabs returns empty.

  "$RADIO" register --role worker-new --tab worker-new --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-new.info"
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID="
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "could not resolve tab_id for tab=worker-new"
  refute_output --partial "preserving existing TAB_ID"
}

@test "register: re-register with empty existing TAB_ID falls through to the resolve-failure path" {
  # Edge case: prior session file exists but TAB_ID= is empty (e.g. zellij
  # wasn't running at the original register). A subsequent re-register that
  # also misses should NOT log "preserving" (nothing useful to preserve) —
  # it should log the original "could not resolve" line, same as a first
  # register would.
  setup_stubs
  export ZELLIJ=fake
  # First register: no fixture → TAB_ID= empty in file.
  "$RADIO" register --role worker-empty --tab worker-empty --agent claude

  # Second register: still no fixture.
  "$RADIO" register --role worker-empty --tab worker-empty --agent claude

  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "could not resolve tab_id for tab=worker-empty"
  refute_output --partial "preserving existing TAB_ID"
}
