#!/usr/bin/env bash
# Radio-home isolation guard (#203).
#
# radio, task-done and friends resolve their mailbox root as
# `${TASK_FORCE_HOME:-$HOME/.task-force}`. A test file that never overrides
# $TASK_FORCE_HOME therefore drives the *developer's live radio home* — and
# since $TASK_FORCE_ROLE is inherited from the tab the suite is run from, the
# damage lands on the runner's own session file. task_done.bats and
# task_done_dispatcher.bats did exactly that: 57 silent
# `radio unregister --manual` wipes per `./run_tests.sh`, which made an agent
# worker unaddressable mid-run and polluted the radio log that #191's runbook
# asks people to trust.
#
# Two layers stop that recurring:
#   * tests/setup_suite.bash exports a run-scoped tempdir when the caller
#     hasn't supplied one, so isolation is the default rather than something
#     each file has to remember;
#   * this guard, invoked when tests/helpers/common.bash loads, fails loudly
#     if $TASK_FORCE_HOME is missing or points back at the real home.
#
# Sourced by both tests/setup_suite.bash and tests/helpers/common.bash.

# True when $1 is a usable, isolated radio home: non-empty, and neither the
# real ~/.task-force nor anything beneath it.
task_force_home_is_isolated() {
  local home="${1:-}" real="${HOME%/}/.task-force"
  [[ -n "$home" ]] || return 1
  [[ "$home" != "$real" && "$home" != "$real"/* ]]
}

# Fail loudly when the ambient $TASK_FORCE_HOME would point tests at the
# developer's live mailbox. Returns 1 (callers decide whether to exit).
require_isolated_task_force_home() {
  task_force_home_is_isolated "${TASK_FORCE_HOME:-}" && return 0
  cat >&2 <<MSG
ERROR: refusing to run tests against the real radio home (#203).

  \$TASK_FORCE_HOME = ${TASK_FORCE_HOME:-<unset>}
  \$HOME/.task-force = ${HOME%/}/.task-force

Tests invoke 'radio unregister --manual' and other destructive commands; with
no isolated \$TASK_FORCE_HOME they would wipe the live session of whoever ran
them. Run the suite via ./run_tests.sh (or any bats invocation that picks up
tests/setup_suite.bash), or export TASK_FORCE_HOME to a scratch directory.
MSG
  return 1
}
