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
# Integration: launchers keep the caller's focus by default; --focus jumps (#254)
# ---------------------------------------------------------------------------

CALLER_TABS='[{"name":"pm","position":0,"active":true}]'

@test "task-work, no flag: snap-back fires (PM keeps focus) on every agent (#254)" {
  local impl
  for impl in claude-gh kiro-gh; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
      run env AW_IMPL="$impl" "$TASK_WORK" "plain-${impl%%-*}"
    assert_success
    assert_stub_called zellij "go-to-tab 1"
  done
}

@test "task-work --plan: snap-back fires too (#254)" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
    run env AW_IMPL=claude-gh "$TASK_WORK" my-feature --plan
  assert_success
  assert_stub_called zellij "go-to-tab 1"
}

@test "task-work --auto: snap-back fires (unchanged by permission mode)" {
  ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
    run env AW_IMPL=claude-gh "$TASK_WORK" my-feature --auto
  assert_success
  assert_stub_called zellij "go-to-tab 1"
}

@test "task-work --focus: no pre-lookup, no snap-back, on every agent (#254)" {
  local impl
  for impl in claude-gh kiro-gh; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    ZELLIJ=1 STUB_ZELLIJ_TABS_JSON="$CALLER_TABS" \
      run env AW_IMPL="$impl" "$TASK_WORK" "focus-${impl%%-*}" --focus
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
    run env AW_IMPL=claude-gh "$TASK_WORK" my-feature --auto --focus
  assert_success
  run grep -F 'go-to-tab' "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}
