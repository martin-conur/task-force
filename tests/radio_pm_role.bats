#!/usr/bin/env bats
# Per-repo PM role (#165): the `--to pm` compat shim, alias-session hop,
# basename-collision warning, and the register-alias / unregister-sweep /
# orphans plumbing that supports one PM overseeing N repos.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ              # no wakeup attempts — exercise the queue paths
  unset TASK_FORCE_PM_ROLE  # tests opt in explicitly
  export TASK_FORCE_ROLE=test-runner
}

teardown() {
  teardown_all
}

_inbox_count() {  # $1 = role
  ls "$TASK_FORCE_HOME/radio/mailbox/$1/inbox/"*.md 2>/dev/null | wc -l | tr -d ' '
}

# ----- --to pm compat shim resolution order --------------------------------

@test "--to pm resolves via \$TASK_FORCE_PM_ROLE (launch-time identity) (#165)" {
  export TASK_FORCE_PM_ROLE=pm-myrepo
  "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  TASK_FORCE_ROLE=worker-myrepo-issue-1 run "$RADIO" send \
    --to pm --intent review-requested --pr 42 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm-myrepo"
  assert_output --partial 'TASK_FORCE_PM_ROLE'
  assert_equal "$(_inbox_count pm-myrepo)" "1"
  assert_equal "$(_inbox_count pm)" "0"
}

@test "--to pm resolves via the sender session's REPO= basename (#165)" {
  # No env var; the sender's own session file names its repo.
  "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  "$RADIO" register --role worker-myrepo-issue-1 --tab issue-1 \
    --repo /somewhere/myrepo --agent claude
  TASK_FORCE_ROLE=worker-myrepo-issue-1 run "$RADIO" send \
    --to pm --intent review-requested --pr 7 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm-myrepo"
  assert_equal "$(_inbox_count pm-myrepo)" "1"
}

@test "--to pm resolves by splitting the sender role against live pm-<name> sessions (#165)" {
  # No env var and no sender session file — fall back to matching the slug
  # prefix against a registered pm-<name>.
  "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  TASK_FORCE_ROLE=worker-myrepo-issue-9 run "$RADIO" send \
    --to pm --intent review-requested --pr 9 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm-myrepo"
  assert_equal "$(_inbox_count pm-myrepo)" "1"
}

@test "--to pm with \$TASK_FORCE_PM_ROLE set-but-unregistered + literal pm live resolves to pm (#165)" {
  # The env names a future PM address that isn't up yet; a live literal pm is.
  # Registration-gated step 1 must fall through to the migration fallback.
  export TASK_FORCE_PM_ROLE=pm-notyet
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send \
    --to pm --intent review-requested --pr 2 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm (via literal pm"
  assert_equal "$(_inbox_count pm)" "1"
  assert_equal "$(_inbox_count pm-notyet)" "0"
}

@test "--to pm ignores a malformed \$TASK_FORCE_PM_ROLE instead of hard-failing the send (#165)" {
  # A hand-exported bad value must degrade to the literal-pm queue, not trip
  # cmd_send's post-shim _validate_role || exit 2.
  export TASK_FORCE_PM_ROLE='pm-My.App'
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send \
    --to pm --intent review-requested --pr 2 --body "PR up"
  assert_success   # NOT exit 2
  assert_equal "$(_inbox_count pm)" "1"
}

@test "--to pm falls back to literal pm when the derived role isn't registered but pm is (migration window) (#165)" {
  # The running PM predates the rename (role `pm`); the sender can derive
  # pm-myrepo from its REPO=, but that session doesn't exist yet — so the ping
  # must reach the live `pm`, not strand in an unregistered pm-myrepo inbox.
  "$RADIO" register --role pm --tab pm --agent claude
  "$RADIO" register --role worker-myrepo-issue-3 --tab issue-3 \
    --repo /somewhere/myrepo --agent claude
  TASK_FORCE_ROLE=worker-myrepo-issue-3 run "$RADIO" send \
    --to pm --intent review-requested --pr 3 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm (via literal pm"   # migration fallback, named
  assert_equal "$(_inbox_count pm)" "1"
  assert_equal "$(_inbox_count pm-myrepo)" "0"
}

@test "--to pm falls back to literal pm when a pre-migration pm session exists (#165)" {
  "$RADIO" register --role pm --tab pm --agent claude
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send \
    --to pm --intent review-requested --pr 1 --body "PR up"
  assert_success
  # Resolution line prints on every shim invocation (RC-7), naming literal pm.
  assert_output --partial "radio: --to pm → pm (via literal pm"
  assert_equal "$(_inbox_count pm)" "1"
}

@test "--to pm with nothing configured queues to literal pm and warns (#165)" {
  # Unresolved: no env, no sender session, no pm-* / pm session. The honest
  # signal is the no-session WARNING, not a silent misdelivery.
  export ZELLIJ=fake-session
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send \
    --to pm --intent review-requested --pr 1 --body "PR up"
  assert_success
  assert_output --partial "radio: WARNING — no session for pm"
  assert_equal "$(_inbox_count pm)" "1"
}

# ----- alias hop ------------------------------------------------------------

@test "send to an alias role routes into the primary's inbox (#165)" {
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  TASK_FORCE_ROLE=worker-other-issue-2 run "$RADIO" send \
    --to pm-other --intent review-requested --pr 5 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm-other → pm-primary"
  assert_output --partial "via alias pm-other"
  assert_equal "$(_inbox_count pm-primary)" "1"
  assert_equal "$(_inbox_count pm-other)" "0"
}

@test "a two-hop alias chain is refused (exit 2) (#165)" {
  "$RADIO" register-alias --role pm-a --alias pm-b --repo /x/a
  "$RADIO" register-alias --role pm-b --alias pm-c --repo /x/b
  TASK_FORCE_ROLE=worker-a-issue-1 run "$RADIO" send \
    --to pm-a --intent review-requested --body "PR up"
  assert_failure
  assert_output --partial "alias chain too deep"
}

# ----- basename-collision warning -------------------------------------------

@test "register warns (non-blocking) when a role is re-claimed for a different repo (#165)" {
  "$RADIO" register --role pm-api --tab pm-api --repo /work/a/api --agent claude
  run "$RADIO" register --role pm-api --tab pm-api --repo /work/b/api --agent claude
  assert_success   # warn, don't block
  assert_output --partial "WARNING"
  assert_output --partial "same basename"
}

@test "register does not warn on a re-register with the same repo (#165)" {
  "$RADIO" register --role pm-api --tab pm-api --repo /work/a/api --agent claude
  run "$RADIO" register --role pm-api --tab pm-api --repo /work/a/api --agent claude
  assert_success
  refute_output --partial "WARNING"
}

# ----- register-alias / unregister sweep / orphans --------------------------

@test "register-alias writes an ALIAS= session and creates no inbox (#165)" {
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  local f="$TASK_FORCE_HOME/radio/sessions/pm-other.info"
  assert [ -f "$f" ]
  run cat "$f"
  assert_output --partial "ALIAS=pm-primary"
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm-other/inbox" ]
}

@test "register-alias refuses to alias a role to itself (#165)" {
  run "$RADIO" register-alias --role pm-a --alias pm-a
  assert_failure
  assert_output --partial "cannot point at itself"
}

@test "unregistering the primary sweeps its alias sessions (#165)" {
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/pm-other.info" ]
  TASK_FORCE_ROLE=pm-primary "$RADIO" unregister
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/pm-primary.info" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/pm-other.info" ]
}

@test "orphans flags an alias whose target session is missing (#165)" {
  # Alias with no live primary (unclean exit left it dangling).
  "$RADIO" register-alias --role pm-other --alias pm-gone --repo /x/other
  run "$RADIO" orphans
  assert_success
  assert_output --partial "pm-other"
  assert_output --partial "target session missing"
}

@test "orphans does not flag an alias whose target session is live (#165)" {
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  run "$RADIO" orphans
  assert_success
  refute_output --partial "pm-other"
}

# ----- RC-2: worktree-proof repo-name derivation ----------------------------

@test "register persists REPO_NAME= as the MAIN repo, not the worktree slug (#165 RC-2)" {
  local parent main wt
  parent=$(mktemp -d)
  main="$parent/mainrepo"
  mkdir -p "$main"
  git -C "$main" init -q -b main
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$parent/mainrepo-worktrees/feat-x"
  git -C "$main" worktree add -q "$wt" -b task/feat-x
  # A worker registers from inside the worktree — REPO= is the worktree path.
  "$RADIO" register --role worker-mainrepo-feat-x --tab feat-x --repo "$wt" --agent claude
  run grep '^REPO_NAME=' "$TASK_FORCE_HOME/radio/sessions/worker-mainrepo-feat-x.info"
  assert_output "REPO_NAME=mainrepo"
  git -C "$main" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$parent"
}

@test "--to pm from a worktree worker resolves via persisted REPO_NAME (not the slug) (#165 RC-2)" {
  local parent main wt
  parent=$(mktemp -d)
  main="$parent/mainrepo"
  mkdir -p "$main"
  git -C "$main" init -q -b main
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$parent/mainrepo-worktrees/feat-y"
  git -C "$main" worktree add -q "$wt" -b task/feat-y
  "$RADIO" register --role pm-mainrepo --tab pm-mainrepo --agent claude
  "$RADIO" register --role worker-mainrepo-feat-y --tab feat-y --repo "$wt" --agent claude
  TASK_FORCE_ROLE=worker-mainrepo-feat-y run "$RADIO" send \
    --to pm --intent review-requested --pr 9 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm-mainrepo"
  assert_equal "$(_inbox_count pm-mainrepo)" "1"
  git -C "$main" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$parent"
}

# ----- RC-3: longest-match slug split ---------------------------------------

@test "--to pm slug-split prefers the LONGEST registered pm-<name> (#165 RC-3)" {
  # api and api-server both live; worker-api-server-fix-1 must reach pm-api-server,
  # not pm-api (which glob order could otherwise pick).
  "$RADIO" register --role pm-api        --tab pm-api        --agent claude
  "$RADIO" register --role pm-api-server --tab pm-api-server --agent claude
  TASK_FORCE_ROLE=worker-api-server-fix-1 run "$RADIO" send \
    --to pm --intent review-requested --pr 1 --body "PR up"
  assert_success
  assert_output --partial "radio: --to pm → pm-api-server"
  assert_equal "$(_inbox_count pm-api-server)" "1"
  assert_equal "$(_inbox_count pm-api)" "0"
}

# ----- RC-4: alias lifecycle ------------------------------------------------

@test "register-alias records the alias in the primary's sidecar and register re-seeds it (#165 RC-4a)" {
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/pm-primary.aliases" ]
  # Simulate an erroneous sweep dropping the alias mid-session.
  rm -f "$TASK_FORCE_HOME/radio/sessions/pm-other.info"
  # A re-register (SessionStart on /compact) must re-seed it from the sidecar.
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/pm-other.info" ]
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-other.info"
  assert_output --partial "ALIAS=pm-primary"
}

@test "register-alias migrates a pre-existing inbox into the primary (#165 RC-4b)" {
  # A worker pinged pm-other while no PM ran — the message sits in pm-other/inbox.
  export ZELLIJ=fake-session
  TASK_FORCE_ROLE=worker-other-1 "$RADIO" send --to pm-other --intent ping --body "early" >/dev/null
  assert_equal "$(_inbox_count pm-other)" "1"
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /x/other
  # The queued message is folded into the primary's inbox; the alias owns none.
  assert_equal "$(_inbox_count pm-primary)" "1"
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm-other/inbox" ]
}

@test "a real PM claiming an aliased address does not trip the collision warning (#165 RC-4c)" {
  "$RADIO" register-alias --role pm-api --alias pm-primary --repo /alias/api
  run "$RADIO" register --role pm-api --tab pm-api --repo /real/api --agent claude
  assert_success
  refute_output --partial "WARNING"
  # It became a real (non-alias) session.
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-api.info"
  refute_output --partial "ALIAS="
}

@test "re-pointing an alias at a different primary/repo warns (#165 RC-4d)" {
  "$RADIO" register-alias --role pm-x --alias pm-a --repo /1/x
  run "$RADIO" register-alias --role pm-x --alias pm-b --repo /2/x
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "re-pointing"
}

@test "re-pointing an alias's repo rewrites the sidecar (re-seed replays the new repo, not the stale one) (#165)" {
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /old/other
  "$RADIO" register-alias --role pm-other --alias pm-primary --repo /new/other
  # Sidecar holds exactly one pm-other line, with the new repo.
  run bash -c "grep -c '^pm-other|' '$TASK_FORCE_HOME/radio/sessions/pm-primary.aliases'"
  assert_output "1"
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-primary.aliases"
  assert_output --partial "pm-other|/new/other"
  refute_output --partial "/old/other"
  # A re-seed (drop the .info, re-register the primary) replays the NEW repo.
  rm -f "$TASK_FORCE_HOME/radio/sessions/pm-other.info"
  "$RADIO" register --role pm-primary --tab pm-primary --agent claude
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-other.info"
  assert_output --partial "REPO=/new/other"
}
