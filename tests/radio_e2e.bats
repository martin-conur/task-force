#!/usr/bin/env bats
# End-to-end tests: two simulated roles (PM + worker), bidirectional ping,
# cross-repo correlation via the `repo:` field on messages.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_stubs
  export ZELLIJ=fake
  # Bypass the no-role dispatcher gate on `register` (#93); tests still set
  # TASK_FORCE_ROLE per-invocation where the value matters.
  export TASK_FORCE_ROLE=test-runner
  # Don't let the dev shell's $ZELLIJ_TAB fire the _rename_tab safeguard
  # during the register calls below.
  unset ZELLIJ_TAB
  unset TASK_FORCE_PM_ROLE   # exercise the --to pm sender-derivation shim (#165)
  seed_zellij_tabs pm-task-force worker-task-force-issue-60 pm-repo-a pm-repo-b worker-repo-a-feat-x worker-repo-b-feat-y
}

teardown() {
  teardown_all
}

@test "worker pings PM (--to pm shim), PM pings worker — both arrive correctly tagged (#165)" {
  # Per-repo PM (#165): the worker's `--to pm` resolves to pm-<reponame> via the
  # sender session's REPO= basename (task-force), not a global `pm`.
  "$RADIO" register --role pm-task-force --tab pm-task-force --agent claude
  "$RADIO" register --role worker-task-force-issue-60 --tab issue-60 --repo /tmp/task-force --agent claude

  # worker -> PM (bare --to pm, resolved by the shim)
  TASK_FORCE_ROLE=worker-task-force-issue-60 "$RADIO" send \
    --to pm --intent review-requested --pr 62 --repo /tmp/task-force --body "PR #62 ready"
  TASK_FORCE_ROLE=pm-task-force run "$RADIO" check
  assert_output --partial "from=worker-task-force-issue-60"
  assert_output --partial "intent=review-requested"

  # PM -> worker (explicit worker role, no shim)
  TASK_FORCE_ROLE=pm-task-force "$RADIO" send \
    --to worker-task-force-issue-60 --intent re-review-requested --pr 62 \
    --body "address comments"
  TASK_FORCE_ROLE=worker-task-force-issue-60 run "$RADIO" check
  assert_output --partial "from=pm-task-force"
  assert_output --partial "intent=re-review-requested"
}

@test "cross-repo: two workers in different repos reach their OWN per-repo PM, never each other's (#165)" {
  # The core #165 acceptance criterion: two PMs in two repos coexist and each
  # receives only its own repo's reports (was: both mixed into one global pm).
  "$RADIO" register --role pm-repo-a            --tab pm-repo-a --agent claude
  "$RADIO" register --role pm-repo-b            --tab pm-repo-b --agent claude
  "$RADIO" register --role worker-repo-a-feat-x --tab feat-x --repo /repos/repo-a --agent claude
  "$RADIO" register --role worker-repo-b-feat-y --tab feat-y --repo /repos/repo-b --agent claude

  TASK_FORCE_ROLE=worker-repo-a-feat-x "$RADIO" send \
    --to pm --intent review-requested --pr 100 --repo /repos/repo-a --body "from A"
  TASK_FORCE_ROLE=worker-repo-b-feat-y "$RADIO" send \
    --to pm --intent review-requested --pr 200 --repo /repos/repo-b --body "from B"

  # Each PM inbox holds exactly its own repo's one report — no cross-wiring.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm-repo-a/inbox/'*.md | wc -l | tr -d ' '"
  assert_output "1"
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm-repo-b/inbox/'*.md | wc -l | tr -d ' '"
  assert_output "1"

  run bash -c "cat '$TASK_FORCE_HOME/radio/mailbox/pm-repo-a/inbox/'*.md"
  assert_output --partial "from: worker-repo-a-feat-x"
  refute_output --partial "worker-repo-b-feat-y"

  run bash -c "cat '$TASK_FORCE_HOME/radio/mailbox/pm-repo-b/inbox/'*.md"
  assert_output --partial "from: worker-repo-b-feat-y"
  refute_output --partial "worker-repo-a-feat-x"

  # And no global `pm` inbox was ever created.
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm/inbox" ]
}
