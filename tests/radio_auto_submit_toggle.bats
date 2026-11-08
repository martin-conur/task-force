#!/usr/bin/env bats
# `radio auto-submit on|off|status` (#385): switch a running role, a PM left
# running while the user is away, between auto-submitted and Enter-gated wakes
# without a relaunch.
#
# Contract:
#   - on/off rewrite AUTO_SUBMIT in the session file and the `<role>.auto-submit`
#     sidecar, so the next send picks it up; status prints the state, the
#     expiry and the note.
#   - The setting lives in `<role>.away` and outranks the launch env on a
#     /compact or /clear re-register. An `on` survives a fresh register too (a
#     PM rotation); an `off` gives way to a fresh register that states its own.
#   - `on --for` / `--until` expire: the first send after the expiry types LF,
#     logs `auto-submit: expired role=…` once, and clears the setting.
#   - The note is repeated by `radio check` (what every wake types) while the
#     role auto-submits, and on every register; the typed wake stays the
#     literal `radio check`.
#   - A call with no derivable role refuses.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session
  unset ZELLIJ_TAB TASK_FORCE_AUTO_SUBMIT
  # pm gets tab_id=7, pane_id=700.
  seed_zellij_tabs pm worker-foo
  export TASK_FORCE_ROLE=pm
  SESS="$TASK_FORCE_HOME/radio/sessions"
}

teardown() {
  teardown_all
}

# A PM launched the default way: task-pm says TASK_FORCE_AUTO_SUBMIT=0.
_register_pm() {
  TASK_FORCE_AUTO_SUBMIT="${1:-0}" "$RADIO" register --role pm --tab pm --agent claude </dev/null >/dev/null
}

_send_to_pm() {
  : >"$STUB_CALLS_DIR/zellij.calls"
  TASK_FORCE_ROLE=worker-foo "$RADIO" send --to "${1:-pm}" --intent review-requested --body "PR up" >/dev/null
}

_cr_wakes() { grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls" || true; }

_iso_in() {
  local e=$(( $(date -u +%s) + $1 ))
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ
}

# ----- on / off / status ------------------------------------------------------

@test "on rewrites AUTO_SUBMIT in the session file and the sidecar, and the next send types CR" {
  _register_pm
  run cat "$SESS/pm.info"
  refute_output --partial "AUTO_SUBMIT=1"

  run "$RADIO" auto-submit on
  assert_success
  assert_output --partial "auto-submit on for pm (no expiry"
  run cat "$SESS/pm.info"
  assert_output --partial "AUTO_SUBMIT=1"
  run cat "$SESS/pm.auto-submit"
  assert_output "1"

  _send_to_pm
  run _cr_wakes
  assert_output "1"
}

@test "off rewrites both back, and the next send types LF" {
  _register_pm 1
  run "$RADIO" auto-submit off
  assert_success
  assert_output --partial "auto-submit off for pm"
  run cat "$SESS/pm.info"
  refute_output --partial "AUTO_SUBMIT=1"
  run cat "$SESS/pm.auto-submit"
  assert_output "0"

  _send_to_pm
  run _cr_wakes
  assert_output "0"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
}

@test "status prints on/off, the expiry and the note" {
  _register_pm
  run "$RADIO" auto-submit status
  assert_success
  assert_output --partial "auto-submit off for pm (from its launch)"

  local until; until=$(_iso_in 7200)
  "$RADIO" auto-submit on --until "$until" --note "finish #377, no merges" >/dev/null
  run "$RADIO" auto-submit status
  assert_output --partial "auto-submit on for pm (until $until; set with radio auto-submit)"
  assert_output --partial "note: finish #377, no merges"
}

@test "status reports what the next wake does, not the caller's launch env" {
  _register_pm 1
  run env TASK_FORCE_AUTO_SUBMIT=0 "$RADIO" auto-submit status
  assert_output --partial "auto-submit on for pm (no expiry; from its launch)"
  _register_pm 0
  run env TASK_FORCE_AUTO_SUBMIT=1 "$RADIO" auto-submit status
  assert_output --partial "auto-submit off for pm (from its launch)"
}

@test "on --note - reads the note from stdin, verbatim" {
  _register_pm
  "$RADIO" auto-submit on --note - <<'NOTE' >/dev/null
review `task-done` but do not merge
second line
NOTE
  run cat "$SESS/pm.away-note"
  assert_line --index 0 'review `task-done` but do not merge'
  assert_line --index 1 'second line'
}

@test "a plain off clears the expiry and the note" {
  _register_pm
  "$RADIO" auto-submit on --for 8h --note "away" >/dev/null
  run cat "$SESS/pm.info"
  assert_output --partial "AUTO_SUBMIT_UNTIL="
  "$RADIO" auto-submit off >/dev/null
  run cat "$SESS/pm.info"
  refute_output --partial "AUTO_SUBMIT_UNTIL="
  [ ! -e "$SESS/pm.away-note" ]
}

# ----- re-registers -----------------------------------------------------------

@test "a runtime on survives the /compact re-register of a process launched with 0" {
  _register_pm 0
  "$RADIO" auto-submit on >/dev/null
  _register_pm 0
  run cat "$SESS/pm.info"
  assert_output --partial "AUTO_SUBMIT=1"
  _send_to_pm
  run _cr_wakes
  assert_output "1"
}

@test "a runtime on survives a fresh register (a PM rotation), expiry included" {
  _register_pm 0
  local until; until=$(_iso_in 3600)
  "$RADIO" auto-submit on --until "$until" >/dev/null
  "$RADIO" unregister --manual </dev/null >/dev/null
  _register_pm 0
  run cat "$SESS/pm.info"
  assert_output --partial "AUTO_SUBMIT=1"
  assert_output --partial "AUTO_SUBMIT_UNTIL=$until"
}

@test "a runtime off survives a re-register with 1, and gives way to a fresh one" {
  _register_pm 1
  "$RADIO" auto-submit off >/dev/null
  _register_pm 1
  run cat "$SESS/pm.info"
  refute_output --partial "AUTO_SUBMIT=1"

  "$RADIO" unregister --manual </dev/null >/dev/null
  _register_pm 1
  run cat "$SESS/pm.info"
  assert_output --partial "AUTO_SUBMIT=1"
}

# ----- expiry -----------------------------------------------------------------

@test "on --for expires: a send after it types LF, logs it once, and clears it" {
  _register_pm
  "$RADIO" auto-submit on --for 1s --note "away" >/dev/null
  sleep 2
  _send_to_pm
  run _cr_wakes
  assert_output "0"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
  run grep -c 'auto-submit: expired role=pm' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
  run cat "$SESS/pm.info"
  refute_output --partial "AUTO_SUBMIT"
  run cat "$SESS/pm.auto-submit"
  assert_output "0"
  [ ! -e "$SESS/pm.away-note" ]

  # Once: the next send finds it already off.
  _send_to_pm
  run grep -c 'auto-submit: expired role=pm' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "on --until an ISO time expires the same way" {
  _register_pm
  run "$RADIO" auto-submit on --until "$(_iso_in 2)"
  assert_success
  _send_to_pm
  run _cr_wakes
  assert_output "1"
  sleep 3
  _send_to_pm
  run _cr_wakes
  assert_output "0"
  run grep -c 'auto-submit: expired role=pm' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "on --until HH:MM lands within the next 24 hours" {
  _register_pm
  "$RADIO" auto-submit on --until 07:30 >/dev/null
  local until e now
  until=$(grep '^UNTIL=' "$SESS/pm.away" | cut -d= -f2)
  e=$(date -u -d "$until" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$until" +%s)
  now=$(date -u +%s)
  (( e > now && e <= now + 86400 ))
}

@test "bad expiries and flags are refused before anything is written" {
  _register_pm
  run "$RADIO" auto-submit on --for soon
  assert_failure
  assert_output --partial "not a duration"
  run "$RADIO" auto-submit on --until 2001-01-01T00:00Z
  assert_failure
  assert_output --partial "in the past"
  run "$RADIO" auto-submit on --for 1h --until 07:00
  assert_failure
  run "$RADIO" auto-submit off --for 1h
  assert_failure
  run "$RADIO" auto-submit maybe
  assert_failure
  [ ! -e "$SESS/pm.away" ]
}

# ----- alias ------------------------------------------------------------------

@test "a wake to a --also alias honours the primary's runtime setting" {
  seed_zellij_tabs pm-pmrepo
  TASK_FORCE_AUTO_SUBMIT=0 "$RADIO" register --role pm-pmrepo --tab pm-pmrepo --agent claude </dev/null >/dev/null
  "$RADIO" register-alias --role pm-otherrepo --alias pm-pmrepo --repo /tmp/otherrepo

  _send_to_pm pm-otherrepo
  run _cr_wakes
  assert_output "0"

  TASK_FORCE_ROLE=pm-pmrepo "$RADIO" auto-submit on >/dev/null
  _send_to_pm pm-otherrepo
  run _cr_wakes
  assert_output "1"
}

# ----- the away note ----------------------------------------------------------

@test "the note appears on an auto-submitted wake's check and not on a manual one's" {
  _register_pm
  "$RADIO" auto-submit on --note "finish #377 and #384, review but don't merge" >/dev/null

  _send_to_pm
  run _cr_wakes
  assert_output "1"
  # The typed wake carries no caller text: the note is in check's output.
  run grep -c "finish" "$STUB_CALLS_DIR/zellij.calls"
  assert_output "0"
  run "$RADIO" check
  assert_success
  assert_output --partial "[away] finish #377 and #384, review but don't merge"

  # Manual (LF) wake: no AUTO_SUBMIT, so its check carries no note.
  _session_off() { grep -v '^AUTO_SUBMIT' "$SESS/pm.info" >"$SESS/pm.tmp"; mv "$SESS/pm.tmp" "$SESS/pm.info"; }
  _session_off
  _send_to_pm
  run _cr_wakes
  assert_output "0"
  run "$RADIO" check
  refute_output --partial "[away]"
}

@test "off drops the note from check" {
  _register_pm
  "$RADIO" auto-submit on --note "away mandate" >/dev/null
  "$RADIO" auto-submit off >/dev/null
  run "$RADIO" check
  refute_output --partial "[away]"
}

@test "every register of the role repeats the note, a /compact one included" {
  _register_pm
  "$RADIO" auto-submit on --note "away mandate" >/dev/null
  run env TASK_FORCE_AUTO_SUBMIT=0 "$RADIO" register --role pm --tab pm --agent claude </dev/null
  assert_success
  assert_output --partial "[away] away mandate"
}

# ----- role resolution and gc -------------------------------------------------

@test "a call with no derivable role refuses loudly" {
  local outside; outside=$(mktemp -d)
  cd "$outside"
  run env -u TASK_FORCE_ROLE "$RADIO" auto-submit on
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
  rm -rf "$outside"
  run ls "$SESS"
  refute_output --partial ".away"
}

@test "gc reclaims a dead role's away sidecars with the rest" {
  TASK_FORCE_ROLE=gone "$RADIO" auto-submit on --note "x" >/dev/null 2>&1
  [ -e "$SESS/gone.away" ]
  [ -e "$SESS/gone.away-note" ]
  touch -t 202001010000 "$SESS"/gone.*
  "$RADIO" gc --max-age-days 1 >/dev/null
  [ ! -e "$SESS/gone.away" ]
  [ ! -e "$SESS/gone.away-note" ]
}
