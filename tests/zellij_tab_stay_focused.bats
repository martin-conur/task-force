#!/usr/bin/env bats
# Tests for aw_launch_tab's optional `stay_on_caller_tab` 4th arg (#130).
#
# Contract pinned here:
#   - stay_on_caller_tab="1" + $ZELLIJ set + jq available  →  recorded sequence
#     is `list-tabs --json` then `new-tab …` then `go-to-tab <pos+1>`.
#   - stay_on_caller_tab="" / omitted                       →  no `list-tabs`
#     pre-lookup, no `go-to-tab` snap-back (focus moves to the new tab).
#   - task-work / task-recreate-worker pass "1" by default and "" under
#     --focus (#254).
#   - $ZELLIJ unset, or empty position from list-tabs       →  defensive gates
#     fall through to legacy behavior — never abort the spawn.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

ZELLIJ_TAB_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/zellij-tab.sh"

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  setup_task_force_home   # a private radio log for the tab-focus: lines (#311)
  cd "$MAIN_REPO"
  # shellcheck source=../lib/zellij-tab.sh
  source "$ZELLIJ_TAB_LIB"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# aw_launch_tab unit tests (sourced directly)
# ---------------------------------------------------------------------------

@test "stay_on_caller_tab=1 + ZELLIJ set: records list-tabs → new-tab → go-to-tab <pos+1>" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","tab_id":1,"position":0,"active":true},{"name":"worker-a","tab_id":2,"position":1,"active":false}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  local calls
  calls=$(stub_calls zellij)
  # list-tabs lookup must happen before new-tab; new-tab before go-to-tab.
  run grep -nE 'list-tabs --json|new-tab --name new-worker|go-to-tab 1' <<<"$calls"
  assert_success
  # Ordering check.
  local list_line new_line goto_line
  list_line=$(grep -n 'list-tabs --json' <<<"$calls" | head -1 | cut -d: -f1)
  new_line=$(grep -n 'new-tab --name new-worker' <<<"$calls" | head -1 | cut -d: -f1)
  goto_line=$(grep -n 'go-to-tab 1' <<<"$calls" | head -1 | cut -d: -f1)
  [[ -n "$list_line" && -n "$new_line" && -n "$goto_line" ]]
  (( list_line < new_line ))
  (( new_line < goto_line ))
}

@test "stay_on_caller_tab=1: go-to-tab uses position+1 (0-indexed list-tabs → 1-indexed go-to-tab)" {
  # PM is in slot position=3 (0-indexed) → go-to-tab should be called with 4.
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"a","position":0,"active":false},{"name":"b","position":1,"active":false},{"name":"c","position":2,"active":false},{"name":"pm","position":3,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  assert_stub_called zellij "go-to-tab 4"
}

@test "stay_on_caller_tab=\"\": no list-tabs pre-lookup, no go-to-tab (legacy behavior)" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" ""

  local calls
  calls=$(stub_calls zellij)
  assert_stub_called zellij "new-tab --name new-worker"
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
  # And no pre-launch list-tabs probe — the only zellij call should be new-tab.
  run grep -F 'list-tabs --json' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab omitted (3-arg call): legacy behavior" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi"

  local calls
  calls=$(stub_calls zellij)
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab=1 + ZELLIJ unset: gate falls through, no go-to-tab" {
  # No $ZELLIJ → not inside a session → skip the snap-back entirely.
  unset ZELLIJ
  STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  local calls
  calls=$(stub_calls zellij)
  assert_stub_called zellij "new-tab --name new-worker"
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
  run grep -F 'list-tabs --json' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab=1 + empty list-tabs result: no go-to-tab issued" {
  # list-tabs returns "" → jq filter yields "" → caller_pos stays empty → skip.
  ZELLIJ=1 aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  local calls
  calls=$(stub_calls zellij)
  assert_stub_called zellij "new-tab --name new-worker"
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab=1 + no active tab in list: no go-to-tab issued" {
  # list-tabs returns valid JSON but no entry has active=true → jq selects
  # nothing → caller_pos empty → skip.
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"a","position":0,"active":false},{"name":"b","position":1,"active":false}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  local calls
  calls=$(stub_calls zellij)
  assert_stub_called zellij "new-tab --name new-worker"
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab=1 + jq missing: gate falls through, no list-tabs / no go-to-tab" {
  # Override `command` as a shell function so `command -v jq` returns non-zero
  # without disturbing PATH (which the zellij stub's `#!/usr/bin/env bash`
  # shebang relies on). aw_launch_tab is sourced into this shell, so the
  # function override is visible when its `command -v jq >/dev/null 2>&1`
  # gate runs. All other lookups delegate to the real builtin.
  command() {
    if [[ "$1" == "-v" && "$2" == "jq" ]]; then return 1; fi
    builtin command "$@"
  }

  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"

  unset -f command

  local calls
  calls=$(stub_calls zellij)
  assert_stub_called zellij "new-tab --name new-worker"
  run grep -F 'list-tabs --json' <<<"$calls"
  assert_failure
  run grep -F 'go-to-tab' <<<"$calls"
  assert_failure
}

@test "stay_on_caller_tab=1 + go-to-tab exits non-zero: spawn still succeeds" {
  # If `zellij action go-to-tab` errors (e.g. stale position, race with a
  # close-tab elsewhere), the `|| true` swallow must keep aw_launch_tab from
  # propagating the failure. Worker spawn must still succeed.
  STUB_ZELLIJ_GOTO_TAB_FAIL=1 ZELLIJ=1 \
    STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  # new-tab still recorded, go-to-tab was attempted (and failed silently).
  assert_stub_called zellij "new-tab --name new-worker"
  assert_stub_called zellij "go-to-tab 1"
}

@test "stay_on_caller_tab=1 + empty cmd (no-launch path): still snaps back" {
  # The --no-launch branch from task-work passes an empty cmd. Snap-back must
  # still fire so --auto --no-launch (if ever combined) keeps PM focus.
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":2,"active":true}]' \
    aw_launch_tab "new-worker" "$MAIN_REPO" "" "1"

  assert_stub_called zellij "go-to-tab 3"
}

# ---------------------------------------------------------------------------
# The snap-back re-checks focus: zellij's async new-tab can steal it back (#311)
# ---------------------------------------------------------------------------

CALLER_ACTIVE='[{"name":"pm","position":0,"active":true},{"name":"new-worker","position":1,"active":false}]'
NEW_ACTIVE='[{"name":"pm","position":0,"active":false},{"name":"new-worker","position":1,"active":true}]'

# go-to-tab calls recorded so far.
_goto_count() { grep -c 'go-to-tab' "$STUB_CALLS_DIR/zellij.calls" || true; }
_focus_log() { grep 'tab-focus:' "$TASK_FORCE_HOME/radio/log" 2>/dev/null || true; }

@test "snap-back race: new tab still active after go-to-tab → second go-to-tab + tab-focus log line (#311)" {
  # Pre-lookup sees the caller; the first check after new-tab sees the new tab
  # (the race); after the retry the fixture reports the caller again.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n%s\n' "$CALLER_ACTIVE" "$NEW_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_equal "$(_goto_count)" 2
  # The race was corrected, so no warning (run merges stderr into $output).
  refute_output --partial "Could not keep focus on your tab"
  run _focus_log
  assert_output --partial 'tab-focus: snap-back needed 2 go-to-tab(s) slug=new-worker caller_position=0'
  assert_equal "$(grep -c . <<<"$output")" 1
}

@test "snap-back: caller active on the first check → exactly one go-to-tab, no log line (#311)" {
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  refute_output --partial "Could not keep focus on your tab"
  assert_equal "$(_goto_count)" 1
  # The re-check really ran: pre-lookup plus two consecutive caller-active
  # checks after the go-to-tab (#343).
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 3
  run _focus_log
  assert_output ''
}

@test "snap-back: stay_on_caller_tab=\"\" (--focus) issues no go-to-tab and no log line (#311)" {
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON="$NEW_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" ""
  assert_success
  assert_equal "$(_goto_count)" 0
  run _focus_log
  assert_output ''
}

@test "snap-back: caller never comes back → loop stops bounded, logs the failure, launch succeeds (#311)" {
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n' "$CALLER_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 AW_TAB_FOCUS_CHECKS=4 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$NEW_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  # One go-to-tab per check: the first, then one after each failed check but the last.
  assert_equal "$(_goto_count)" 4
  assert_output --partial "Could not keep focus on your tab: 'new-worker' may have taken it"
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 5
  run _focus_log
  assert_output --partial 'tab-focus: snap-back failed after 4 go-to-tab(s) slug=new-worker caller_position=0 active_position=1'
  assert_equal "$(grep -c . <<<"$output")" 1
}

@test "snap-back: list-tabs unusable mid-loop → stops, logs it and warns (#311, #384)" {
  # Pre-lookup sees the caller, the first check sees the new tab (so a retry
  # follows), then list-tabs answers something that is not JSON. The loop
  # cannot tell who has focus, so it stops; before #384 it stopped silently,
  # which is how a lost focus left no `tab-focus:` line at all.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n%s\n%s\n' "$CALLER_ACTIVE" "$NEW_ACTIVE" "not json" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$NEW_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_output --partial "Could not confirm focus on your tab: zellij's tab list did not answer"
  assert_equal "$(_goto_count)" 2
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 3
  run _focus_log
  assert_output --partial 'tab-focus: list-tabs unusable after 2 check(s), 2 go-to-tab(s) slug=new-worker caller_position=0'
  assert_equal "$(grep -c . <<<"$output")" 1
}

@test "snap-back: list-tabs empty on the first check → logged, not silent (#384)" {
  # The pre-lookup answers; every list-tabs after the new-tab answers nothing.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n' "$CALLER_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_output --partial "Could not confirm focus on your tab"
  run _focus_log
  assert_output --partial 'tab-focus: list-tabs unusable after 1 check(s), 1 go-to-tab(s) slug=new-worker'
}

@test "snap-back: a stalled list-tabs is bounded, logged as zellij-timeout and as unusable (#384)" {
  # The stub hangs every list-tabs, the pre-lookup's included, so this runs
  # the snap-back directly, as aw_launch_tab would once it has the position.
  local start=$SECONDS
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 TASK_FORCE_ZELLIJ_TIMEOUT=1 \
    STUB_ZELLIJ_HANG=list-tabs STUB_ZELLIJ_HANG_SECS=20 \
    aw_snap_back_to_tab "new-worker" 0 >"$BATS_TEST_TMPDIR/out" 2>&1
  assert [ $((SECONDS - start)) -le 4 ]
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "Could not confirm focus on your tab"
  run grep -F 'zellij-timeout: list-tabs 1s caller=snap-back slug=new-worker' "$TASK_FORCE_HOME/radio/log"
  assert_success
  run _focus_log
  assert_output --partial 'tab-focus: list-tabs unusable after 1 check(s)'
}

@test "snap-back: a stalled go-to-tab is bounded and logged; the launch goes on (#384)" {
  local start=$SECONDS
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 TASK_FORCE_ZELLIJ_TIMEOUT=1 \
    STUB_ZELLIJ_HANG=go-to-tab STUB_ZELLIJ_HANG_SECS=20 STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1" >"$BATS_TEST_TMPDIR/out" 2>&1
  assert [ $((SECONDS - start)) -le 4 ]
  run grep -F 'zellij-timeout: go-to-tab 1s caller=snap-back slug=new-worker' "$TASK_FORCE_HOME/radio/log"
  assert_success
}

@test "aw_bounded never fires an inherited ERR trap: task-reviewer's would remove the worktree (#384)" {
  # task-reviewer runs aw_launch_tab under `set -eE` with a cleanup ERR trap.
  # aw_bounded runs the command and its watchdog in background subshells,
  # which inherit that trap: a failing go-to-tab, or the watchdog's sleep
  # being cancelled, would run the cleanup there.
  local fired="$BATS_TEST_TMPDIR/err-fired"
  run bash -c 'set -eEuo pipefail
    source "$1"
    trap "echo fired >> \"$2\"" ERR
    aw_bounded 5 false || true
    aw_bounded 0.2 sleep 5 || true
    aw_bounded 5 true
    sleep 0.3
    echo done' _ "$ZELLIJ_TAB_LIB" "$fired"
  assert_success
  assert_output --partial done
  assert [ ! -e "$fired" ]
}

@test "snap-back: a steal after focus settled is caught by the late look (#384)" {
  # Pre-lookup, two settled checks, then the steal lands: before #384 the
  # loop had already returned. The late look sees it and snaps back.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n%s\n%s\n%s\n' "$CALLER_ACTIVE" "$CALLER_ACTIVE" "$CALLER_ACTIVE" "$NEW_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 AW_TAB_FOCUS_LATE=0.01 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  refute_output --partial "Could not"
  assert_equal "$(_goto_count)" 2
  # pre-lookup + 2 settled + the late steal + 2 settled again.
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 6
  run _focus_log
  assert_output --partial 'tab-focus: snap-back needed 2 go-to-tab(s) slug=new-worker caller_position=0 late_steal=1'
}

@test "snap-back: the late look finds the caller still focused → one go-to-tab, no log line (#384)" {
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 AW_TAB_FOCUS_LATE=0.01 STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_equal "$(_goto_count)" 1
  # pre-lookup + 2 settled + the late look.
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 4
  run _focus_log
  assert_output ''
}

@test "snap-back: the late look is on by default (#384)" {
  unset AW_TAB_FOCUS_LATE
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 4
}

# A list-tabs answered before zellij has processed the new-tab: the caller is
# active and the new tab is not listed at all.
CALLER_ONLY='[{"name":"pm","position":0,"active":true}]'

@test "snap-back: caller active before the new tab exists, then the new tab steals focus → caught and snapped back (#343)" {
  # Pre-lookup, then two checks that see only the caller (zellij has not
  # processed new-tab yet), then the new tab appears with focus, then the
  # caller again after the retry.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n%s\n%s\n%s\n' "$CALLER_ONLY" "$CALLER_ONLY" "$CALLER_ONLY" "$NEW_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  refute_output --partial "Could not"
  # No go-to-tab while the caller was active; one after the steal.
  assert_equal "$(_goto_count)" 2
  # pre-lookup + 2 early + the steal + 2 consecutive caller-active checks.
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 6
  run _focus_log
  assert_output --partial 'tab-focus: snap-back needed 2 go-to-tab(s) slug=new-worker caller_position=0'
  assert_equal "$(grep -c . <<<"$output")" 1
}

@test "snap-back: one caller-active check is not enough, a steal between two is caught (#343)" {
  # The new tab is listed and the caller active once, then the steal lands
  # before the second observation: the streak resets and the loop retries.
  local q="$BATS_TEST_TMPDIR/tabs.queue"
  printf '%s\n%s\n%s\n' "$CALLER_ACTIVE" "$CALLER_ACTIVE" "$NEW_ACTIVE" > "$q"
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    STUB_ZELLIJ_TABS_JSON="$CALLER_ACTIVE" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  refute_output --partial "Could not"
  assert_equal "$(_goto_count)" 2
  # pre-lookup + active + steal + 2 consecutive caller-active checks.
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 5
  run _focus_log
  assert_output --partial 'tab-focus: snap-back needed 2 go-to-tab(s) slug=new-worker caller_position=0'
}

@test "snap-back: a painted new-tab name (▶️ <slug>) counts as listed (#343)" {
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 \
    STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true},{"name":"▶️ new-worker","position":1,"active":false}]' \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  refute_output --partial "Could not"
  assert_equal "$(_goto_count)" 1
  run _focus_log
  assert_output ''
}

@test "snap-back: new tab never listed → budget spent, logged as never appeared, launch succeeds (#343)" {
  ZELLIJ=1 AW_TAB_FOCUS_INTERVAL=0 AW_TAB_FOCUS_CHECKS=4 STUB_ZELLIJ_TABS_JSON="$CALLER_ONLY" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_output --partial "'new-worker' never showed up in zellij's tab list"
  # The caller stayed active throughout, so no go-to-tab beyond the first.
  assert_equal "$(_goto_count)" 1
  assert_equal "$(grep -c 'list-tabs --json' "$STUB_CALLS_DIR/zellij.calls")" 5
  run _focus_log
  assert_output --partial 'tab-focus: new tab never appeared after 4 check(s) slug=new-worker caller_position=0 active_position=0'
  assert_equal "$(grep -c . <<<"$output")" 1
}

@test "snap-back: default bound is about 1.5s, not an unbounded wait (#311)" {
  local q="$BATS_TEST_TMPDIR/tabs.queue" start=$SECONDS
  printf '%s\n' "$CALLER_ACTIVE" > "$q"
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$NEW_ACTIVE" STUB_ZELLIJ_TABS_JSON_QUEUE="$q" \
    run aw_launch_tab "new-worker" "$MAIN_REPO" "echo hi" "1"
  assert_success
  assert_equal "$(_goto_count)" 7
  assert [ $((SECONDS - start)) -le 4 ]
}

# ---------------------------------------------------------------------------
# Integration: launchers keep the caller's focus by default; --focus jumps (#254)
# ---------------------------------------------------------------------------

CALLER_TABS='[{"name":"pm","position":0,"active":true}]'

# CALLER_TABS plus the new tab <slug>, listed inactive as zellij would once it
# opens: the snap-back waits for it before trusting the caller's focus (#343).
_caller_tabs() {
  printf '[{"name":"pm","tab_id":1,"position":0,"active":true},{"name":"%s","tab_id":2,"position":1,"active":false}]' "$1"
}

@test "task-work, no flag: snap-back fires (PM keeps focus) on every agent (#254)" {
  local impl
  for impl in claude-gh kiro-gh; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$(_caller_tabs "plain-${impl%%-*}")" \
      run env AW_IMPL="$impl" "$TASK_WORK" --no-task "plain-${impl%%-*}"
    assert_success
    assert_stub_called zellij "go-to-tab 1"
  done
}

@test "task-work --plan: snap-back fires too (#254)" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$(_caller_tabs my-feature)" \
    run env AW_IMPL=claude-gh "$TASK_WORK" my-feature --plan
  assert_success
  refute_output --partial "Could not keep focus"
  refute_output --partial "Could not confirm focus"
  assert_stub_called zellij "go-to-tab 1"
}

@test "task-work --auto: snap-back fires (unchanged by permission mode)" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$(_caller_tabs my-feature)" \
    run env AW_IMPL=claude-gh "$TASK_WORK" --no-task my-feature --auto
  assert_success
  assert_stub_called zellij "go-to-tab 1"
}

@test "task-work --focus: no pre-lookup, no snap-back, on every agent (#254)" {
  local impl
  for impl in claude-gh kiro-gh; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
      run env AW_IMPL="$impl" "$TASK_WORK" --no-task "focus-${impl%%-*}" --focus
    assert_success
    run grep -F 'go-to-tab' "$STUB_CALLS_DIR/zellij.calls"
    assert_failure
    # aw_record_tab_id lists tabs after the launch; nothing may precede new-tab.
    local first
    first=$(grep -m1 -E 'list-tabs|new-tab' "$STUB_CALLS_DIR/zellij.calls")
    [[ "$first" == *new-tab* ]] || { echo "$impl: $first" >&2; return 1; }
  done
}

@test "task-work --focus --auto: --focus wins, no snap-back" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
    run env AW_IMPL=claude-gh "$TASK_WORK" --no-task my-feature --auto --focus
  assert_success
  run grep -F 'go-to-tab' "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}
