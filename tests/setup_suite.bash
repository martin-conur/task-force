#!/usr/bin/env bash
# Suite-wide setup, run once per bats invocation — a single file, a glob of
# files, or the whole tests/ directory. bats picks this up from the folder of
# the first test file, so ./run_tests.sh and a bare `bats tests/foo.bats` both
# get it.
#
# Its job is fixture isolation from real machine state: a scratch
# $TASK_FORCE_HOME so a suite that forgets setup_task_force_home degrades to
# "isolated anyway" rather than "writes to the developer's live mailbox" (#203),
# and a $PATH with no task-force command on it so a suite can only reach the
# checkout under test (#223). See tests/helpers/radio_home.bash and
# tests/helpers/path_isolation.bash for the failures these prevent.

_SETUP_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/radio_home.bash
source "$_SETUP_SUITE_DIR/helpers/radio_home.bash"
# shellcheck source=tests/helpers/path_isolation.bash
source "$_SETUP_SUITE_DIR/helpers/path_isolation.bash"

setup_suite() {
  # PATH first: it decides which checkout's binaries the run can see at all.
  # Unconditional, not "only when something leaked" — the rewrite is a no-op on
  # a machine that has never run install.sh, and honouring a caller-supplied
  # PATH the way $TASK_FORCE_HOME is honoured would just reinstate the bug.
  AW_PATH_MIRROR_ROOT=$(mktemp -d "${BATS_SUITE_TMPDIR:-${TMPDIR:-/tmp}}/path-mirror.XXXXXX")
  PATH=$(sanitize_path_of_task_force "$AW_PATH_MIRROR_ROOT")
  export PATH
  require_task_force_free_path || return 1

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
  # Same shell as setup_suite, so $AW_PATH_MIRROR_ROOT and $TASK_FORCE_HOME are
  # still the run-scoped ones unless a test file exported its own — hence the
  # isolation re-check.
  [[ -z "${AW_PATH_MIRROR_ROOT:-}" ]] || rm -rf "$AW_PATH_MIRROR_ROOT"
  [[ -n "${TASK_FORCE_HOME:-}" ]] || return 0
  task_force_home_is_isolated "$TASK_FORCE_HOME" && rm -rf "$TASK_FORCE_HOME"
  return 0
}
