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
  # Pin the live zellij session name (#167) so the identity check has a stable
  # baseline instead of inheriting whatever session the suite runs inside.
  # recorded==live here, so the guard verifies tab-name-at-id (the seeded tabs
  # all resolve) and legacy wake paths behave deterministically. Tests that
  # simulate a restart override ZELLIJ_SESSION_NAME per-invocation.
  export ZELLIJ_SESSION_NAME=live-server
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

# ----- stale TAB_ID across a zellij restart (#167, verify-name-at-id reframe) --

@test "send verifies tab-name-at-id and wakes by id when it still matches (#167)" {
  # No restart: the tab at recorded TAB_ID=7 still bears pm's bare name, so the
  # identity check passes and the fast id path stands.
  "$RADIO" register --role pm --tab pm --agent claude
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
  run stub_calls zellij
  assert_output --partial "action write-chars --pane-id 700 radio check"
}

@test "send refuses a stale TAB_ID when the tab at that id no longer bears pm's name (#167)" {
  # Same-named-session restart — the case a session-name compare would MISS:
  # recorded ZELLIJ_SESSION == live (both 'live-server', as with `attach -c`),
  # but after the restart id 7 now hosts an unrelated tab. The identity check
  # (name-at-id) catches it; with pm's tab gone by name too, wake-up queues and
  # never writes into the tab that inherited id 7.
  "$RADIO" register --role pm --tab pm --agent claude
  # id 7 now belongs to someone else's tab; pm's tab is gone.
  export STUB_ZELLIJ_TABS_JSON='[{"name": "some-other-tab", "tab_id": 7}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id": 700, "is_plugin": false, "is_focused": true, "tab_id": 7}]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent review-requested --body "PR up"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (stale or unreachable tab)"

  run stub_calls zellij
  # The whole point: never write-chars into the tab that inherited the stale id.
  refute_output --partial "write-chars"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "tab id unresolved"
}

@test "send recovers by name and repairs the session file after a zellij restart (#167)" {
  # Restart, and pm's tab genuinely came back — under a fresh id 42. The id-7
  # verification fails (nothing at 7), name recovery finds 42, wake-up writes to
  # 42's pane (never the stale 7), and the .info is repaired to be id-driven.
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

@test "send queues (never misdelivers) when pm's recorded session is alive in another server (#167 review #2)" {
  # Concurrency, not restart: pm.info was registered by a DIFFERENT, still-live
  # zellij server ('other-server'). This server happens to have its own tab 7
  # named 'pm' — a look-alike. Delivering by id here would write into the wrong
  # session's pm; repairing would rewrite the live owner's file (ping-pong). The
  # liveness guard must queue instead, touching neither.
  export ZELLIJ_SESSION_NAME=other-server
  "$RADIO" register --role pm --tab pm --agent claude   # pm.info: session=other-server, id=7
  export ZELLIJ_SESSION_NAME=this-server
  # other-server is still listed as a live (non-EXITED) session.
  export STUB_ZELLIJ_SESSIONS='other-server [Created 1h ago]
this-server [Created 5m ago] (current)'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: queued — pm is idle but wake failed (stale or unreachable tab)"

  run stub_calls zellij
  refute_output --partial "write-chars"
  # The live owner's file is untouched — still bound to other-server.
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=other-server"
}

@test "recovery repair does not blank ZELLIJ_SESSION when the live session name is empty (#167 review #8)" {
  # If the current server name is unknown (ZELLIJ set, ZELLIJ_SESSION_NAME
  # empty), a name-recovery repair must restamp only TAB_ID — not overwrite
  # ZELLIJ_SESSION with "" and drop the file into the unguarded class.
  export ZELLIJ_SESSION_NAME=old-server
  "$RADIO" register --role pm --tab pm --agent claude   # id 7, session old-server
  unset ZELLIJ_SESSION_NAME
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "pm", "tab_id": 42},
    {"name": "⏸️ pm", "tab_id": 42},
    {"name": "▶️ pm", "tab_id": 42}
  ]'
  export STUB_ZELLIJ_PANES_JSON='[{"id": 4200, "is_plugin": false, "is_focused": true, "tab_id": 42}]'
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=42)"
  # TAB_ID repaired to the fresh id, ZELLIJ_SESSION left intact (not blanked).
  run grep "^TAB_ID=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "TAB_ID=42"
  run grep "^ZELLIJ_SESSION=" "$TASK_FORCE_HOME/radio/sessions/pm.info"
  assert_output "ZELLIJ_SESSION=old-server"
}

@test "send treats a legacy session file with no ZELLIJ_SESSION line via the identity check (#167)" {
  # A pre-#167 session file has TAB_ID set and NO ZELLIJ_SESSION line at all.
  # Grandfathering (empty == never-stale) would keep the bug; instead it takes
  # the ordinary identity path — the tab at id 7 still bears pm's name, so it
  # wakes by id and works, no special-casing.
  "$RADIO" register --role pm --tab pm --agent claude
  sed -i.bak '/^ZELLIJ_SESSION=/d' "$TASK_FORCE_HOME/radio/sessions/pm.info"
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to pm --intent ping --body "hi"
  assert_success
  assert_output --partial "radio: delivered — woke pm (tab_id=7)"
}
