#!/usr/bin/env bats
# PATH isolation for the test suite itself (#223).
#
# task-work / task-done resolve `task-board` from $PATH in preference to this
# checkout's own root copy, and install.sh plants ~/.local/bin/task-board as a symlink into
# whichever checkout ran the installer last. So on any machine that has ever
# installed task-force, the two `regenerates tasks/_board.md` tests invoked
# *another clone's* task-board — which, being the root canonical copy, refuses on a
# fixture repo that has no workflow doc. Under the old `|| true` that failure was
# swallowed whole, and the visible symptom was a missing artifact two assertions
# later. CI installs nothing, so CI was green: the suite failed for precisely the
# people most likely to run it, and passed on the machine that gates merges.
#
# These tests are the standing guard. The unit tests pin the rewrite; the two at
# the bottom drive real bats invocations with a hostile task-board planted on
# $PATH — the exact condition that reproduced the bug.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

BATS_BIN="$REPO_ROOT_REAL/tests/libs/bats-core/bin/bats"

# A directory shaped like the ~/.local/bin of a machine that installed
# task-force from a different checkout: a task-board that refuses (as the root
# bin/task-board does on a repo with no workflow doc), next to an unrelated binary
# that isolation must not take away with it.
make_foreign_bin() {
  local d="${1:-$BATS_TEST_TMPDIR/foreign-bin}"
  mkdir -p "$d"
  cat > "$d/task-board" <<'EOF'
#!/usr/bin/env bash
echo "Error: no workflow doc found in $PWD (foreign checkout)" >&2
exit 1
EOF
  printf '#!/bin/sh\necho neighbour\n' > "$d/neighbour"
  chmod +x "$d/task-board" "$d/neighbour"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# The rewrite
# ---------------------------------------------------------------------------

@test "sanitize: a task-force command on \$PATH becomes unreachable" {
  local bin mirror sanitized
  bin=$(make_foreign_bin)
  mirror="$BATS_TEST_TMPDIR/mirror"
  sanitized=$(PATH="$bin:$PATH"; sanitize_path_of_task_force "$mirror")

  run bash -c "PATH='$sanitized'; command -v task-board"
  assert_failure
}

@test "sanitize: the directory's other binaries survive" {
  # The whole reason a holding directory is mirrored rather than dropped:
  # ~/.local/bin routinely carries jq, gh or python next to our symlinks, and
  # dropping it wholesale would trade this bug for a worse one.
  local bin mirror sanitized
  bin=$(make_foreign_bin)
  mirror="$BATS_TEST_TMPDIR/mirror"
  sanitized=$(PATH="$bin:$PATH"; sanitize_path_of_task_force "$mirror")

  run bash -c "PATH='$sanitized'; neighbour"
  assert_success
  assert_output "neighbour"
}

@test "sanitize: the holding directory itself is off the new \$PATH" {
  local bin mirror sanitized
  bin=$(make_foreign_bin)
  mirror="$BATS_TEST_TMPDIR/mirror"
  sanitized=$(PATH="$bin:$PATH"; sanitize_path_of_task_force "$mirror")

  # The holding directory is gone from the list…
  run bash -c "case \":$sanitized:\" in *\":$bin:\"*) echo present ;; *) echo absent ;; esac"
  assert_output "absent"
  # …and a mirror of it stands where it was.
  run bash -c "case \":$sanitized:\" in *\"$mirror\"*) echo mirrored ;; *) echo missing ;; esac"
  assert_output "mirrored"
}

@test "sanitize: every task-force command install.sh links is stripped" {
  local d="$BATS_TEST_TMPDIR/all-bin" mirror="$BATS_TEST_TMPDIR/mirror" cmd sanitized
  mkdir -p "$d"
  for cmd in "${AW_TASK_FORCE_COMMANDS[@]}"; do
    printf '#!/bin/sh\nexit 7\n' > "$d/$cmd"
    chmod +x "$d/$cmd"
  done
  sanitized=$(PATH="$d:$PATH"; sanitize_path_of_task_force "$mirror")

  for cmd in "${AW_TASK_FORCE_COMMANDS[@]}"; do
    run bash -c "PATH='$sanitized'; command -v '$cmd'"
    assert_failure
  done
}

@test "sanitize: a repeated directory is mirrored once, not once per mention" {
  local bin mirror sanitized n
  bin=$(make_foreign_bin)
  mirror="$BATS_TEST_TMPDIR/mirror"
  sanitized=$(PATH="$bin:/usr/bin:$bin:/bin:$bin"; sanitize_path_of_task_force "$mirror")

  # One mirror, not three.
  n=$(find "$mirror" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
  assert_equal "$n" "1"
  # And the duplicate entries are gone rather than pointing at the same mirror.
  assert_equal "$sanitized" "$mirror/01-${bin##*/}:/usr/bin:/bin"
  run bash -c "PATH='$sanitized'; command -v task-board"
  assert_failure
}

@test "sanitize: a duplicate directory with nothing of ours collapses too" {
  local mirror="$BATS_TEST_TMPDIR/mirror" sanitized
  mkdir -p "$mirror"
  sanitized=$(PATH="/usr/bin:/bin:/usr/bin"; sanitize_path_of_task_force "$mirror")
  assert_equal "$sanitized" "/usr/bin:/bin"
}

@test "sanitize: a \$PATH with nothing of ours is returned unchanged" {
  local d="$BATS_TEST_TMPDIR/clean" mirror="$BATS_TEST_TMPDIR/mirror" sanitized
  mkdir -p "$d" "$mirror"
  printf '#!/bin/sh\n:\n' > "$d/unrelated"
  chmod +x "$d/unrelated"
  sanitized=$(PATH="$d:/usr/bin:/bin"; sanitize_path_of_task_force "$mirror")

  assert_equal "$sanitized" "$d:/usr/bin:/bin"
  # Nothing to mirror means nothing was mirrored.
  run bash -c "ls -A '$mirror'"
  assert_output ""
}

# ---------------------------------------------------------------------------
# The guard
# ---------------------------------------------------------------------------

@test "guard: refuses a \$PATH that can reach a task-force command" {
  local bin
  bin=$(make_foreign_bin)
  run env PATH="$bin:$PATH" bash -c \
    "source '$REPO_ROOT_REAL/tests/helpers/path_isolation.bash'
     require_task_force_free_path"
  assert_failure
  assert_output --partial "#223"
  assert_output --partial "task-board -> $bin/task-board"
}

@test "guard: passes once the rewrite has run" {
  local bin mirror sanitized
  bin=$(make_foreign_bin)
  mirror="$BATS_TEST_TMPDIR/mirror"
  sanitized=$(PATH="$bin:$PATH"; sanitize_path_of_task_force "$mirror")
  run env PATH="$sanitized" bash -c \
    "source '$REPO_ROOT_REAL/tests/helpers/path_isolation.bash'
     require_task_force_free_path"
  assert_success
}

@test "this run's own \$PATH cannot reach a task-force command" {
  # The end-to-end assertion: whatever machine this is, setup_suite has already
  # put the run out of reach of ~/.local/bin.
  run task_force_commands_on_path
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# The two tests that failed, under the condition that failed them
# ---------------------------------------------------------------------------

# Run one suite in a child bats process with a foreign task-board first on
# $PATH — i.e. exactly the machine state install.sh leaves behind.
run_suite_with_foreign_task_board() {
  local suite="$1"; shift
  local bin
  bin=$(make_foreign_bin "$BATS_TEST_TMPDIR/foreign-$suite")
  run env PATH="$bin:$PATH" \
    BATS_LIB_PATH="$REPO_ROOT_REAL/tests/libs" \
    "$BATS_BIN" "$REPO_ROOT_REAL/tests/$suite.bats" "$@"
}

# The per-loadout task-work suites these used to run were consolidated in #237;
# the board tests live in tests/task_work_trackers.bats now. Each filter is
# asserted to select at least one test, so a rename cannot turn this into a
# zero-test run that passes by running nothing.
@test "claude-local board test passes with a foreign task-board on \$PATH" {
  run_suite_with_foreign_task_board task_work_trackers --filter "local: regenerates tasks/_board.md"
  assert_success
  assert_output --partial "ok 1 "
}

@test "kiro-local board test passes with a foreign task-board on \$PATH" {
  run_suite_with_foreign_task_board task_work_trackers --filter "written under both local loadouts"
  assert_success
  assert_output --partial "ok 1 "
}
