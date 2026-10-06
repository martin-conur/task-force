#!/usr/bin/env bats
# A missed TAB_ID capture is reported where it happens (#242).
#
# task-work used to append TAB_ID= only on a hit and say nothing on a miss, so
# the first sign of a failed capture was task-done's "no tab id captured" at
# teardown — hours later, in another command, with the cause gone. These pin
# the loud miss (stderr + a `tab-id:` line in radio's log), the reasons it can
# tell apart, that a miss never aborts the launch, that a hit is silent, and
# task-done's pointer back to the launch-time log line.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  LOG="$TASK_FORCE_HOME/radio/log"
}

teardown() {
  [[ -z "${NOJQ_BIN:-}" ]] || rm -rf "$NOJQ_BIN"
  teardown_all
}

# ---------------------------------------------------------------------------
# lib/zellij-tab.sh: aw_zellij_tab_id_miss_reason
# ---------------------------------------------------------------------------

miss_reason() {
  # shellcheck source=lib/zellij-tab.sh
  bash -c 'source "$1"; aw_zellij_tab_id_miss_reason "$2"' _ "$REPO_ROOT_REAL/lib/zellij-tab.sh" "$1"
}

@test "miss reason: no-zellij-bin when zellij is not on PATH" {
  export ZELLIJ=fake-session
  NOJQ_BIN=$(make_nojq_bin)   # bash and coreutils only: no zellij, no jq
  run env PATH="$NOJQ_BIN" bash -c 'source "$1"; aw_zellij_tab_id_miss_reason "$2"' _ "$REPO_ROOT_REAL/lib/zellij-tab.sh" my-feature
  assert_success
  assert_output --regexp '^no-zellij-bin '
}

@test "miss reason: not-in-zellij when \$ZELLIJ is unset" {
  unset ZELLIJ
  run miss_reason my-feature
  assert_success
  assert_output --regexp '^not-in-zellij '
}

@test "miss reason: no-jq when jq is not on PATH" {
  export ZELLIJ=fake-session
  NOJQ_BIN=$(make_nojq_bin)
  ln -s "$STUB_BIN/zellij" "$NOJQ_BIN/zellij"
  run env PATH="$NOJQ_BIN" bash -c 'source "$1"; aw_zellij_tab_id_miss_reason "$2"' _ "$REPO_ROOT_REAL/lib/zellij-tab.sh" my-feature
  assert_success
  assert_output --regexp '^no-jq '
}

@test "miss reason: list-tabs-empty when zellij lists nothing" {
  export ZELLIJ=fake-session
  run miss_reason my-feature
  assert_success
  assert_output --regexp '^list-tabs-empty '
}

@test "miss reason: no-match names the slug, its length, and the names zellij reported" {
  export ZELLIJ=fake-session
  export STUB_ZELLIJ_TABS_JSON='[{"name":"pm-repo","tab_id":0},{"name":"my-featur","tab_id":3}]'
  run miss_reason my-feature
  assert_success
  assert_output --regexp '^no-match '
  assert_output --partial '"my-feature" (10 chars)'
  assert_output --partial '["pm-repo","my-featur"]'
}

@test "miss reason: race when the tab is listed by the time the diagnosis re-queries" {
  export ZELLIJ=fake-session
  export STUB_ZELLIJ_TABS_JSON='[{"name":"▶️ my-feature","tab_id":3}]'
  run miss_reason my-feature
  assert_success
  assert_output --regexp '^race '
}

# ---------------------------------------------------------------------------
# task-work: a miss is loud, logged, and non-fatal; a hit is silent
# ---------------------------------------------------------------------------

@test "task-work: a missed capture is reported on stderr and logged, and the launch still succeeds" {
  export ZELLIJ=fake-session
  export STUB_ZELLIJ_TABS_JSON='[{"name":"someone-else","tab_id":4}]'
  run env AW_IMPL=claude-gh "$TASK_WORK" my-feature
  assert_success
  assert_output --partial "Started worker in"
  assert_output --partial "Could not capture the zellij tab id for 'my-feature'"
  assert_output --partial '["someone-else"]'
  assert_output --partial "grep 'tab-id:'"
  run grep "^TAB_ID=" "$WORKTREE_BASE/.my-feature.info"
  assert_failure
  run grep -E ' tab-id: task-work capture missed slug=my-feature reason=no-match info=.*/\.my-feature\.info detail=' "$LOG"
  assert_success
}

@test "task-work: the log line says not-in-zellij when run outside zellij" {
  unset ZELLIJ
  run env AW_IMPL=claude-gh "$TASK_WORK" my-feature
  assert_success
  assert_output --partial "not running inside zellij"
  run grep -c 'tab-id: task-work capture missed slug=my-feature reason=not-in-zellij ' "$LOG"
  assert_output "1"
}

@test "task-work: a successful capture prints nothing extra and logs nothing" {
  export ZELLIJ=fake-session
  export STUB_ZELLIJ_TABS_JSON='[{"name":"my-feature","tab_id":12}]'
  run env AW_IMPL=claude-gh "$TASK_WORK" my-feature
  assert_success
  local hit_output="$output"
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${TAB_ID:-}" "12"
  refute_output --partial "tab id"
  assert [ ! -e "$LOG" ]
  # Byte-for-byte: the output is exactly the pre-#242 sequence of lines, with
  # nothing appended after the launch line.
  run tail -n 1 <<<"$hit_output"
  assert_output --regexp '^Started worker in .*/my-feature \(branch: task/my-feature, base: main\)$'
}

@test "task-work (kiro-gh): the shared region reports a miss in the kiro loadout too" {
  setup_kiro_agents
  export ZELLIJ=fake-session
  run env AW_IMPL=kiro-gh "$TASK_WORK" my-feature
  assert_success
  assert_output --partial "Could not capture the zellij tab id for 'my-feature'"
  run grep -c 'tab-id: task-work capture missed slug=my-feature reason=list-tabs-empty ' "$LOG"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# The other callers: each names itself in the log line, so a miss is
# attributable to the command that launched the tab.
# ---------------------------------------------------------------------------

@test "task-reviewer (claude): a missed capture is reported and logged as task-reviewer" {
  setup_kiro_agents
  export ZELLIJ=fake-session GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_success
  assert_output --partial "Could not capture the zellij tab id for 'review-pr42'"
  run grep -c 'tab-id: task-reviewer capture missed slug=review-pr42 reason=list-tabs-empty ' "$LOG"
  assert_output "1"
}

@test "task-reviewer (kiro-gh): a missed capture is reported and logged as task-reviewer" {
  setup_kiro_agents
  export ZELLIJ=fake-session GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  run "$TASK_REVIEWER_KIRO" 42
  assert_success
  assert_output --partial "Could not capture the zellij tab id for 'review-pr42'"
  run grep -c 'tab-id: task-reviewer capture missed slug=review-pr42 reason=list-tabs-empty ' "$LOG"
  assert_output "1"
}

@test "task-recreate-worker: a missed rebind is reported and logged as task-recreate-worker" {
  export ZELLIJ=fake-session
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/issue-42" -b task/issue-42
  printf 'BASE_BRANCH=main\nSLUG=issue-42\nGH_URL=\nTAB_ID=999\n' > "$WORKTREE_BASE/.issue-42.info"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "Could not capture the zellij tab id for 'issue-42'"
  run grep -c 'tab-id: task-recreate-worker capture missed slug=issue-42 reason=list-tabs-empty ' "$LOG"
  assert_output "1"
  # The stale id was stripped and nothing replaced it.
  run grep '^TAB_ID=' "$WORKTREE_BASE/.issue-42.info"
  assert_failure
}

# ---------------------------------------------------------------------------
# task-done: the skip message names which source came up empty
# ---------------------------------------------------------------------------
#
# These run the canonical bin/task-done with AW_IMPL pinning the loadout. #242
# landed against claude-gh/bin/task-done, one of seven copies; #236 collapsed
# those into one body composing a tracker module, so there is a single place for
# this skip line to live now. The behaviour asserted is unchanged, and it is in
# the shared body — no tracker or agent hook goes anywhere near tab-id capture.

@test "task-done: a sidecar without TAB_ID= points at the launch-time tab-id: log line" {
  setup_worktree my-feature
  cd "$WORKTREE_BASE/my-feature"
  export ZELLIJ=fake-session
  unset TASK_FORCE_ROLE
  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "Skipping zellij close-tab (no tab id captured"
  assert_output --partial ".my-feature.info has no TAB_ID= line; the launch logged why: grep 'tab-id:.*slug=my-feature ' $TASK_FORCE_HOME/radio/log"
}

@test "task-done: says \$ZELLIJ is unset when that is why no id was read" {
  setup_worktree my-feature
  cd "$WORKTREE_BASE/my-feature"
  unset ZELLIJ TASK_FORCE_ROLE
  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_success
  assert_output --partial "(task-done is not running inside zellij (\$ZELLIJ unset))"
}

@test "task-done: says there is no sidecar when the branch no longer matches the slug" {
  setup_worktree my-feature
  cd "$WORKTREE_BASE/my-feature"
  git checkout -q -b some-other-branch
  export ZELLIJ=fake-session
  unset TASK_FORCE_ROLE
  run env AW_IMPL=claude-gh "$TASK_DONE" --remove-worktree --force
  assert_output --partial "(no sidecar at "
  assert_output --partial "(branch 'some-other-branch')"
}
