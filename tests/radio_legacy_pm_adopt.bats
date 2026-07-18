#!/usr/bin/env bats
# Legacy `pm` inbox adoption (#182). Post-#165 no role ever registers as the
# literal `pm` again, so `mailbox/pm/inbox` is write-only: the pre-migration
# backlog plus any env-less `--to pm` fallback sends land there with no
# consumer. When a repo-scoped pm-<reponame> registers FRESH (#168 gate) and
# that inbox is non-empty with no live literal-`pm` session, register migrates
# each message into the new PM's inbox with an `adopted-from:` provenance header
# and the existing drain-on-register summary surfaces it. One-time backfill;
# closes the fallback path.

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

# Queue a message into the literal `pm` inbox with no session running (ZELLIJ
# unset → cmd_send only writes the file, no wake attempt), mirroring the
# 'no session for pm' strandings the ticket describes.
_queue_legacy_pm() {
  local intent="${1:-review-requested}" pr="${2:-}" issue="${3:-}" from="${4:-worker-bar}"
  TASK_FORCE_ROLE="$from" "$RADIO" send --to pm --intent "$intent" \
    ${pr:+--pr "$pr"} ${issue:+--issue "$issue"} --body "queued while pm offline"
}

# ----- the happy path: fresh pm-<repo> adopts the orphaned pm backlog --------

@test "register: fresh pm-<repo> migrates the legacy pm inbox into its own (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  _queue_legacy_pm spec-ready "" 7 planner
  assert_equal "$(_inbox_count pm)" "2"

  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success

  # The legacy inbox is drained; the two messages now live in pm-myrepo's inbox.
  assert_equal "$(_inbox_count pm)" "0"
  assert_equal "$(_inbox_count pm-myrepo)" "2"
}

@test "register: adopted messages are surfaced by the drain summary + a legacy flag (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  _queue_legacy_pm spec-ready "" 7 planner

  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  # Reuses the #168 drain framing — no separate print path.
  assert_output --partial "[radio] 2 message(s) queued while this role was offline:"
  # The frontmatter fields still thread through the summary post-migration.
  assert_output --partial "intent=review-requested pr=41"
  assert_output --partial "intent=spec-ready issue=7"
  # Legacy backfill is flagged so the PM knows these were adopted, not sent here.
  assert_output --partial "adopted from the legacy \`pm\` inbox"
}

@test "register: each migrated message carries an adopted-from provenance header (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  TASK_FORCE_ROLE=pm-myrepo "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude

  run cat "$TASK_FORCE_HOME/radio/mailbox/pm-myrepo/inbox"/*.md
  assert_output --partial "adopted-from: pm (legacy inbox, backfilled by pm-myrepo at "
  # The original frontmatter is preserved verbatim alongside the new line.
  assert_output --partial "intent: review-requested"
  assert_output --partial "from: worker-a"
}

@test "register: adopted message keeps its id and acks via radio read (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  local id
  id=$(basename "$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox"/*.md)" .md)

  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  # The filename/id is preserved, so the drain summary names a real ackable id.
  assert_output --partial "$id"

  # And `radio read <id>` drains it normally from the new inbox.
  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" read "$id"
  assert_success
  assert_equal "$(_inbox_count pm-myrepo)" "0"
}

# ----- guards ---------------------------------------------------------------

@test "register: does NOT adopt when a live literal-pm session still owns the inbox (#182)" {
  # A real `pm` is up (fresh heartbeat) — its inbox is not orphaned. A later
  # pm-<repo> must not steal from it.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  _queue_legacy_pm review-requested 41 "" worker-a

  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  assert_equal "$(_inbox_count pm)" "1"
  assert_equal "$(_inbox_count pm-myrepo)" "0"
  refute_output --partial "adopted from the legacy"
}

@test "register: adopts when the literal-pm session is heartbeat-dead (#182)" {
  # A stale `pm` session file (crashed tab, >1h stale heartbeat) is not a live
  # owner — the orphaned inbox is fair game for adoption.
  TASK_FORCE_ROLE=pm "$RADIO" register --role pm --tab pm --agent claude
  _queue_legacy_pm review-requested 41 "" worker-a
  # Backdate the heartbeat well past the 1h staleness threshold.
  local sess="$TASK_FORCE_HOME/radio/sessions/pm.info"
  sed -i.bak 's/^LAST_HEARTBEAT=.*/LAST_HEARTBEAT=2000-01-01T00:00:00Z/' "$sess" && rm -f "$sess.bak"

  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  assert_equal "$(_inbox_count pm)" "0"
  assert_equal "$(_inbox_count pm-myrepo)" "1"
}

@test "register: re-register (non-fresh) pm-<repo> does NOT re-adopt (#182)" {
  # First fresh register adopts. A later message strands in the legacy inbox,
  # then a /compact-style re-register fires — the fresh=1 gate must skip it, so
  # the second legacy message is NOT swept mid-session.
  _queue_legacy_pm review-requested 41 "" worker-a
  TASK_FORCE_ROLE=pm-myrepo "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_equal "$(_inbox_count pm)" "0"

  _queue_legacy_pm changes-requested 42 "" worker-c
  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  # The second message stays in the legacy inbox — re-register did not adopt.
  assert_equal "$(_inbox_count pm)" "1"
  refute_output --partial "adopted from the legacy"
}

@test "register: a non-pm role never adopts the legacy pm inbox (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  TASK_FORCE_ROLE=worker-foo run "$RADIO" register --role worker-foo --tab worker-foo --agent claude
  assert_success
  assert_equal "$(_inbox_count pm)" "1"
  refute_output --partial "adopted from the legacy"
}

@test "register: literal-pm register does not adopt its own inbox (#182)" {
  # `pm` is not `pm-*`; the guard must not treat it as an adopter (it would
  # otherwise try to migrate its inbox into itself).
  _queue_legacy_pm review-requested 41 "" worker-a
  TASK_FORCE_ROLE=pm run "$RADIO" register --role pm --tab pm --agent claude
  assert_success
  # The literal pm's own drain still surfaces its backlog (that's #168), but no
  # adoption/migration happened — the message stays in pm's own inbox.
  assert_equal "$(_inbox_count pm)" "1"
  refute_output --partial "adopted from the legacy"
}

@test "register: empty legacy pm inbox → no adoption, no extra output (#182)" {
  TASK_FORCE_ROLE=pm-myrepo run "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  assert_success
  assert_output ""
}

@test "register: adoption is logged for postmortem (#182)" {
  _queue_legacy_pm review-requested 41 "" worker-a
  TASK_FORCE_ROLE=pm-myrepo "$RADIO" register --role pm-myrepo --tab pm-myrepo --agent claude
  run cat "$TASK_FORCE_HOME/radio/log"
  assert_output --partial "adopt: migrated 1 legacy pm message(s) into role=pm-myrepo"
}
