#!/usr/bin/env bats
# A kiro role whose hooks stopped firing mid-session (#370).
#
# kiro-cli 3.1's V3 engine drops every hook of an agent it hot-reloads from an
# old-shape config, so the role's heartbeat freezes at its last hook and
# `radio send` called it dead while its agent worked on in an open tab. Two
# changes are pinned here: a kiro role the heartbeat calls dead is still woken
# when the tab at its recorded TAB_ID is listed under its name, and every hook
# entrypoint that no-ops on an empty role leaves a log line.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake-session-name
  export ZELLIJ_SESSION_NAME=live-server
  export TASK_FORCE_ROLE=test-runner
  unset ZELLIJ_TAB ZELLIJ_PANE_ID
  # worker-foo gets tab_id=7, pane_id=700.
  seed_zellij_tabs worker-foo
}

teardown() {
  teardown_all
}

SESS() { printf '%s/radio/sessions/%s.info' "$TASK_FORCE_HOME" "$1"; }

# Register <role> as <agent>, mark it busy, and push its heartbeat 3h back:
# the frozen session #370 found, its STATE left at the last hook that ran.
_register_frozen() {
  local role="$1" agent="$2" stale f
  "$RADIO" register --role "$role" --tab "$role" --agent "$agent"
  TASK_FORCE_ROLE="$role" "$RADIO" busy
  stale=$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)
  f=$(SESS "$role")
  awk -v h="LAST_HEARTBEAT=$stale" '/^LAST_HEARTBEAT=/{print h; next} {print}' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  : > "$STUB_CALLS_DIR/zellij.calls"
}

# ----- the wake fallback ----------------------------------------------------

@test "send wakes a kiro role that looks dead while its tab is still open (#370)" {
  _register_frozen worker-foo kiro

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: delivered — woke worker-foo (tab_id=7), although its heartbeat is"
  assert_output --partial "its tab is still open"
  refute_output --partial "looks dead"
  assert_stub_called zellij "action write-chars --pane-id 700 radio check"
  run grep -c 'but its tab is still open — kiro, waking anyway' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
  run grep -c 'send: woke worker-foo via tab_id=7' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "a dead-looking claude role is still only warned about, never woken (#370)" {
  _register_frozen worker-foo claude

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: WARNING — worker-foo looks dead"
  refute_output --partial "delivered"
  run stub_calls zellij
  refute_output --partial "write-chars"
  run grep -c 'waking anyway' "$TASK_FORCE_HOME/radio/log"
  assert_output "0"
}

@test "a kiro role whose recorded tab id now names another tab is not woken (#370)" {
  _register_frozen worker-foo kiro
  # Tab 7 is somebody else's now, and a worker-foo tab exists at another id:
  # _live_tab_id would recover it by name (rc 3), which is not enough here.
  export STUB_ZELLIJ_TABS_JSON='[
    {"name": "worker-bar", "tab_id": 7},
    {"name": "worker-foo", "tab_id": 9}
  ]'

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: WARNING — worker-foo looks dead"
  run stub_calls zellij
  refute_output --partial "write-chars"
  # Nor is the file repaired to point at the look-alike.
  run grep '^TAB_ID=' "$(SESS worker-foo)"
  assert_output "TAB_ID=7"
}

@test "a kiro role whose tab is gone is warned about as before (#370)" {
  _register_frozen worker-foo kiro
  export STUB_ZELLIJ_TABS_JSON='[{"name": "worker-bar", "tab_id": 8}]'

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: WARNING — worker-foo looks dead"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

@test "a failed fallback wake ends in the looks-dead warning, not the idle line (#370)" {
  _register_frozen worker-foo kiro

  STUB_ZELLIJ_WRITE_CHARS_FAIL=1 TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: WARNING — worker-foo looks dead"
  refute_output --partial "is idle but wake failed"
  refute_output --partial "delivered"
  run grep -c 'write-chars failed for worker-foo' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "a busy kiro role with a fresh heartbeat still queues without a wake (#370)" {
  # The fallback is for a heartbeat the 1h orphan threshold calls dead, not for
  # an ordinary busy turn: that one is #322's to decide.
  "$RADIO" register --role worker-foo --tab worker-foo --agent kiro
  TASK_FORCE_ROLE=worker-foo "$RADIO" busy
  : > "$STUB_CALLS_DIR/zellij.calls"

  TASK_FORCE_ROLE=pm-foo run "$RADIO" send --to worker-foo --intent changes-requested --body "x"
  assert_success
  assert_output --partial "radio: queued — worker-foo is busy"
  run stub_calls zellij
  refute_output --partial "write-chars"
}

# ----- the silent no-op paths -----------------------------------------------

@test "every hook entrypoint logs its no-op on an empty role, printing nothing (#370)" {
  local entry
  for entry in busy ready awaiting stop-hook prompt-hook unregister; do
    run env -u TASK_FORCE_ROLE "$RADIO" "$entry" </dev/null
    assert_success
    # Hook stdout is injected into the agent's context: not a byte.
    assert_output ""
    run grep -c "hook-noop: $entry — no \$TASK_FORCE_ROLE" "$TASK_FORCE_HOME/radio/log"
    assert_output "1"
  done
  # The cwd says which worktree's hooks ran roleless.
  run grep -c "hook-noop: busy — .* cwd=$PWD;" "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "the hook no-op line is rate-limited per entrypoint (#370)" {
  env -u TASK_FORCE_ROLE "$RADIO" busy </dev/null
  env -u TASK_FORCE_ROLE "$RADIO" busy </dev/null
  env -u TASK_FORCE_ROLE "$RADIO" ready </dev/null
  run grep -c 'hook-noop: busy' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
  run grep -c 'hook-noop: ready' "$TASK_FORCE_HOME/radio/log"
  assert_output "1"

  # An hour on, it logs again.
  touch -t 202001010000 "$TASK_FORCE_HOME/radio/.hook-noop-busy"
  env -u TASK_FORCE_ROLE "$RADIO" busy </dev/null
  run grep -c 'hook-noop: busy' "$TASK_FORCE_HOME/radio/log"
  assert_output "2"
}

@test "a hook with a role logs no no-op line (#370)" {
  "$RADIO" register --role worker-foo --tab worker-foo --agent kiro
  TASK_FORCE_ROLE=worker-foo run "$RADIO" busy </dev/null
  assert_success
  run grep -c 'hook-noop:' "$TASK_FORCE_HOME/radio/log"
  assert_output "0"
}
