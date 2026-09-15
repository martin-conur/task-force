#!/usr/bin/env bats
# Tests for bin/ci-guard and its commit-msg hook installer (#194).
#
# The bug being guarded: a forge scans the ENTIRE head-commit message for
# CI-skip markers, so an agent that merely *quotes* one while describing
# another commit suppresses its own workflow run. No run is queued at all, so
# the PR shows no failing checks — it shows no checks — and "CI green" gets
# reported in good faith off an empty list. Two occurrences in one hour proved
# a prompt warning insufficient (the second agent was *explaining* the first),
# hence a mechanical guard.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

CI_GUARD="$REPO_ROOT_REAL/bin/ci-guard"

setup() {
  TMP=$(mktemp -d)
}

teardown() {
  teardown_all
  [[ -z "${TMP:-}" ]] || rm -rf "$TMP"
}

# A temp dir holding a `ci-guard` symlink, for PATH-based hook invocation.
make_guard_bin() {
  local d="$TMP/bin"
  mkdir -p "$d"
  ln -sf "$CI_GUARD" "$d/ci-guard"
  printf '%s' "$d"
}

msg() { printf '%s\n' "$@" > "$TMP/msg"; }

# ---------------------------------------------------------------- scanning

@test "scan: every marker the forge honours is caught" {
  for marker in "[skip ci]" "[ci skip]" "[no ci]" "[skip actions]" "[actions skip]"; do
    msg "subject line" "" "body mentioning $marker here"
    run "$CI_GUARD" scan "$TMP/msg"
    assert_failure
    assert_output --partial "$marker"
  done
}

@test "scan: matching is case-insensitive" {
  msg "subject" "" "quoting [SKIP CI] verbatim"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_failure
  assert_output --partial "[skip ci]"
}

@test "scan: a marker in the subject line is caught too" {
  msg "fix the [ci skip] handling"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_failure
  assert_output --partial "line 1"
}

@test "scan: reports the line number of each hit" {
  msg "subject" "" "first [skip ci]" "" "second [no ci]"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_failure
  assert_output --partial "line 3: [skip ci]"
  assert_output --partial "line 5: [no ci]"
}

@test "scan: a clean message passes" {
  msg "worker prompts: warn about CI-skip markers" "" \
      "Describes the marker as skip-ci so the run is not suppressed."
  run "$CI_GUARD" scan "$TMP/msg"
  assert_success
  assert_output ""
}

@test "scan: the documented escape hatch (broken marker) passes" {
  # This is the form the error message tells the agent to use. If it tripped
  # the guard the advice would be a dead end and the guard would get reverted.
  msg "subject" "" "the commit carried skip-ci, so main's CI never ran"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_success
}

@test "scan: comment lines are ignored (git strips them before committing)" {
  msg "subject" "# Please enter the commit message. Lines with [skip ci] are ignored"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_success
}

@test "scan: the scissors tail is ignored (git discards it)" {
  # `git commit --verbose` appends the diff below the scissors line; that diff
  # routinely contains the marker when the PR is about the marker itself.
  msg "subject" \
      "# ------------------------ >8 ------------------------" \
      "+- **CI markers**: never write [skip ci] in a commit message"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_success
}

@test "scan: stdin is accepted" {
  run bash -c "printf 'subject\n\nbody [no ci]\n' | '$CI_GUARD' scan -"
  assert_failure
  assert_output --partial "[no ci]"
}

@test "scan: a missing file is a usage error, not a silent pass" {
  run "$CI_GUARD" scan "$TMP/nope"
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "no such file"
}

# ------------------------------------------------------- refusal messaging

@test "refusal names the escape hatch so the guard does not get bypassed blind" {
  msg "subject with [skip ci]"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_failure
  assert_output --partial "skip-ci"
  assert_output --partial "--no-verify"
  assert_output --partial "TASK_FORCE_NO_CI_GUARD=1"
}

@test "refusal hands over the copy-pasteable proof-of-run command" {
  # The whole point: "did CI pass" cannot catch this, only "does a run exist
  # for this exact SHA" can.
  msg "subject with [skip ci]"
  run "$CI_GUARD" scan "$TMP/msg"
  assert_failure
  assert_output --partial "gh run list -c"
  assert_output --partial "git rev-parse HEAD"
}

@test "the refusal goes to stderr, so it is not swallowed as hook output" {
  msg "subject with [skip ci]"
  run bash -c "'$CI_GUARD' scan '$TMP/msg' 2>/dev/null"
  assert_failure
  assert_output ""
}

# ------------------------------------------------------------ commit-msg mode

@test "commit-msg: refuses a marker-bearing message" {
  msg "subject" "" "body [skip ci]"
  run "$CI_GUARD" commit-msg "$TMP/msg"
  assert_failure
  [ "$status" -eq 1 ]
}

@test "commit-msg: TASK_FORCE_NO_CI_GUARD disables the check" {
  msg "subject [skip ci]"
  TASK_FORCE_NO_CI_GUARD=1 run "$CI_GUARD" commit-msg "$TMP/msg"
  assert_success
}

@test "commit-msg: a missing message file never blocks the commit" {
  # A guard-side surprise must not wedge the user's git.
  run "$CI_GUARD" commit-msg "$TMP/absent"
  assert_success
}

# ------------------------------------------------------------- check mode

@test "check: scans HEAD's message by default" {
  setup_repo
  git -C "$MAIN_REPO" commit -q --allow-empty --no-verify -m "describes [ci skip] here"
  run bash -c "cd '$MAIN_REPO' && '$CI_GUARD' check"
  assert_failure
  assert_output --partial "[ci skip]"
}

@test "check: accepts a revision range" {
  setup_repo
  git -C "$MAIN_REPO" commit -q --allow-empty --no-verify -m "clean one"
  git -C "$MAIN_REPO" commit -q --allow-empty --no-verify -m "dirty [no ci] one"
  run bash -c "cd '$MAIN_REPO' && '$CI_GUARD' check 'HEAD~2..HEAD'"
  assert_failure
  assert_output --partial "[no ci]"
}

@test "check: clean history passes" {
  setup_repo
  run bash -c "cd '$MAIN_REPO' && '$CI_GUARD' check"
  assert_success
}

@test "check: outside a git repo is an environment error" {
  run bash -c "cd '$TMP' && '$CI_GUARD' check"
  [ "$status" -eq 2 ]
  assert_output --partial "not in a git repo"
}

# --------------------------------------------------------- hook installation

@test "install-hook: writes an executable commit-msg hook" {
  setup_repo
  run "$CI_GUARD" install-hook "$MAIN_REPO"
  assert_success
  assert [ -x "$MAIN_REPO/.git/hooks/commit-msg" ]
  run grep -qF "task-force:ci-guard-hook" "$MAIN_REPO/.git/hooks/commit-msg"
  assert_success
}

@test "install-hook: is idempotent — no commit-msg.local snowball" {
  setup_repo
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  assert [ -x "$MAIN_REPO/.git/hooks/commit-msg" ]
  assert [ ! -e "$MAIN_REPO/.git/hooks/commit-msg.local" ]
}

@test "install-hook: preserves a pre-existing foreign hook and chains it" {
  setup_repo
  printf '#!/bin/sh\necho FOREIGN-RAN\n' > "$MAIN_REPO/.git/hooks/commit-msg"
  chmod +x "$MAIN_REPO/.git/hooks/commit-msg"

  run "$CI_GUARD" install-hook "$MAIN_REPO"
  assert_success
  assert_output --partial "preserved"
  run grep -qF FOREIGN-RAN "$MAIN_REPO/.git/hooks/commit-msg.local"
  assert_success

  # And the chain actually fires on a clean commit.
  run bash -c "cd '$MAIN_REPO' && git commit -q --allow-empty -m 'clean subject'"
  assert_success
  assert_output --partial "FOREIGN-RAN"
}

@test "install-hook: refuses to guess when both hook names are taken" {
  setup_repo
  printf '#!/bin/sh\nexit 0\n' > "$MAIN_REPO/.git/hooks/commit-msg"
  printf '#!/bin/sh\nexit 0\n' > "$MAIN_REPO/.git/hooks/commit-msg.local"
  chmod +x "$MAIN_REPO/.git/hooks/commit-msg" "$MAIN_REPO/.git/hooks/commit-msg.local"

  run "$CI_GUARD" install-hook "$MAIN_REPO"
  assert_success
  assert_output --partial "leaving the existing commit-msg hook alone"
  # The user's hook is untouched — no marker written into it.
  run grep -qF "task-force:ci-guard-hook" "$MAIN_REPO/.git/hooks/commit-msg"
  assert_failure
}

@test "install-hook: honours core.hooksPath" {
  setup_repo
  mkdir -p "$MAIN_REPO/myhooks"
  git -C "$MAIN_REPO" config core.hooksPath myhooks
  run "$CI_GUARD" install-hook "$MAIN_REPO"
  assert_success
  assert [ -x "$MAIN_REPO/myhooks/commit-msg" ]
  assert [ ! -e "$MAIN_REPO/.git/hooks/commit-msg" ]
}

@test "install-hook: TASK_FORCE_NO_CI_GUARD skips installation entirely" {
  setup_repo
  TASK_FORCE_NO_CI_GUARD=1 run "$CI_GUARD" install-hook "$MAIN_REPO"
  assert_success
  assert [ ! -e "$MAIN_REPO/.git/hooks/commit-msg" ]
}

@test "install-hook: from a linked worktree, installs into the shared hooks dir" {
  # Git shares one hooks dir across a repo's worktrees, so a guard installed
  # from a task worktree must protect the main worktree's commits too — that
  # is where the sync commit which triggered both occurrences was made.
  setup_repo
  setup_worktree wt-hooks
  run "$CI_GUARD" install-hook "$WORKTREE_BASE/wt-hooks"
  assert_success
  assert [ -x "$MAIN_REPO/.git/hooks/commit-msg" ]
}

# ------------------------------------------------------------- end to end

@test "e2e: the installed hook aborts a marker-bearing commit" {
  setup_repo
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  run bash -c "PATH='$(make_guard_bin)':\$PATH; cd '$MAIN_REPO' && git commit --allow-empty -m 'quoting [skip ci] while explaining it'"
  assert_failure
  assert_output --partial "ci-guard"
  # Nothing was committed.
  run git -C "$MAIN_REPO" log --oneline
  refute_output --partial "quoting"
}

@test "e2e: the installed hook lets a clean commit through" {
  setup_repo
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  run bash -c "PATH='$(make_guard_bin)':\$PATH; cd '$MAIN_REPO' && git commit --allow-empty -m 'explains the skip-ci token safely'"
  assert_success
}

@test "e2e: --no-verify is the documented bypass and works" {
  setup_repo
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  run bash -c "PATH='$(make_guard_bin)':\$PATH; cd '$MAIN_REPO' && git commit --allow-empty --no-verify -m 'deliberately [skip ci]'"
  assert_success
}

@test "e2e: the hook no-ops when ci-guard is not on PATH" {
  # A user who uninstalls task-force must not be locked out of committing.
  setup_repo
  "$CI_GUARD" install-hook "$MAIN_REPO" >/dev/null
  run bash -c "PATH='$TMP/empty-bin:/usr/bin:/bin'; cd '$MAIN_REPO' && git commit --allow-empty -m 'has [skip ci] but no guard binary'"
  assert_success
}

# ------------------------------------------------------- task-work wiring

@test "task-work installs the commit-msg hook in all seven loadouts" {
  # The guard only counts if it is wired into the path every worker takes.
  for impl in claude-gh claude-jira claude-local claude-notion kiro-gh kiro-local kiro-notion; do
    run grep -qF 'aw_install_ci_guard_hook "$REPO_ROOT"' "$REPO_ROOT_REAL/$impl/bin/task-work"
    assert_success
    run grep -qF 'source "$AW_ROOT_REAL/lib/ci-guard.sh"' "$REPO_ROOT_REAL/$impl/bin/task-work"
    assert_success
  done
}

@test "install-hook: an unwritable hooks dir warns but never fails the caller" {
  # task-work is `set -e` and sources this installer — a guard-side failure
  # must degrade to a warning, not abort the worktree launch.
  setup_repo
  chmod 500 "$MAIN_REPO/.git/hooks"
  run "$CI_GUARD" install-hook "$MAIN_REPO"
  chmod 700 "$MAIN_REPO/.git/hooks"
  assert_success
  assert_output --partial "commits will NOT be checked"
}
