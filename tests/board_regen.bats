#!/usr/bin/env bats
# Tests for lib/board-regen.sh — the board regeneration shared by the two local
# loadouts' task-work and task-done (#223).
#
# Resolution order is the subject: $PATH's task-board first, the caller's own
# sibling copy second. **Both branches are tested here on purpose.** Before #223
# the $PATH branch was exercised only by accident — on whichever machine happened
# to have run install.sh — and the fallback only on CI, which has nothing
# installed. Neutralizing $PATH for the suite (tests/helpers/path_isolation.bash)
# fixes the accident but would leave the $PATH branch tested by nobody, on any
# machine: that is the shape the bug grew in, so it is closed here rather than
# swapped for its mirror image.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  mkdir -p "$MAIN_REPO/tasks"

  # Stands in for <impl>/bin/task-work: the sibling fallback is resolved
  # relative to the *calling script's* path, so the fixture needs one.
  CALLER_BIN="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/impl/bin"
  mkdir -p "$CALLER_BIN"
  CALLER="$CALLER_BIN/task-work"
  : > "$CALLER"

  # shellcheck source=lib/board-regen.sh
  source "$REPO_ROOT_REAL/lib/board-regen.sh"
}

teardown() {
  teardown_all
}

# A task-board that records its arguments and renders a board naming itself, so
# a test can tell *which* copy ran rather than only that one did.
make_task_board() {
  local path="$1" label="$2" rc="${3:-0}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_CALLS_DIR/task-board.calls"
# A copy that refuses renders nothing, like the root dispatcher turning down a
# repo whose loadout it cannot detect.
if [[ $rc -ne 0 ]]; then
  echo "$label: refusing (no workflow doc found)" >&2
  exit $rc
fi
if [[ "\$1" == "--repo" && -d "\$2" ]]; then
  mkdir -p "\$2/tasks"
  echo "rendered by $label" > "\$2/tasks/_board.md"
fi
EOF
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# Resolution — both branches
# ---------------------------------------------------------------------------

@test "resolve: \$PATH's task-board wins over the sibling copy" {
  local bin="$BATS_TEST_TMPDIR/path-bin" resolved
  make_task_board "$bin/task-board" "the PATH copy"
  make_task_board "$CALLER_BIN/task-board" "the sibling copy"

  resolved=$(PATH="$bin:$PATH"; aw_resolve_task_board "$CALLER")
  assert_equal "$resolved" "$bin/task-board"
}

@test "resolve: falls back to the caller's sibling when \$PATH has none" {
  local resolved
  make_task_board "$CALLER_BIN/task-board" "the sibling copy"

  # No PATH juggling: the suite itself runs with no task-force command
  # reachable, which is the condition this branch is for.
  run bash -c "command -v task-board"
  assert_failure

  resolved=$(aw_resolve_task_board "$CALLER")
  assert_equal "$resolved" "$CALLER_BIN/task-board"
}

@test "resolve: the caller's script path is required, not defaulted" {
  # There is deliberately no `${1:-${BASH_SOURCE[1]}}` default here. It reads as
  # a convenience but could never be right: every real caller arrives through
  # aw_regenerate_board, so BASH_SOURCE[1] would be that frame — lib/ — which has
  # no task-board beside it. So a direct caller that forgets the argument fails
  # at its own call site instead of silently resolving nothing (#223 review).
  # Run it in a subshell and report that subshell's status: a ${var:?} failure
  # exits the shell it happens in, and bash's status for that is not the same
  # number everywhere, so the assertion is on "not zero" plus the message.
  run bash -c "source '$REPO_ROOT_REAL/lib/board-regen.sh'
               ( aw_resolve_task_board ) 2>&1
               echo \"rc=\$?\""
  assert_success
  assert_output --partial "path of the calling script is required"
  refute_output --partial "rc=0"
}

@test "resolve: fails when there is neither" {
  run aw_resolve_task_board "$CALLER"
  assert_failure
  assert_output ""
}

# ---------------------------------------------------------------------------
# Regeneration
# ---------------------------------------------------------------------------

@test "regenerate: runs the resolved copy against the given repo" {
  make_task_board "$CALLER_BIN/task-board" "the sibling copy"

  run aw_regenerate_board "$MAIN_REPO" "$CALLER"
  assert_success
  assert_stub_called task-board "--repo $MAIN_REPO"
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output "rendered by the sibling copy"
}

@test "regenerate: \$PATH's copy is the one that runs" {
  local bin="$BATS_TEST_TMPDIR/path-bin"
  make_task_board "$bin/task-board" "the PATH copy"
  make_task_board "$CALLER_BIN/task-board" "the sibling copy"

  PATH="$bin:$PATH" run aw_regenerate_board "$MAIN_REPO" "$CALLER"
  assert_success
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output "rendered by the PATH copy"
}

@test "regenerate: a failure is loud on stderr but not fatal" {
  # The #223 fix, in one test: task-work must survive a board that would not
  # render (it has a worktree and a tab to finish setting up), but the failure
  # may not be swallowed the way `|| true` swallowed it.
  local bin="$BATS_TEST_TMPDIR/path-bin"
  make_task_board "$bin/task-board" "the foreign copy" 1
  make_task_board "$CALLER_BIN/task-board" "the sibling copy"

  PATH="$bin:$PATH" run aw_regenerate_board "$MAIN_REPO" "$CALLER"
  assert_success
  assert_output --partial "task-board failed"
  assert_output --partial "$bin/task-board"
  # The failing copy's own diagnostics reach the user rather than /dev/null.
  assert_output --partial "no workflow doc found"
  # A copy that came from $PATH is named as such, with the local one to run by
  # hand — the sentence that would have short-circuited #223's diagnosis.
  assert_output --partial "came from \$PATH"
  assert_output --partial "$CALLER_BIN/task-board --repo"
  assert [ ! -f "$MAIN_REPO/tasks/_board.md" ]
}

@test "regenerate: a failing sibling copy is not blamed on \$PATH" {
  make_task_board "$CALLER_BIN/task-board" "the sibling copy" 1

  run aw_regenerate_board "$MAIN_REPO" "$CALLER"
  assert_success
  assert_output --partial "task-board failed"
  refute_output --partial "came from \$PATH"
}

@test "regenerate: no task-board anywhere is a silent no-op" {
  # A repo can be perfectly usable without a rendered board, and the caller has
  # no way to install one — so this is the one case that stays quiet.
  run aw_regenerate_board "$MAIN_REPO" "$CALLER"
  assert_success
  assert_output ""
  assert [ ! -f "$MAIN_REPO/tasks/_board.md" ]
}
