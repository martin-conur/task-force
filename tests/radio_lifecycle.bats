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

# ----- re-register preserves TAB_ID on zellij lookup miss (#117, #140) ------
#
# The #117 failure mode: a worker's $ZELLIJ_TAB env var sticks to the bare
# slug captured at pane creation, but the visible tab name has since been
# painted to "⏸️ <slug>" / "▶️ <slug>" by _rename_tab. When SessionStart
# fires a second time (because of /compact, /clear, /resume, or a fresh
# `claude` in the same tab), the hook re-runs `radio register --tab $ZELLIJ_TAB`
# with the bare slug. Pre-#140, the literal-name lookup missed and we relied
# on the in-file preservation fallback (which only works for register, not
# for _ensure_session_file). Post-#140, _zellij_tab_id_by_name itself matches
# both the bare slug and the emoji-prefixed variants — so the lookup
# succeeds for real, and the preservation path only fires when zellij is
# genuinely unreachable.

@test "register: lookup resolves through emoji-prefixed visible name (#140 Fix B)" {
  setup_stubs
  export ZELLIJ=fake
  # Only the painted name is advertised — no bare-slug entry. This is the
  # actual state of zellij after _rename_tab has flipped the tab to "▶️".
  export STUB_ZELLIJ_TABS_JSON='[{"name":"▶️ worker-foo","tab_id":7}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id":700,"is_plugin":false,"is_focused":true,"tab_id":7}]'

  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"
  run cat "$TASK_FORCE_HOME/radio/log"
  # Direct resolution — no "preserving" path needed.
  refute_output --partial "could not resolve tab_id for tab=worker-foo"
}

@test "register: lookup resolves through idle ⏸️ prefixed visible name (#140 Fix B)" {
  setup_stubs
  export ZELLIJ=fake
  export STUB_ZELLIJ_TABS_JSON='[{"name":"⏸️ worker-foo","tab_id":7}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id":700,"is_plugin":false,"is_focused":true,"tab_id":7}]'

  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"
}

@test "register: re-register preserves existing TAB_ID when zellij is truly unreachable (#117)" {
  setup_stubs
  seed_zellij_tabs worker-foo
  export ZELLIJ=fake

  # First register: finds tab_id=7 by name and persists it.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output --partial "TAB_ID=7"

  # Now simulate zellij being completely unreachable for the second
  # register: empty list-tabs JSON (zellij died, jq misparsed, anything that
  # leaves the lookup with zero matches). The #117 in-file preservation
  # path must still kick in.
  export STUB_ZELLIJ_TABS_JSON='[]'

  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  # TAB_ID must still be 7 — preserved, not clobbered to empty.
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "preserving existing TAB_ID=7"
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

# ----- #140: re-seed after unregister cascade preserves TAB_ID + LOADOUT ----
#
# Reproduces the corruption documented in #140: an unregister cascade wipes
# the session file mid-life; _ensure_session_file re-seeds when the next
# busy/ready hook fires. Before #140, the re-seed lost two fields:
#   - TAB_ID: empty, because _zellij_tab_id_by_name did exact-match against
#     the painted (emoji-prefixed) tab name and missed.
#   - LOADOUT: literal "unknown", because $TASK_FORCE_LOADOUT isn't set in
#     Claude Code's hook subshell (task-work exports it at launch time only).
#
# Combined effect: cmd_send couldn't wake the worker (no TAB_ID for the
# zellij write-chars target), so --auto workers stopped being auto.

@test "re-seed after unregister recovers TAB_ID through emoji-prefixed tab name (#140 Bug B)" {
  setup_stubs
  seed_zellij_tabs worker-foo
  export ZELLIJ=fake

  # Initial register: file has TAB_ID=7, LOADOUT=claude-gh.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"

  # Cascade wipe — the same unregister storm reproduced in #140's log.
  rm -f "$sess"

  # By now the visible tab is painted "▶️ worker-foo" by _rename_tab. Re-seed
  # the stub fixture so only the painted variant is advertised. Pre-#140
  # the lookup would miss and TAB_ID= would be written empty.
  export STUB_ZELLIJ_TABS_JSON='[{"name":"▶️ worker-foo","tab_id":7}]'
  export STUB_ZELLIJ_PANES_JSON='[{"id":700,"is_plugin":false,"is_focused":true,"tab_id":7}]'

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run "$RADIO" busy
  assert_success
  run grep "^TAB_ID=" "$sess"
  assert_output "TAB_ID=7"
}

@test "re-seed after unregister recovers LOADOUT from sidecar (#140 Bug C)" {
  # _ensure_session_file's previous fallback "${TASK_FORCE_LOADOUT:-unknown}"
  # wrote the literal "unknown" because hook subshells don't inherit
  # task-work's launch-time env. The sidecar persists the loadout name
  # alongside the session file at register time so the re-seed can recover.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  run grep "^LOADOUT=" "$sess"
  assert_output "LOADOUT=claude-gh"

  # Cascade wipe.
  rm -f "$sess"

  # Re-seed via busy hook — note: $TASK_FORCE_LOADOUT is *not* exported (it
  # wouldn't be, in Claude Code's hook subshell). The sidecar is the only
  # available source for the loadout name.
  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run env -u TASK_FORCE_LOADOUT "$RADIO" busy
  assert_success
  run grep "^LOADOUT=" "$sess"
  assert_output "LOADOUT=claude-gh"
  refute_output --partial "unknown"
}

@test "re-seed survives when sidecar read fails (#150 round-2 review: TOCTOU on unconditional cat)" {
  # _ensure_session_file does an unconditional `cat "$sidecar" 2>/dev/null
  # || true` — no `[[ -f ]]` pre-check. The TOCTOU guard must convert any
  # read failure (file absent, unlinked mid-read by concurrent unregister,
  # unreadable) into "empty string" without tripping set -e. Otherwise the
  # function aborts mid-re-seed and STATE tracking dies for the worker's
  # lifetime.
  #
  # We exercise the failure path by making the sidecar unreadable
  # (chmod 0). cat returns ENOENT-equivalent (EACCES); without `|| true`,
  # set -e propagates and `radio busy` exits non-zero. With it, the read
  # returns empty and we fall through to the env-var fallback (unset →
  # "unknown") — assert that fallback fired, not just that the script
  # completed.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  rm -f "$sess"

  chmod 0 "$sidecar"

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run env -u TASK_FORCE_LOADOUT "$RADIO" busy
  # Restore permission so teardown can clean up.
  chmod 644 "$sidecar"
  assert_success
  assert [ -f "$sess" ]
  run grep "^STATE=" "$sess"
  assert_output "STATE=busy"
  # Fallback value confirms the read returned empty AND the env-var
  # fallback fired — not that cat silently succeeded.
  run grep "^LOADOUT=" "$sess"
  assert_output "LOADOUT=unknown"
}

@test "re-seed survives when sidecar is absent at read time (#150 review: TOCTOU, unlink variant)" {
  # Companion to the chmod variant above: sidecar deleted before the
  # busy hook fires (the realistic cascade pattern — unregister wipes
  # both .info and .loadout, then the next hook event re-seeds). The
  # unconditional `cat` must collapse to empty without aborting; the
  # env-var fallback handles the LOADOUT.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"

  rm -f "$sess" "$sidecar"

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run env -u TASK_FORCE_LOADOUT "$RADIO" busy
  assert_success
  assert [ -f "$sess" ]
  run grep "^LOADOUT=" "$sess"
  assert_output "LOADOUT=unknown"
}

@test "re-seed recovers LOADOUT when .info-write was killed but sidecar landed first (#150 round-3 review: Finding 1)" {
  # Models the kill-window the reviewer flagged: cmd_register writes the
  # sidecar BEFORE the session file (post-#150-r3), so if the process is
  # killed between the two writes, the sidecar exists but .info doesn't.
  # The next re-seed should find the sidecar and recover LOADOUT correctly
  # instead of writing "unknown".
  #
  # Simulate by registering normally, then deleting only .info (matches
  # the "sidecar landed, info didn't" state). Pre-r3 (write-info-first
  # order) this state was unreachable except through manual file
  # manipulation; post-r3 it's the natural mid-kill snapshot.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  assert [ -f "$sidecar" ]
  rm -f "$sess"
  assert [ -f "$sidecar" ]

  TASK_FORCE_ROLE=worker-foo ZELLIJ_TAB=worker-foo run env -u TASK_FORCE_LOADOUT "$RADIO" busy
  assert_success
  run grep "^LOADOUT=" "$sess"
  assert_output "LOADOUT=claude-gh"
}

@test "register: writes sidecar before .info so a kill mid-call leaves sidecar recoverable (#150 round-3 review: Finding 1)" {
  # Direct assertion of the write-order invariant: a kill that interrupts
  # cmd_register between the sidecar write and the .info write must leave
  # the system in a state that a subsequent re-seed can recover. Inverse
  # case (sidecar absent but .info present) would be unrecoverable —
  # that's the pre-r3 failure mode.
  #
  # We can't actually kill in the middle of a real register, but we can
  # assert the timestamps: sidecar's mtime must be ≤ .info's mtime. (On
  # POSIX, stat -f vs -c differ; use `find -newer` to compare without
  # parsing.)
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  assert [ -f "$sess" ]
  assert [ -f "$sidecar" ]
  # If sidecar were written AFTER .info, .info would be `-newer` than
  # sidecar would be false (sidecar would be newer). Assert .info is
  # newer-or-equal to sidecar.
  run find "$sess" -newer "$sidecar"
  # `find -newer` prints the file if it's STRICTLY newer. .info written
  # immediately after sidecar may share the same mtime resolution on
  # fast filesystems — either output (the path or empty) is fine; what
  # matters is that sidecar isn't newer than .info.
  run find "$sidecar" -newer "$sess"
  refute_output --partial "$sidecar"
}

@test "register: writes loadout sidecar alongside session file (#140 Bug C)" {
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  assert [ -f "$sidecar" ]
  run cat "$sidecar"
  assert_output "claude-gh"
}

@test "unregister: sweeps loadout sidecar so a stale value can't leak to the next role lifecycle (#140)" {
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sess="$TASK_FORCE_HOME/radio/sessions/worker-foo.info"
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  assert [ -f "$sidecar" ]

  # Real exit unregister (reason=logout slips past the skip-list, file
  # deleted, sidecar deleted).
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"logout\"}' | '$RADIO' unregister"
  assert_success
  assert [ ! -f "$sess" ]
  assert [ ! -f "$sidecar" ]
}

@test "unregister: skipped unregister (reason=clear) does NOT sweep loadout sidecar (#140)" {
  # The skip-list applies symmetrically to both: if we don't delete .info,
  # we mustn't delete .loadout either. Otherwise a subsequent re-seed would
  # write LOADOUT=unknown despite the unregister having been a no-op.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude --loadout claude-gh
  local sidecar="$TASK_FORCE_HOME/radio/sessions/worker-foo.loadout"
  assert [ -f "$sidecar" ]

  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"clear\"}' | '$RADIO' unregister"
  assert_success
  assert [ -f "$sidecar" ]
}

@test "unregister: logs full payload when proceeding past the skip-list (#140 Fix A instrumentation)" {
  # When the cascade fires with a reason we don't recognise (or no reason
  # at all), we still proceed with the delete — but log the full payload so
  # we can investigate what's driving the cascade. Without the payload in
  # the log, the cascade is invisible.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"reason\":\"weird_event\",\"extra\":\"data\"}' | '$RADIO' unregister"
  assert_success
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "unregister: proceeding (reason=weird_event)"
  assert_output --partial "payload="
  assert_output --partial "weird_event"
  assert_output --partial "extra"
}

@test "unregister: logs payload even when reason is missing (#140 Fix A instrumentation)" {
  # The smoking gun in #140 was unregister calls with no parseable reason.
  # Make sure we log the payload then too.
  "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  TASK_FORCE_ROLE=worker-foo run bash -c "echo '{\"other\":\"value\"}' | '$RADIO' unregister"
  assert_success
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "unregister: proceeding (reason=<unset>)"
  assert_output --partial "payload="
}
