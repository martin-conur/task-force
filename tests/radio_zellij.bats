#!/usr/bin/env bats
# Integration tests for bin/radio against a mocked zellij stub. Asserts that
# `radio send` resolves the recipient's tab/pane and calls
# `zellij action write-chars --pane-id <pane> "radio check\n"` when the
# recipient is idle, without yanking the user's focus via `go-to-tab-name`
# (#102); and does NOT call zellij when the recipient is busy.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session-name
  # Bypass the no-role dispatcher gate on `register` (#93); tests still set
  # TASK_FORCE_ROLE per-invocation where the value matters.
  export TASK_FORCE_ROLE=test-runner
  # Don't let the dev shell's $ZELLIJ_TAB fire the _rename_tab safeguard
  # during the `radio register` call each test makes.
  unset ZELLIJ_TAB
  # pm gets tab_id=7, pane_id=700; worker-foo gets tab_id=8, pane_id=800.
  seed_zellij_tabs pm worker-foo
}

teardown() {
  teardown_all
}

# ----- idle: should write "radio check\n" straight to the recipient's pane --

@test "send to idle recipient writes 'radio check' to recipient's pane by id" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  # Per-pane write — no focus switch leaks across panes (#102).
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
  run stub_calls zellij
  refute_output --partial "go-to-tab-name"
}

# ----- delivered: sender is told the wake landed (#166) ---------------------

@test "send to idle recipient prints the delivered outcome on stdout (#166)" {
  # pm registered with tab_id=7; a successful write-chars must report back so
  # the sending agent knows the ping actually woke pm (not just queued).
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
}

# ----- busy: no zellij wake calls at all -----------------------------------

@test "send to busy recipient does not call zellij wake actions" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=pm "$RADIO" busy
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent review-requested --body "PR up"

  run stub_calls zellij
  refute_output --partial "go-to-tab-name"
  refute_output --partial "write-chars"

  # And the message should still be queued for the recipient.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}

# ----- ZELLIJ unset: graceful no-op ----------------------------------------

@test "send is a silent no-op when \$ZELLIJ is unset (recipient still queues)" {
  unset ZELLIJ
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to pm --intent ping --body "queue me"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "1"
}

# ----- recipient's tab no longer exists in zellij --------------------------

@test "send queues silently when recipient's tab has no writable panes (#102)" {
  # Register pm so TAB_ID=7 is captured, then wipe the panes fixture so the
  # `list-panes --json --tab` lookup returns []. The session file's TAB_ID=
  # is still resolvable on paper, but there's no pane to write to — this is
  # the "zellij tab was closed out from under us" case. Wake-up must queue
  # rather than fall through to a focused-tab write.
  "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_PANES_JSON='[]'

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"

  # Idle recipient but no pane to wake → honest queued/idle-wake-failed line (#166).
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (no writable pane on its tab)"

  run stub_calls zellij
  refute_output --partial "write-chars"
  refute_output --partial "go-to-tab-name"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "no writable pane on tab_id=7"
}

# ----- remaining wake-failed reasons, pinned via the stub (#166) ------------

@test "send to idle recipient whose TAB= is blank prints the no-tab wake-failed line (#166)" {
  "$RADIO" register --role pm --tab pm --agent claude
  # Blank the TAB= field so the rtab guard fires before pane resolution.
  awk '/^TAB=/{print "TAB="; next} {print}' \
    "$TASK_FORCE_HOME/radio/sessions/pm.info" > "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp"
  mv "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp" "$TASK_FORCE_HOME/radio/sessions/pm.info"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (recipient has no tab)"
}

@test "send to idle recipient whose TAB_ID= is blank prints the not-registered wake-failed line (#166)" {
  "$RADIO" register --role pm --tab pm --agent claude
  # Blank only TAB_ID= (keep TAB=) — the "registered outside zellij" shape.
  awk '/^TAB_ID=/{print "TAB_ID="; next} {print}' \
    "$TASK_FORCE_HOME/radio/sessions/pm.info" > "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp"
  mv "$TASK_FORCE_HOME/radio/sessions/pm.info.tmp" "$TASK_FORCE_HOME/radio/sessions/pm.info"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (not zellij-registered)"
}

@test "send whose write-chars call fails prints the write-chars-failed wake-failed line (#166)" {
  "$RADIO" register --role pm --tab pm --agent claude
  export STUB_ZELLIJ_WRITE_CHARS_FAIL=1   # pane resolves, but the write returns non-zero

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (write-chars failed)"
  # The write was attempted (reached the pane) before failing.
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

# ----- stale zellij session across a restart (#167) -------------------------

@test "send refuses a stale TAB_ID and queues when the recorded zellij session is gone (#167)" {
  # pm registers under one zellij server; its .info records TAB_ID=7 bound to
  # ZELLIJ_SESSION=old-server. zellij then restarts (crash/reboot) — the sender
  # is now in a fresh server and pm's tab no longer exists under any name. The
  # stale id 7 may now belong to an unrelated tab, so wake-up must NOT write to
  # it; it queues with the stale-session outcome instead.
  export ZELLIJ_SESSION_NAME=old-server
  "$RADIO" register --role pm --tab pm --agent claude
  export ZELLIJ_SESSION_NAME=new-server
  export STUB_ZELLIJ_TABS_JSON='[]'
  export STUB_ZELLIJ_PANES_JSON='[]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (stale zellij session)"

  run stub_calls zellij
  # The whole point: never write-chars into the tab that now owns the stale id.
  refute_output --partial "write-chars"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "stale zellij session — id wake refused"
}

@test "send recovers by name and repairs the session file after a zellij restart (#167)" {
  # Same restart, but pm's tab genuinely came back — under a fresh id 42 in the
  # new server. Wake-up must resolve pm by name, write to id 42's pane (never
  # the stale 7), and repair the .info so the next send is id-driven again.
  export ZELLIJ_SESSION_NAME=old-server
  "$RADIO" register --role pm --tab pm --agent claude
  export ZELLIJ_SESSION_NAME=new-server
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "pm", "tab_id": 42},
    {"name": "⏸️ pm", "tab_id": 42},
    {"name": "▶️ pm", "tab_id": 42}
  ]'
  export STUB_ZELLIJ_PANES_JSON='[
    {"id": 4200, "is_plugin": false, "is_focused": true, "tab_id": 42}
  ]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=42)"

  run stub_calls zellij
  assert_output --partial "action write-chars --pane-id 4200 radio check"
  refute_output --partial "--pane-id 700"

  # The session file is repaired: id + session now reflect the live server.
  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID=42"
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=new-server"
}

@test "send wakes by id when the recorded zellij session matches the live server (#167)" {
  # No restart: recorded ZELLIJ_SESSION == live $ZELLIJ_SESSION_NAME, so the
  # stale guard is a no-op and the fast id path stands.
  export ZELLIJ_SESSION_NAME=main
  "$RADIO" register --role pm --tab pm --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
  run stub_calls zellij
  assert_output --partial "action write-chars --pane-id 700 radio check"
}

@test "send treats an empty recorded ZELLIJ_SESSION as non-stale (#167)" {
  # Recipient registered outside zellij / before #167: ZELLIJ_SESSION= empty.
  # A live sender in a named session must NOT trip the stale guard — empty means
  # "unknown", so the id path stays available and non-zellij paths are unchanged.
  unset ZELLIJ_SESSION_NAME
  "$RADIO" register --role pm --tab pm --agent claude
  export ZELLIJ_SESSION_NAME=some-server
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
}
