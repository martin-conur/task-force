#!/usr/bin/env bats
# A stalled zellij server must not stall radio's hooks (#384).
#
# `UserPromptSubmit hook [radio prompt-hook] timed out after 30s — output
# discarded` was seen in two repos: the busy flip ran `_rename_tab` first, and
# every zellij call it makes (list-sessions, list-tabs, rename-tab-by-id) was
# unbounded. Claude Code killed the hook at 30s and dropped the unread
# summary with it. The stub's STUB_ZELLIJ_HANG makes a chosen action block,
# which is what a busy or loaded zellij server looks like from the client.
#
# Contract pinned here: every zellij call radio makes is bounded by
# TASK_FORCE_ZELLIJ_TIMEOUT seconds, a timeout is logged as `zellij-timeout:`,
# the rest of that run skips zellij, and the state write and the summary go
# through regardless.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session ZELLIJ_SESSION_NAME=live-server
  unset ZELLIJ_TAB
  export TASK_FORCE_ROLE=worker-foo
  seed_zellij_tabs worker-foo
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude </dev/null
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-foo --intent changes-requested --pr 41 \
    --body "fix the thing" </dev/null >/dev/null 2>&1
  : > "$STUB_CALLS_DIR/zellij.calls"
  : > "$TASK_FORCE_HOME/radio/log"
}

teardown() {
  teardown_all
}

_state() { grep '^STATE=' "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"; }

# Run the hook with stdout to a file, never a pipe or $(…), so a hook that
# hangs cannot hold the test open past the stub's own sleep (see the
# fixture-portability notes on deadlines and pipes).
_timed_hook() {
  local out="$BATS_TEST_TMPDIR/hook.out" start=$SECONDS
  "$RADIO" "$@" </dev/null >"$out" 2>&1 || true
  HOOK_SECS=$((SECONDS - start))
  HOOK_OUT=$(cat "$out")
}

@test "prompt-hook: rename-tab-by-id hangs → summary printed, busy written, done inside the deadline (#384)" {
  STUB_ZELLIJ_HANG=rename-tab-by-id STUB_ZELLIJ_HANG_SECS=20 TASK_FORCE_ZELLIJ_TIMEOUT=1 \
    _timed_hook prompt-hook
  [[ "$HOOK_OUT" == *"[radio] 1 unread message(s)"* ]] || { echo "out: $HOOK_OUT" >&2; return 1; }
  assert [ "$HOOK_SECS" -le 5 ]
  run _state
  assert_output "STATE=busy"
  run grep 'zellij-timeout:' "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "zellij-timeout: rename-tab-by-id 1s role=worker-foo"
}

@test "prompt-hook: list-tabs hangs → the first timeout skips every later zellij call (#384)" {
  STUB_ZELLIJ_HANG=list-tabs STUB_ZELLIJ_HANG_SECS=20 TASK_FORCE_ZELLIJ_TIMEOUT=1 \
    _timed_hook prompt-hook
  [[ "$HOOK_OUT" == *"[radio] 1 unread message(s)"* ]] || { echo "out: $HOOK_OUT" >&2; return 1; }
  # One stalled call, not one per lookup: 1s, plus the run's own work.
  assert [ "$HOOK_SECS" -le 3 ]
  run _state
  assert_output "STATE=busy"
  assert_equal "$(grep -c 'list-tabs' "$STUB_CALLS_DIR/zellij.calls")" 1
  run grep -F 'rename-tab-by-id' "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
  run grep -c 'zellij-timeout:' "$TASK_FORCE_HOME/radio/log"
  assert_output 1
}

@test "busy / ready / heartbeat / stop-hook: a hanging zellij is bounded and the state still lands (#384)" {
  local cmd want
  for cmd in busy ready stop-hook heartbeat; do
    : > "$TASK_FORCE_HOME/radio/log"
    # stop-hook with mail queued blocks the stop (stays busy); the others flip.
    case "$cmd" in busy) want=busy ;; ready) want=idle ;; *) want="" ;; esac
    STUB_ZELLIJ_HANG="list-tabs rename-tab-by-id list-sessions" STUB_ZELLIJ_HANG_SECS=20 \
      TASK_FORCE_ZELLIJ_TIMEOUT=1 _timed_hook "$cmd"
    (( HOOK_SECS <= 4 )) || { echo "$cmd took ${HOOK_SECS}s" >&2; return 1; }
    [[ -z "$want" ]] || [[ "$(_state)" == "STATE=$want" ]] || { echo "$cmd: $(_state)" >&2; return 1; }
  done
}

@test "prompt-hook: a healthy zellij logs no timeout and still repaints the tab (#384)" {
  TASK_FORCE_ZELLIJ_TIMEOUT=1 _timed_hook prompt-hook
  [[ "$HOOK_OUT" == *"[radio] 1 unread message(s)"* ]]
  assert_stub_called zellij "rename-tab-by-id 7 ▶️ worker-foo"
  run grep -F 'zellij-timeout:' "$TASK_FORCE_HOME/radio/log"
  assert_failure
}

@test "register: a hanging list-tabs is bounded and the session file is still written (#384)" {
  rm -f "$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local start=$SECONDS
  STUB_ZELLIJ_HANG=list-tabs STUB_ZELLIJ_HANG_SECS=20 TASK_FORCE_ZELLIJ_TIMEOUT=1 \
    "$RADIO" register --role worker-foo --tab worker-foo --agent claude </dev/null \
    >"$BATS_TEST_TMPDIR/reg.out" 2>&1
  assert [ $((SECONDS - start)) -le 4 ]
  run _state
  assert_output "STATE=idle"
  run grep -F 'zellij-timeout: list-tabs 1s role=worker-foo' "$TASK_FORCE_HOME/radio/log"
  assert_success
}
