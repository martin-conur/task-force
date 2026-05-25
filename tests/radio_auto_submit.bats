#!/usr/bin/env bats
# Pins the opt-in CR (auto-submit) wake-up contract for --auto workers (#128).
#
# Contract:
#   - `radio register` with TASK_FORCE_AUTO_SUBMIT=1 in env → AUTO_SUBMIT=1 in
#     session file. Absent / any other value → no AUTO_SUBMIT line (legacy).
#   - `radio send` to a recipient whose session file has AUTO_SUBMIT=1 writes
#     "radio check" + CR (0x0D) via zellij write-chars. Otherwise LF (0x0A).
#   - `_ensure_session_file` (the self-heal path) re-applies the same env check
#     so the opt-in survives /clear, /compact, /resume.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  export TASK_FORCE_ROLE=test-runner
  unset ZELLIJ_TAB
  # pm gets tab_id=7, pane_id=700; worker-foo gets tab_id=8, pane_id=800.
  seed_zellij_tabs pm worker-foo
}

teardown() {
  teardown_all
}

# ----- register: persist AUTO_SUBMIT only when env opt-in is set -------------

@test "register persists AUTO_SUBMIT=1 when TASK_FORCE_AUTO_SUBMIT=1 is in env" {
  TASK_FORCE_AUTO_SUBMIT=1 "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  run cat "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output --partial "AUTO_SUBMIT=1"
}

@test "register omits AUTO_SUBMIT when the env var is unset (legacy default)" {
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  run cat "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  refute_output --partial "AUTO_SUBMIT"
}

@test "register omits AUTO_SUBMIT when the env var holds anything but the exact value 1" {
  TASK_FORCE_AUTO_SUBMIT=true "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  run cat "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  refute_output --partial "AUTO_SUBMIT"
}

# ----- send: CR if AUTO_SUBMIT=1, LF otherwise -------------------------------

@test "send to AUTO_SUBMIT=1 recipient writes 'radio check' followed by CR (0x0D)" {
  TASK_FORCE_AUTO_SUBMIT=1 "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-foo --intent approved-and-merged --body "merged"

  # The zellij stub records calls with the literal byte preserved.
  # CR (0x0D) terminates the wake-up — that's the Enter the recipient TUI
  # binds to.
  run grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls"
  assert_output "1"
}

@test "send to default recipient (no AUTO_SUBMIT) preserves LF (0x0A) wake-up" {
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-foo --intent changes-requested --body "rework"

  # No CR-terminated wake-up — legacy behaviour intact.
  run grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls"
  assert_output "0"
  # Sanity: write-chars did fire (recipient was idle and reachable).
  assert_stub_called zellij "action write-chars --pane-id 800 radio check"
}

@test "send to PM (which never opts in) always uses LF, even if sender is --auto" {
  # PM registers without the env flag.
  "$RADIO" register --role pm --tab pm --agent claude
  # Worker sends back review-requested with the flag in its own env. The CR/LF
  # decision is driven by the *recipient's* session file, not the sender's env.
  TASK_FORCE_ROLE=worker-foo TASK_FORCE_AUTO_SUBMIT=1 \
    "$RADIO" send --to pm --intent review-requested --body "PR up"

  run grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls"
  assert_output "0"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

# ----- _ensure_session_file: preserve the opt-in across self-heal -----------

@test "_ensure_session_file re-seeds AUTO_SUBMIT=1 when env still has the flag" {
  # Simulate a worker tab where SessionStart did not (or no longer) hold the
  # session file. busy → _update_state → _ensure_session_file triggers the
  # re-seed branch.
  unset TASK_FORCE_ROLE
  export TASK_FORCE_ROLE=worker-foo
  export ZELLIJ_TAB=worker-foo
  export TASK_FORCE_AUTO_SUBMIT=1

  "$RADIO" busy

  run cat "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  assert_output --partial "AUTO_SUBMIT=1"
  assert_output --partial "STATE=busy"
}

@test "_ensure_session_file omits AUTO_SUBMIT when env flag is absent" {
  unset TASK_FORCE_ROLE
  export TASK_FORCE_ROLE=worker-foo
  export ZELLIJ_TAB=worker-foo

  "$RADIO" busy

  run cat "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  refute_output --partial "AUTO_SUBMIT"
}
