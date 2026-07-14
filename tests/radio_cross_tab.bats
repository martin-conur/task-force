#!/usr/bin/env bats
# Regression tests for #102 — both `_rename_tab` (state flips) and
# `cmd_send` (wake-up) must scope their zellij side-effects to the role's
# own tab, independent of whichever tab the user happens to have focused.
#
# Bug 1 (symptom 1 in the issue): with PM focused, a worker auto-unregister
# fires `radio ready` from the worker's pane. The pre-#102 code called
# `zellij action rename-tab "▶️ pm"` which targets the focused tab, so PM's
# tab name got clobbered. With per-tab targeting we should rename only the
# worker's own tab id.
#
# Bug 2 (symptom 2 in the issue): with worker-a focused, worker-b runs
# `radio send --to pm`. The pre-#102 code did `go-to-tab-name pm` +
# `write-chars`; the focus switch wasn't atomic and "radio check" could land
# on worker-a (or worker-b). With per-pane targeting the write goes to PM's
# pane regardless of who's focused.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

PAUSE='⏸️ '
PLAY='▶️ '

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  # Pin the live zellij session name (#167) so the identity check has a stable
  # baseline rather than inheriting the suite's own session; restart/concurrency
  # tests override it per-invocation.
  export ZELLIJ_SESSION_NAME=live-server
  export TASK_FORCE_ROLE=test-runner
  # Don't let the dev shell's $ZELLIJ_TAB fire the _rename_tab safeguard
  # during the initial registers; the bug-1 test re-sets it per-call to
  # simulate worker-a's pane context.
  unset ZELLIJ_TAB
  # pm=tab 7 pane 700; worker-a=tab 8 pane 800; worker-b=tab 9 pane 900.
  seed_zellij_tabs pm worker-a worker-b
}

teardown() {
  teardown_all
}

# ----- Bug 1: rename does not leak to the focused tab ----------------------

@test "worker-a's ready/busy renames worker-a's tab id, never pm's (#102 bug 1)" {
  # Register both roles so each has a session file with TAB= set.
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  # Clear the call log so we only inspect what the worker's flip emits.
  : > "$STUB_CALLS_DIR/zellij.calls"

  # Simulate: user is focused on PM. Worker-a fires its ready hook from its
  # own pane (so ZELLIJ_TAB=worker-a per the env that task-work set on the
  # pane). The rename must hit tab_id=8 (worker-a), never tab_id=7 (pm).
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" busy

  run stub_calls zellij
  # Only the worker's tab id appears in any rename-tab-by-id call.
  assert_output --partial "action rename-tab-by-id 8 ${PLAY}worker-a"
  refute_output --partial "action rename-tab-by-id 7"
  # And the unsafe focused-tab form (`rename-tab <name>` with no `-by-id`)
  # never appears.
  run bash -c "grep -E 'action rename-tab [^-]' '$STUB_CALLS_DIR/zellij.calls' || true"
  assert_output ""
}

@test "pm.info TAB= is untouched when a different role's _rename_tab runs (#102 bug 1)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude

  # After both registers, both session files have TAB= set to their idle
  # paint. Now run the worker through busy → ready and verify pm's TAB=
  # never changes.
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" busy
  ZELLIJ_TAB=worker-a TASK_FORCE_ROLE=worker-a "$RADIO" ready

  run grep "^TAB=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB=${PAUSE}pm"
}

# ----- Bug 2: wake-up does not leak to the focused tab ---------------------

@test "send writes 'radio check' to pm's pane regardless of which tab is focused (#102 bug 2)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  TASK_FORCE_ROLE=worker-b  "$RADIO" register --role worker-b  --tab worker-b  --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  # User focused on worker-a; worker-b runs `radio send --to pm`. The pane-id
  # write must target pm's pane (700), never worker-a's (800) or worker-b's
  # (900). And the previous focus-stealing `go-to-tab-name` must not appear.
  TASK_FORCE_ROLE=worker-b "$RADIO" send --to pm --intent review-requested --pr 1 --body "PR up"

  run stub_calls zellij
  assert_output --partial "action write-chars --pane-id 700 radio check"
  refute_output --partial "--pane-id 800"
  refute_output --partial "--pane-id 900"
  refute_output --partial "go-to-tab-name"
}

# ----- TAB_ID= invariants (#102 review feedback) ----------------------------

@test "send wakes by id despite an emoji-prefix drift between TAB= and the live name (#167)" {
  # The realistic TAB= drift: it lags the live tab name by an idle↔busy emoji
  # flip (a partial state change). Under the #167 identity check both sides are
  # stripped of emoji before comparison, so a pure prefix difference still
  # verifies and id-wake stands — only a genuine *bare*-name change triggers
  # recovery. (This supersedes the pre-#167 "trust the id regardless of TAB="
  # contract: the id is trusted precisely because name-at-id still matches.)
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude   # TAB_ID=7, TAB="⏸️ pm"
  # Live tab at id 7 now reads busy; pm.info TAB= still says idle — bare "pm"
  # on both sides.
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "▶️ pm", "tab_id": 7},
    {"name": "pm", "tab_id": 7},
    {"name": "⏸️ pm", "tab_id": 7}
  ]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-a "$RADIO" send --to pm --intent ping --body "still here?"

  # The write lands on pm's pane (700) via the verified TAB_ID=7.
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

@test "send hits the correct pane when two zellij tabs share a name (#102 review)" {
  # The exact corrupted state the PM's live repro produced: two tabs both
  # named "⏸️ pm". By-name lookup would pick the first match — which is
  # exactly the focused-tab bug we're closing out. TAB_ID= pins the address.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude   # captures TAB_ID=7
  # Override the fixture: two tabs with the same name, the collision id is
  # listed first so a naive `.[0]` name lookup would resolve to it.
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "pm", "tab_id": 99},
    {"name": "⏸️ pm", "tab_id": 99},
    {"name": "▶️ pm", "tab_id": 99},
    {"name": "pm", "tab_id": 7},
    {"name": "⏸️ pm", "tab_id": 7},
    {"name": "▶️ pm", "tab_id": 7}
  ]'
  export STUB_ZELLIJ_PANES_JSON='[
    {"id": 9900, "is_plugin": false, "is_focused": true, "tab_id": 99},
    {"id": 700, "is_plugin": false, "is_focused": true, "tab_id": 7}
  ]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-a "$RADIO" send --to pm --intent ping --body "hi"

  run stub_calls zellij
  # Hits pm's real pane via TAB_ID=7, never the collision's pane.
  assert_output --partial "action write-chars --pane-id 700 radio check"
  refute_output --partial "--pane-id 9900"
}

@test "register persists TAB_ID= alongside TAB= (#102 review)" {
  # The contract that lets the two tests above work — TAB_ID is captured
  # once at register and never re-resolved by name during normal operation.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID=7"
}

@test "register leaves TAB_ID= empty when zellij is unavailable (#102 review)" {
  # Non-zellij CI / first-register-before-zellij paths must still register
  # cleanly — TAB_ID= just stays empty so the next consumer can either
  # fall back to a name lookup (_rename_tab) or queue the message (cmd_send).
  unset ZELLIJ
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID="
}

# ----- stale zellij session across a restart (#167) -------------------------

@test "register persists ZELLIJ_SESSION= alongside TAB_ID= (#167)" {
  # The contract that lets the stale-session guard work: register binds the
  # captured TAB_ID to the zellij server instance it came from.
  ZELLIJ_SESSION_NAME=main TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=main"
}

@test "register's #117 preserve path keeps the recorded session, not the current one (#167 review #3)" {
  # First register under old-server captures TAB_ID=7 / ZELLIJ_SESSION=old-server.
  # A re-register whose list-tabs lookup misses (the #117 emoji-repaint case,
  # simulated by an empty fixture) must preserve BOTH the old id and its old
  # session — stamping the *current* name onto the *old* id would launder the
  # stale binding (recorded==current forever), defeating the very check meant
  # to catch it.
  ZELLIJ_SESSION_NAME=old-server TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_TABS_JSON='[]'
  ZELLIJ_SESSION_NAME=new-server TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude

  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID=7"
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=old-server"
}

@test "_rename_tab refuses a stale TAB_ID and re-resolves the role's tab by name (#167)" {
  # pm registered under old-server (TAB_ID=7). zellij restarts; pm's tab returns
  # under a fresh id 42 in new-server. A state flip must rename tab 42 (found by
  # name), never the stale id 7 that some unrelated tab may now own — then
  # repair the .info so subsequent renames/wakes are id-driven again.
  ZELLIJ_SESSION_NAME=old-server TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "pm", "tab_id": 42},
    {"name": "⏸️ pm", "tab_id": 42},
    {"name": "▶️ pm", "tab_id": 42}
  ]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  ZELLIJ_TAB=pm ZELLIJ_SESSION_NAME=new-server TASK_FORCE_ROLE=pm "$RADIO" busy

  run stub_calls zellij
  assert_output --partial "action rename-tab-by-id 42 ${PLAY}pm"
  refute_output --partial "rename-tab-by-id 7"

  # Session file repaired: id + session now reflect the live server.
  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID=42"
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=new-server"
}

@test "send still no-ops to a busy recipient even with multiple workers focused (#102 bug 2)" {
  TASK_FORCE_ROLE=pm        "$RADIO" register --role pm        --tab pm        --agent claude
  TASK_FORCE_ROLE=pm        "$RADIO" busy
  TASK_FORCE_ROLE=worker-a  "$RADIO" register --role worker-a  --tab worker-a  --agent claude
  TASK_FORCE_ROLE=worker-b  "$RADIO" register --role worker-b  --tab worker-b  --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-b "$RADIO" send --to pm --intent ping --body "queue"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  # Message still queued for pm.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}
