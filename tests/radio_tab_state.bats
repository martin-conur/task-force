#!/usr/bin/env bats
# Tests for _rename_tab — the idle/busy emoji prefix on the zellij tab name
# and the matching TAB= sync in the session file (#95).
#
# `_rename_tab` is a private helper; we exercise it indirectly through
# `radio register` (first-paint idle prefix) and `radio busy` / `radio ready`
# (state-driven flips). The zellij stub records every invocation so we can
# assert that rename-tab fires with the expected emoji-prefixed name.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# The visible-name emojis. Kept as constants so the assertions read clearly
# and we don't repeat the literal UTF-8 sequences across cases.
PAUSE='⏸️ '
PLAY='▶️ '

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  # Bypass the no-role dispatcher gate on `register` (#93); per-test overrides
  # set TASK_FORCE_ROLE where the value matters.
  export TASK_FORCE_ROLE=test-runner
}

teardown() {
  teardown_all
}

# ----- no-op paths ----------------------------------------------------------

@test "register: no rename-tab when \$ZELLIJ is unset" {
  unset ZELLIJ
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run stub_calls zellij
  refute_output --partial "rename-tab"
  # And TAB= stays at the bare slug.
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=pm"
}

@test "register: no rename-tab when zellij is not on PATH" {
  # Drop the stub dir from PATH so `command -v zellij` fails.
  PATH="/usr/bin:/bin" TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run stub_calls zellij
  refute_output --partial "rename-tab"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=pm"
}

@test "busy/ready: no rename-tab when session file has no TAB= field" {
  # Hand-craft a session file with no TAB= line.
  mkdir -p "$TASK_FORCE_HOME/radio/sessions"
  printf 'ROLE=pm\nSTATE=idle\nLAST_HEARTBEAT=2020-01-01T00:00:00Z\nAGENT=claude\nLOADOUT=\n' \
    > "$TASK_FORCE_HOME/radio/sessions/pm.info"
  TASK_FORCE_ROLE=pm "$RADIO" busy
  run stub_calls zellij
  refute_output --partial "rename-tab"
}

# ----- first paint at register ---------------------------------------------

@test "register paints the idle prefix on the tab and syncs TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  assert_stub_called zellij "action rename-tab ${PAUSE}pm"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- busy / ready flips ---------------------------------------------------

@test "busy flips tab to the play prefix and updates TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  assert_stub_called zellij "action rename-tab ${PLAY}pm"
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PLAY}pm"
}

@test "ready flips tab back to the pause prefix and updates TAB=" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- no prefix stacking ---------------------------------------------------

@test "consecutive idle→busy→idle flips do not stack emoji prefixes" {
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=pm "$RADIO" ready

  # Final TAB= should be exactly "<pause> pm", not "<pause><play> pm" etc.
  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"

  # And the most recent rename-tab call should target the same name.
  run bash -c "grep 'rename-tab' '$STUB_CALLS_DIR/zellij.calls' | tail -1"
  assert_output "zellij action rename-tab ${PAUSE}pm"
}

# ----- TAB= sync keeps wake-up working --------------------------------------

@test "send finds the recipient's tab after rename (TAB= sync verified)" {
  # Register pm — first-paint rewrites TAB= to "<pause> pm".
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude

  # Worker sends to pm; wake-up reads TAB= from pm.info and calls
  # `zellij action go-to-tab-name <renamed>`. If TAB= sync were broken
  # this would attempt the bare slug `pm` instead.
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_stub_called zellij "action go-to-tab-name ${PAUSE}pm"
}
