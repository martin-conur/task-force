#!/usr/bin/env bash
# Suite-wide setup, run once per bats invocation — a single file, a glob of
# files, or the whole tests/ directory. bats picks this up from the folder of
# the first test file, so ./run_tests.sh and a bare `bats tests/foo.bats` both
# get it.
#
# Its one job is radio-home isolation (#203): give the whole run a scratch
# $TASK_FORCE_HOME so a suite that forgets setup_task_force_home degrades to
# "isolated anyway" rather than "writes to the developer's live mailbox". See
# tests/helpers/radio_home.bash for the failure this prevents.

_SETUP_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/radio_home.bash
source "$_SETUP_SUITE_DIR/helpers/radio_home.bash"

setup_suite() {
  if [[ -n "${TASK_FORCE_HOME:-}" ]]; then
    # Caller supplied one (CI, or a developer pinning a scratch dir): honour
    # it, but only once it has been proven not to be the real home.
    require_isolated_task_force_home || return 1
    return 0
  fi

  # Under BATS_SUITE_TMPDIR bats removes this for us; the fallback keeps the
  # helper usable if a future bats stops exporting it.
  TASK_FORCE_HOME=$(mktemp -d "${BATS_SUITE_TMPDIR:-${TMPDIR:-/tmp}}/task-force-home.XXXXXX")
  export TASK_FORCE_HOME
}

teardown_suite() {
  # Same shell as setup_suite, so $TASK_FORCE_HOME is still the run-scoped one
  # unless a test file exported its own — hence the isolation re-check.
  [[ -n "${TASK_FORCE_HOME:-}" ]] || return 0
  task_force_home_is_isolated "$TASK_FORCE_HOME" && rm -rf "$TASK_FORCE_HOME"
  return 0
}
