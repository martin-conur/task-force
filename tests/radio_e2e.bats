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
  seed_zellij_tabs pm worker-task-force-issue-60 worker-repo-a-feat-x worker-repo-b-feat-y
}

teardown() {
  teardown_all
}

@test "worker pings PM, PM pings worker — both arrive correctly tagged" {
  "$RADIO" register --role pm    --tab pm    --agent claude
  "$RADIO" register --role worker-task-force-issue-60 --tab issue-60 --repo /tmp/issue-60 --agent claude

  # worker -> PM
  TASK_FORCE_ROLE=worker-task-force-issue-60 "$RADIO" send \
    --to pm --intent review-requested --pr 62 --repo /tmp/issue-60 --body "PR #62 ready"
  TASK_FORCE_ROLE=pm run "$RADIO" check
  assert_output --partial "from=worker-task-force-issue-60"
  assert_output --partial "intent=review-requested"

  # PM -> worker
  TASK_FORCE_ROLE=pm "$RADIO" send \
    --to worker-task-force-issue-60 --intent re-review-requested --pr 62 \
    --body "address comments"
  TASK_FORCE_ROLE=worker-task-force-issue-60 run "$RADIO" check
  assert_output --partial "from=pm"
  assert_output --partial "intent=re-review-requested"
}

@test "cross-repo: two workers in different repos both ping the same PM" {
  "$RADIO" register --role pm                    --tab pm    --agent claude
  "$RADIO" register --role worker-repo-a-feat-x  --tab feat-x --repo /repos/a --agent claude
  "$RADIO" register --role worker-repo-b-feat-y  --tab feat-y --repo /repos/b --agent claude

  TASK_FORCE_ROLE=worker-repo-a-feat-x "$RADIO" send \
    --to pm --intent review-requested --pr 100 --repo /repos/a --body "from A"
  TASK_FORCE_ROLE=worker-repo-b-feat-y "$RADIO" send \
    --to pm --intent review-requested --pr 200 --repo /repos/b --body "from B"

  # Both messages should be in the PM's inbox, each carrying its own repo tag.
  run bash -c "ls '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md | wc -l"
  assert_output --partial "2"

  run bash -c "cat '$TASK_FORCE_HOME/radio/mailbox/pm/inbox/'*.md"
  assert_output --partial "from: worker-repo-a-feat-x"
  assert_output --partial "from: worker-repo-b-feat-y"
  assert_output --partial "repo: /repos/a"
  assert_output --partial "repo: /repos/b"
}
