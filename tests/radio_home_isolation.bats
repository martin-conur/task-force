#!/usr/bin/env bats
# Radio-home isolation for the test suite itself (#203).
#
# `task-done` calls `radio unregister --manual`, which wipes a session file
# unconditionally by design (#198). Two suites used to run that against the
# *real* ~/.task-force, so `./run_tests.sh` destroyed the live session of
# whoever ran it 57 times per run: an agent worker that ran the suite — which
# the pre-PR checklist requires — went unaddressable mid-run, and the radio log
# #191's runbook asks people to trust filled with wipes no code path explained.
#
# These tests are the standing guard: they drive real bats invocations under a
# throwaway $HOME and assert nothing lands under it.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

BATS_BIN="$REPO_ROOT_REAL/tests/libs/bats-core/bin/bats"

setup() {
  FAKE_HOME=$(mktemp -d)
  export FAKE_HOME
}

teardown() {
  [[ -z "${FAKE_HOME:-}" ]] || rm -rf "$FAKE_HOME"
}

# Run one bats suite in a child process with $HOME redirected at $FAKE_HOME and
# $TASK_FORCE_HOME deliberately unset, i.e. exactly the shape that leaked.
# Extra args are passed through to bats (use --filter to keep it quick).
run_suite_under_fake_home() {
  local suite="$1"; shift
  run env -u TASK_FORCE_HOME \
    HOME="$FAKE_HOME" \
    BATS_LIB_PATH="$REPO_ROOT_REAL/tests/libs" \
    "$BATS_BIN" "$REPO_ROOT_REAL/tests/$suite.bats" "$@"
}

# Everything radio writes lives under one of these three.
assert_real_radio_home_untouched() {
  assert [ ! -e "$FAKE_HOME/.task-force/radio/log" ]
  assert [ ! -e "$FAKE_HOME/.task-force/radio/sessions" ]
  assert [ ! -e "$FAKE_HOME/.task-force/radio/mailbox" ]
  assert [ ! -e "$FAKE_HOME/.task-force" ]
}

# ---------------------------------------------------------------------------
# The two suites that leaked
# ---------------------------------------------------------------------------

# The whole of task_done.bats is ~50 tests; the radio-touching subset is what
# leaked, and filtering keeps this suite cheap enough to run every time.
TASK_DONE_RADIO_TESTS='unregister|radio|mailbox'

@test "task_done suite writes nothing under \$HOME/.task-force" {
  run_suite_under_fake_home task_done --filter "$TASK_DONE_RADIO_TESTS"
  assert_success
  assert_real_radio_home_untouched
}

@test "task_done_dispatcher suite writes nothing under \$HOME/.task-force" {
  run_suite_under_fake_home task_done_dispatcher
  assert_success
  assert_real_radio_home_untouched
}

@test "no unregister lands in the real radio log while task_done runs" {
  # Pre-create the log so the check is "nothing was appended", not merely
  # "nothing created the tree" — the delta the issue measured.
  mkdir -p "$FAKE_HOME/.task-force/radio"
  : > "$FAKE_HOME/.task-force/radio/log"

  run_suite_under_fake_home task_done --filter "$TASK_DONE_RADIO_TESTS"
  assert_success

  run grep -c 'unregister role=' "$FAKE_HOME/.task-force/radio/log"
  assert_output "0"
}

# ---------------------------------------------------------------------------
# Isolation is the default, not something each file has to remember
# ---------------------------------------------------------------------------

@test "setup_suite hands every run an isolated TASK_FORCE_HOME" {
  refute [ -z "${TASK_FORCE_HOME:-}" ]
  run task_force_home_is_isolated "$TASK_FORCE_HOME"
  assert_success
}

@test "a suite that never calls setup_task_force_home is still isolated" {
  # Stand up a throwaway bats tree carrying only setup_suite.bash and its
  # helper, plus a probe file whose setup() does nothing at all. The probe has
  # to come out isolated purely on the strength of the suite-level default.
  local dir="$FAKE_HOME/probe"
  mkdir -p "$dir/helpers"
  cp "$REPO_ROOT_REAL/tests/setup_suite.bash" "$dir/"
  cp "$REPO_ROOT_REAL/tests/helpers/radio_home.bash" "$dir/helpers/"
  cat > "$dir/probe.bats" <<'PROBE'
@test "probe records its radio home" {
  printf '%s' "${TASK_FORCE_HOME:-}" > "$PROBE_OUT"
}
PROBE

  run env -u TASK_FORCE_HOME HOME="$FAKE_HOME" PROBE_OUT="$FAKE_HOME/probe-home" \
    "$BATS_BIN" "$dir/probe.bats"
  assert_success

  local seen
  seen=$(cat "$FAKE_HOME/probe-home")
  refute [ -z "$seen" ]
  run task_force_home_is_isolated "$seen"
  assert_success
  assert_real_radio_home_untouched
}

# ---------------------------------------------------------------------------
# …and when it is subverted, it fails loudly instead of writing to the mailbox
# ---------------------------------------------------------------------------

@test "pointing TASK_FORCE_HOME at the real home fails the run loudly" {
  run env HOME="$FAKE_HOME" \
    TASK_FORCE_HOME="$FAKE_HOME/.task-force" \
    BATS_LIB_PATH="$REPO_ROOT_REAL/tests/libs" \
    "$BATS_BIN" "$REPO_ROOT_REAL/tests/task_done.bats" --filter 'unregisters'
  assert_failure
  assert_output --partial "refusing to run tests against the real radio home"
  assert_real_radio_home_untouched
}

@test "a subdirectory of the real home is refused too" {
  run task_force_home_is_isolated "$HOME/.task-force/radio"
  assert_failure
}

@test "an unset TASK_FORCE_HOME is refused when loading the common helper" {
  # Simulates a bats invocation that never picked up tests/setup_suite.bash.
  run env -u TASK_FORCE_HOME bash -c \
    "source '$REPO_ROOT_REAL/tests/helpers/common.bash'"
  assert_failure
  assert_output --partial "refusing to run tests against the real radio home"
}

@test "an isolated TASK_FORCE_HOME supplied by the caller is honoured" {
  run env TASK_FORCE_HOME="$FAKE_HOME/scratch" bash -c \
    "source '$REPO_ROOT_REAL/tests/helpers/common.bash' && printf 'ok'"
  assert_success
  assert_output "ok"
}
