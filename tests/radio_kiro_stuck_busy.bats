#!/usr/bin/env bats
# A kiro role left `busy` by a turn that died on an API error (#322).
#
# Probed on kiro-cli 3.1.0: when the prompt's request fails, kiro retries for
# about 1m40s and then prints the error, with `agentSpawn` and
# `userPromptSubmit` fired and no `stop`. So `radio busy` ran and `radio ready`
# never will. `radio send` used to queue behind that `busy` for good. Pinned
# here: a kiro role at `busy` that no hook has touched for
# TASK_FORCE_KIRO_BUSY_STALE_SECS (600s) is woken when its tab is still open,
# by #370's rule; `radio heartbeat`, kiro's new `postToolUse` hook, keeps a
# long genuine turn inside that window; claude is unchanged.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session-name
  export ZELLIJ_SESSION_NAME=live-server
  export TASK_FORCE_ROLE=test-runner
  unset ZELLIJ_TAB ZELLIJ_PANE_ID TASK_FORCE_KIRO_BUSY_STALE_SECS
  # worker-foo gets tab_id=7, pane_id=700.
  seed_zellij_tabs worker-foo
}

teardown() {
  teardown_all
}

SESS() { printf '%s/radio/sessions/%s.info' "$TASK_FORCE_HOME" "$1"; }

_ago() {
  date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}

_set_heartbeat() {
  local f
  f=$(SESS "$1")
  awk -v h="LAST_HEARTBEAT=$2" '/^LAST_HEARTBEAT=/{print h; next} {print}' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# Register <role> as <agent>, mark it busy, and put its heartbeat <minutes>
# back: the turn whose `stop` never came.
_register_stuck() {
  local role="$1" agent="$2" minutes="$3"
  "$RADIO" register --role "$role" --tab "$role" --agent "$agent"
  TASK_FORCE_ROLE="$role" "$RADIO" busy
  _set_heartbeat "$role" "$(_ago "$minutes")"
  : > "$STUB_CALLS_DIR/zellij.calls"
}

# ----- the wake ---------------------------------------------------------------

@test "send wakes a kiro role stuck busy past the window while its tab is open (#322)" {
  _register_stuck worker-foo kiro 20

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: delivered — woke worker-foo (tab_id=7), although it has been busy with no hook for"
  assert_output --partial "its turn likely ended on an error"
  refute_output --partial "queued"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
  run grep -c 'send: worker-foo is busy (state=busy, no hook for .*s) but its tab is still open — kiro, waking anyway' \
    "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "a busy claude role is still only queued, however old its heartbeat (#322)" {
  _register_stuck worker-foo claude 20

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy; it will drain on its next Stop"
  run stub_calls zellij
  refute_output --partial "write-chars"
  run grep -c 'waking anyway' "$TASK_FORCE_HOME/radio/log"
  assert_output "0"
}

@test "a kiro role busy inside the window is queued without a wake (#322)" {
  _register_stuck worker-foo kiro 5

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

@test "TASK_FORCE_KIRO_BUSY_STALE_SECS moves the window (#322)" {
  _register_stuck worker-foo kiro 5

  TASK_FORCE_KIRO_BUSY_STALE_SECS=60 TASK_FORCE_ROLE=pm-foo \
    run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: delivered — woke worker-foo"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

@test "a stuck kiro role whose tab is gone is queued as busy, not called dead (#322)" {
  _register_stuck worker-foo kiro 20
  export STUB_ZELLIJ_TABS_JSON='[{"name": "worker-bar", "tab_id": 8}]'

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  refute_output --partial "looks dead"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

@test "a stuck kiro role whose recorded tab id now names another tab is not woken (#322)" {
  _register_stuck worker-foo kiro 20
  # Tab 7 is somebody else's now, and a worker-foo tab exists at another id:
  # _live_tab_id would recover it by name (rc 3), which #370's rule refuses.
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "worker-bar", "tab_id": 7},
    {"name": "worker-foo", "tab_id": 9}
  ]'
  # Panes on both tabs, so a wake into tab 9 would land if anything tried it.
  export STUB_ZELLIJ_PANES_JSON='[
    {"id": 700, "is_plugin": false, "is_focused": true, "tab_id": 7},
    {"id": 900, "is_plugin": false, "is_focused": true, "tab_id": 9}
  ]'

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

@test "a failed wake of a stuck kiro role ends in the busy line (#322)" {
  _register_stuck worker-foo kiro 20

  STUB_ZELLIJ_WRITE_CHARS_FAIL=1 TASK_FORCE_ROLE=pm-foo \
    run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  refute_output --partial "delivered"
  refute_output --partial "is idle but wake failed"
  run grep -c 'write-chars failed for worker-foo' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

# ----- the heartbeat hook -------------------------------------------------------

@test "radio heartbeat refreshes LAST_HEARTBEAT, keeps STATE, prints nothing (#322)" {
  _register_stuck worker-foo kiro 20
  local before
  before=$(grep '^LAST_HEARTBEAT=' "$(SESS worker-foo)")

  TASK_FORCE_ROLE=worker-foo run "$RADIO" heartbeat </dev/null
  assert_success
  assert_output ""
  run grep '^STATE=' "$(SESS worker-foo)"
  assert_output "STATE=busy"
  run grep '^LAST_HEARTBEAT=' "$(SESS worker-foo)"
  refute_output "$before"
  # A per-tool-call hook must not repaint the tab.
  run stub_calls zellij
  refute_output --partial "rename-tab"
}

@test "a kiro turn whose tools keep the heartbeat fresh is not woken (#322)" {
  _register_stuck worker-foo kiro 20
  TASK_FORCE_ROLE=worker-foo "$RADIO" heartbeat </dev/null

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

@test "radio heartbeat with no role logs its no-op and prints nothing (#322)" {
  run env -u TASK_FORCE_ROLE "$RADIO" heartbeat </dev/null
  assert_success
  assert_output ""
  run grep -c 'hook-noop: heartbeat — no \$TASK_FORCE_ROLE' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}
