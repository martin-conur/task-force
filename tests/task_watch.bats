#!/usr/bin/env bats
# bin/task-watch (#328): poll Jira for ai-auto bugs, claim each once, radio the
# PM a ticket-filed intent. Jira is tests/helpers/stubs/acli playing a JSON
# file, so a second poll sees the labels the first one swapped. Every test runs
# against a scratch repo and a scratch $TASK_FORCE_HOME, under /bin/bash.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

WATCH="$REPO_ROOT_REAL/bin/task-watch"

setup() {
  setup_repo
  setup_task_force_home
  setup_stubs
  unset TASK_FORCE_ROLE TASK_FORCE_PM_ROLE
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  LEDGER="$TASK_FORCE_HOME/watch/$NAME"
  PM_INBOX="$TASK_FORCE_HOME/radio/mailbox/pm-$NAME/inbox"
  mkdir -p "$MAIN_REPO/.claude"
  cat >"$MAIN_REPO/.claude/jira-workflow.md" <<'DOC'
<!-- task-init:managed:start -->
- **Site**: `https://acme.atlassian.net`
- **Project key(s)**: `PROJ`
- **Watch label**: `ai-auto`
- **Watch max in flight**: `2`
- **Watch failure cap**: `2`
<!-- task-init:managed:end -->
DOC
  export ACLI_STUB_ISSUES="$BATS_TEST_TMPDIR/issues.json"
  echo '[]' >"$ACLI_STUB_ISSUES"
  # acli's profile file: the account the PM and the watcher post as (#338).
  export TASK_WATCH_ACLI_CONFIG="$BATS_TEST_TMPDIR/jira_config.yaml"
  cat >"$TASK_WATCH_ACLI_CONFIG" <<'YAML'
version: 1
current_profile: cloud-1:acct:pm-self
profiles:
    - site: example
      cloud_id: cloud-0
      account_id: acct:someone-else
    - site: example
      cloud_id: cloud-1
      account_id: acct:pm-self
YAML
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

watch() { /bin/bash "$WATCH" "$@"; }

# issue <key> <label>... — add a ticket to the stub's Jira.
issue() {
  local key="$1"; shift
  local labels
  labels=$(printf '%s\n' "$@" | jq -R . | jq -s -c .)
  jq --arg k "$key" --argjson l "$labels" \
    '. + [{key: $k, fields: {labels: $l, summary: ("summary of " + $k), status: {name: "To Do", statusCategory: {key: "new"}}}}]' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}

set_done() {
  jq --arg k "$1" 'map(if .key == $k then .fields.status = {name: "Done", statusCategory: {key: "done"}} else . end)' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
delete_issue() {
  jq --arg k "$1" 'map(select(.key != $k))' "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
# Age a pending ledger entry past any timeout.
age_pending() { sed -i.bak 's/^PENDING_SINCE=.*/PENDING_SINCE=1/' "$LEDGER/$1"; }
runs_of() { sed -n 's/^RUNS=//p' "$LEDGER/$1"; }

labels_of() { jq -r --arg k "$1" '.[] | select(.key == $k) | .fields.labels | join(",")' "$ACLI_STUB_ISSUES"; }
set_labels() {
  jq --arg k "$1" --arg l "$2" 'map(if .key == $k then .fields.labels = ($l | split(",")) else . end)' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}

# The PM inbox's ticket-filed messages, as their issue keys, sorted: a radio id
# carries a random suffix after its one-second timestamp, so two messages sent
# in the same second list in no particular order.
pinged() {
  local f
  for f in "$PM_INBOX"/*.md; do
    [[ -f "$f" ]] || continue
    grep -q '^intent: ticket-filed$' "$f" && sed -n 's/^issue: //p' "$f"
  done | sort
  return 0
}

edits() { grep -c 'workitem edit' "$STUB_CALLS_DIR/acli.calls" 2>/dev/null || true; }

# comment <key> <author account id> <seconds from now> [<utc offset hours>]:
# a Jira comment, its created time in Jira's own format, milliseconds and a
# numeric offset: `2026-10-30T22:48:06.665-0700`.
comment() {
  jq --arg k "$1" --arg a "$2" --argjson d "$3" --argjson o "${4:-0}" '
    map(if .key == $k then .fields.comment.comments += [{
      id: ((.fields.comment.comments // []) | length | tostring),
      author: {accountId: $a},
      created: ((now + $d + $o * 3600 | floor | strftime("%Y-%m-%dT%H:%M:%S.665"))
                + (if $o < 0 then "-" else "+" end)
                + ($o | fabs | tostring | if length < 2 then "0" + . else . end) + "00"),
      body: "text"}] else . end)' "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
set_description() {
  jq --arg k "$1" --arg d "$2" 'map(if .key == $k then .fields.description = $d else . end)' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
# Claim <key>, then have the PM bounce it and the watcher see the bounce.
claim_and_bounce() {
  watch --once >/dev/null
  set_labels "$1" "ai-auto:claimed,ai-auto:needs-info"
  watch --once >/dev/null
}
state_of() { sed -n 's/^STATE=//p' "$LEDGER/$1"; }

# A task-work worktree working on <key>: the sidecar plus its directory.
dispatch() {
  local slug
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  mkdir -p "$WORKTREE_BASE/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nJIRA_REF=https://acme.atlassian.net/browse/%s\nAGENT=claude\n' \
    "$slug" "$1" >"$WORKTREE_BASE/.$slug.info"
}
finish() {
  local slug
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  rm -rf "${WORKTREE_BASE:?}/$slug" "$WORKTREE_BASE/.$slug.info"
}

@test "--once claims a labelled bug, then sends exactly one ticket-filed with the summary" {
  issue PROJ-1 ai-auto other
  run watch --once
  assert_success
  assert_output --partial "ticket-filed PROJ-1"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed,other"
  assert_equal "$(pinged)" "PROJ-1"
  run cat "$PM_INBOX"/*.md
  assert_output --partial "from: watch-$NAME"
  assert_output --partial "PROJ-1: summary of PROJ-1"
  assert_output --partial "https://acme.atlassian.net/browse/PROJ-1"
  # The default JQL: project, Bug, the label, minus claimed and failed, paginated.
  assert_stub_called acli 'labels = "ai-auto" AND labels not in ("ai-auto:claimed", "ai-auto:failed")'
  assert_stub_called acli '--paginate --json'
  assert_stub_called acli 'issuetype = "Bug"'
  # The claim is one call.
  assert_stub_called acli 'edit --key PROJ-1 --labels ai-auto:claimed --remove-labels ai-auto --yes --json'
}

@test "a second poll claims nothing and pings nothing again" {
  issue PROJ-1 ai-auto
  watch --once >/dev/null
  run watch --once
  assert_success
  assert_output --partial "claimed 0, in flight 1/2"
  assert_equal "$(pinged)" "PROJ-1"
  assert_equal "$(edits)" 1
}

@test "the concurrency cap: at max in flight the rest stay queued and unclaimed" {
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto; issue PROJ-3 ai-auto
  run watch --once
  assert_success
  assert_output --partial "claimed 2, in flight 2/2, 1 left queued at the cap"
  assert_equal "$(labels_of PROJ-3)" "ai-auto"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-2 "
}

@test "an override below the managed end marker wins over the template's value" {
  printf '\n## Repo-specific notes\n- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  run watch --once
  assert_output --partial "claimed 1, in flight 1/1"
  assert_equal "$(labels_of PROJ-2)" "ai-auto"
}

@test "a dispatched worktree keeps its ticket in flight; its removal frees the slot" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  dispatch PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 dispatched"
  assert_output --partial "claimed 0, in flight 1/1"
  assert_equal "$(grep '^RUNS=' "$LEDGER/PROJ-1")" "RUNS=1"
  finish PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 run ended"
  assert_output --partial "ticket-filed PROJ-2"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-2 "
}

@test "a bounced ticket (needs-info) is released and frees its slot" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  set_labels PROJ-1 "ai-auto:claimed,ai-auto:needs-info"
  run watch --once
  assert_output --partial "PROJ-1 released (bounced, ai-auto:needs-info)"
  assert_output --partial "ticket-filed PROJ-2"
  assert_equal "$(runs_of PROJ-1)" ""
}

# The slot leak (#335 review): a worker that starts and finishes between two
# polls is never seen with a worktree, so its entry stays pending.
@test "a pending ticket whose status is done frees its slot and counts as a run" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  set_done PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 released (status done)"
  assert_output --partial "ticket-filed PROJ-2"
  assert_equal "$(runs_of PROJ-1)" 1
}

@test "a pending ticket labelled failed by hand frees its slot" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  set_labels PROJ-1 "ai-auto:claimed,ai-auto:failed"
  run watch --once
  assert_output --partial "PROJ-1 released (ai-auto:failed)"
  assert_output --partial "ticket-filed PROJ-2"
}

@test "a pending ticket that lost its claimed label frees its slot" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  set_labels PROJ-1 "triaged-by-hand"
  run watch --once
  assert_output --partial "PROJ-1 released (ai-auto:claimed removed)"
  assert_output --partial "ticket-filed PROJ-2"
}

@test "a deleted pending ticket frees its slot instead of stopping the watcher" {
  printf -- '- **Watch max in flight**: `1`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  watch --once >/dev/null
  delete_issue PROJ-1
  run watch --once
  assert_success
  assert_output --partial "PROJ-1 released"
  assert_output --partial "ticket-filed PROJ-2"
  # Searched by the claimed label: `key in (<deleted>)` exits 1 on real Jira.
  run grep -c 'key in' "$STUB_CALLS_DIR/acli.calls"
  assert_output 0
}

@test "pending timeout: released, counted as a failed run, logged, and back in the queue" {
  issue PROJ-1 ai-auto
  watch --once >/dev/null
  run watch --once
  assert_output --partial "in flight 1/2"
  age_pending PROJ-1
  run watch --once
  assert_success
  assert_output --partial "PROJ-1 pending past 120m"
  assert_output --partial "back in the queue"
  assert_equal "$(runs_of PROJ-1)" 1
  run grep 'watch: pending timeout PROJ-1' "$TASK_FORCE_HOME/radio/log"
  assert_success
  # Re-queued, so the same poll claims it again for another try.
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
}

@test "pending timeouts count toward the failure cap" {
  printf -- '- **Watch pending timeout minutes**: `30`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto
  watch --once >/dev/null
  age_pending PROJ-1
  watch --once >/dev/null
  age_pending PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 pending past 30m"
  assert_output --partial "failed run 2 of 2, labelled ai-auto:failed"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:failed"
  run watch --once
  assert_output --partial "claimed 0, in flight 0/2"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
}

@test "failure cap: a ticket back in the queue after N dispatched runs is labelled failed, not claimed" {
  issue PROJ-1 ai-auto
  local run_no
  for run_no in 1 2; do
    watch --once >/dev/null
    dispatch PROJ-1; watch --once >/dev/null
    finish PROJ-1;   watch --once >/dev/null
    set_labels PROJ-1 ai-auto   # the run failed: re-queued
  done
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
  run watch --once
  assert_success
  assert_output --partial "labelled ai-auto:failed"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:failed"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
  # Never re-claimed, even with the label put back by hand.
  set_labels PROJ-1 "ai-auto,ai-auto:failed"
  run watch --once
  assert_output --partial "claimed 0"
  assert_equal "$(labels_of PROJ-1)" "ai-auto,ai-auto:failed"
}

@test "a bounce does not count toward the failure cap" {
  issue PROJ-1 ai-auto
  local i
  for i in 1 2 3; do
    watch --once >/dev/null
    set_labels PROJ-1 "ai-auto:claimed,ai-auto:needs-info"; watch --once >/dev/null
    set_labels PROJ-1 ai-auto   # the reporter added the info and re-queued it
  done
  run watch --once
  assert_output --partial "ticket-filed PROJ-1"
  assert_equal "$(pinged | wc -l | tr -d ' ')" 4
}

@test "requeue: a reporter's comment after the bounce puts the ticket back and it is claimed again" {
  issue PROJ-1 ai-auto
  set_description PROJ-1 "crashes"
  comment PROJ-1 acct:reporter -7200   # before the bounce: not a reply
  claim_and_bounce PROJ-1
  assert_equal "$(state_of PROJ-1)" bounced
  comment PROJ-1 acct:reporter 60
  run watch --once
  assert_success
  assert_output --partial "requeued PROJ-1 (reporter replied)"
  # One edit: the label back, claimed and needs-info off.
  assert_stub_called acli 'edit --key PROJ-1 --labels ai-auto --remove-labels ai-auto:claimed,ai-auto:needs-info --yes --json'
  run grep 'watch: requeued PROJ-1 (reporter replied)' "$TASK_FORCE_HOME/radio/log"
  assert_success
  # The same poll's queue search claims it, and the PM is pinged again.
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
  # A requeue is not a failed run.
  assert_equal "$(runs_of PROJ-1)" ""
}

@test "requeue: a reply stamped with milliseconds and a non-UTC offset is read in UTC" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  # Written an hour ago in -0700: before the bounce, not a reply.
  comment PROJ-1 acct:reporter -3600 -7
  run watch --once
  refute_output --partial "requeued"
  run jq -r '.[0].fields.comment.comments[0].created' "$ACLI_STUB_ISSUES"
  assert_output --regexp '^[0-9-]{10}T[0-9:]{8}\.665-0700$'
  # A minute from now in -0700: a reply.
  comment PROJ-1 acct:reporter 60 -7
  run watch --once
  assert_output --partial "requeued PROJ-1 (reporter replied)"
}

@test "requeue: a reply between the PM's bounce comment and the next poll still counts" {
  issue PROJ-1 ai-auto
  watch --once >/dev/null
  age_pending PROJ-1                  # claimed long before the bounce
  set_labels PROJ-1 "ai-auto:claimed,ai-auto:needs-info"
  comment PROJ-1 acct:pm-self -120    # the bounce comment
  comment PROJ-1 acct:reporter -60    # answered before the watcher looked
  watch --once >/dev/null             # sees the bounce
  run watch --once
  assert_output --partial "requeued PROJ-1 (reporter replied)"
}

@test "requeue: an own comment from before the claim is not the baseline" {
  issue PROJ-1 ai-auto
  comment PROJ-1 acct:pm-self -7200
  comment PROJ-1 acct:reporter -3600
  claim_and_bounce PROJ-1
  run watch --once
  refute_output --partial "requeued"
}

@test "requeue: a bounced ticket closed as done is released, not left bounced" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  set_done PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 no longer bounced (status done)"
  assert_equal "$(state_of PROJ-1)" released
}

@test "requeue: a comment by the PM's own acli account is not a reply" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  comment PROJ-1 acct:pm-self 60
  run watch --once
  assert_success
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed,ai-auto:needs-info"
  assert_equal "$(state_of PROJ-1)" bounced
}

@test "requeue: no reply, no requeue" {
  issue PROJ-1 ai-auto
  set_description PROJ-1 "crashes"
  comment PROJ-1 acct:reporter -7200
  claim_and_bounce PROJ-1
  run watch --once
  assert_success
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed,ai-auto:needs-info"
  assert_equal "$(pinged)" "PROJ-1"
}

@test "requeue: a description edited after the bounce is a reply" {
  issue PROJ-1 ai-auto
  set_description PROJ-1 "crashes"
  claim_and_bounce PROJ-1
  set_description PROJ-1 "crashes on save with an empty title; expected a validation message"
  run watch --once
  assert_success
  assert_output --partial "requeued PROJ-1 (description edited)"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
}

@test "requeue: the half-done swap (needs-info off, claimed left on) is requeued" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  set_labels PROJ-1 "ai-auto:claimed"
  run watch --once
  assert_success
  assert_output --partial "requeued PROJ-1 (ai-auto:needs-info removed)"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
  assert_equal "$(pinged | tr '\n' ' ')" "PROJ-1 PROJ-1 "
}

@test "requeue: a half-done swap with a live worktree is a dispatch, not a retry" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  set_labels PROJ-1 "ai-auto:claimed"
  dispatch PROJ-1
  run watch --once
  assert_output --partial "PROJ-1 dispatched"
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
}

@test "requeue: a bounce from before the watcher looked is adopted, then requeued on a reply" {
  issue PROJ-1 ai-auto:claimed ai-auto:needs-info
  run watch --once
  assert_output --partial "PROJ-1 released (bounced, ai-auto:needs-info)"
  comment PROJ-1 acct:reporter 60
  run watch --once
  assert_output --partial "requeued PROJ-1 (reporter replied)"
}

@test "requeue: the bounce cap leaves the ticket on needs-info" {
  printf -- '- **Watch bounce cap**: `2`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  comment PROJ-1 acct:reporter 60
  watch --once >/dev/null   # requeued and claimed again
  set_labels PROJ-1 "ai-auto:claimed,ai-auto:needs-info"
  run watch --once
  assert_output --partial "bounce 2 of 2: the cap, left on ai-auto:needs-info"
  comment PROJ-1 acct:reporter 120
  set_description PROJ-1 "more detail"
  run watch --once
  assert_success
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed,ai-auto:needs-info"
  # Nor does the half-done swap get past it.
  set_labels PROJ-1 "ai-auto:claimed"
  run watch --once
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed"
}

@test "requeue: a failed requeue edit changes no state" {
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  comment PROJ-1 acct:reporter 60
  cp "$LEDGER/PROJ-1" "$BATS_TEST_TMPDIR/ledger.before"
  ACLI_STUB_EDIT_FAIL=PROJ-1 run watch --once
  assert_success
  assert_output --partial "label swap on PROJ-1"
  refute_output --partial "requeued"
  assert_equal "$(labels_of PROJ-1)" "ai-auto:claimed,ai-auto:needs-info"
  run diff "$BATS_TEST_TMPDIR/ledger.before" "$LEDGER/PROJ-1"
  assert_success
  # The next poll tries again.
  run watch --once
  assert_output --partial "requeued PROJ-1 (reporter replied)"
}

@test "requeue: with no acli account on file, comments are not trusted but a description edit still requeues" {
  rm "$TASK_WATCH_ACLI_CONFIG"
  issue PROJ-1 ai-auto
  claim_and_bounce PROJ-1
  comment PROJ-1 acct:pm-self 60
  run watch --once
  refute_output --partial "requeued"
  assert_output --partial "cannot tell the reporter's comments from the PM's"
  set_description PROJ-1 "now with steps"
  run watch --once
  assert_output --partial "requeued PROJ-1 (description edited)"
}

@test "a failed claim (acli exits 0, successCount 0) is never followed by a ping" {
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  ACLI_STUB_EDIT_FAIL=PROJ-1 run watch --once
  assert_success
  assert_output --partial "label swap on PROJ-1"
  assert_equal "$(pinged)" "PROJ-2"
  # Only its parent is cached (#351): no claim recorded.
  run grep '^STATE=' "$LEDGER/PROJ-1"
  assert_failure
}

@test "a failed acli read stops the watcher, radios watch-stopped, and claims nothing" {
  issue PROJ-1 ai-auto
  ACLI_STUB_SEARCH_EXIT=1 run watch --once
  assert_failure 3
  assert_output --partial "acli jira auth login --web"
  assert_equal "$(edits)" 0
  run grep -l '^intent: watch-stopped$' "$PM_INBOX"/*.md
  assert_success
  run grep 'watch: stopped' "$TASK_FORCE_HOME/radio/log"
  assert_success
}

@test "a non-auth acli error stops the watcher with acli's error, not a re-login (#351)" {
  issue PROJ-1 ai-auto
  ACLI_STUB_SEARCH_ERROR="field 'parent' is not allowed" run watch --once
  assert_failure 3
  assert_output --partial "acli error: ✗ Error: field 'parent' is not allowed"
  refute_output --partial "re-login"
  assert_equal "$(edits)" 0
  f=$(grep -l '^intent: watch-stopped$' "$PM_INBOX"/*.md)
  run cat "$f"
  assert_output --partial "acli error: ✗ Error: field 'parent' is not allowed"
  refute_output --partial "auth login"
}

@test "an acli error with a failing auth status is blamed on the login (#351)" {
  issue PROJ-1 ai-auto
  ACLI_STUB_SEARCH_ERROR="something odd" ACLI_STUB_AUTH_STATUS_EXIT=1 run watch --once
  assert_failure 3
  assert_output --partial "re-login with: acli jira auth login --web"
  f=$(grep -l '^intent: watch-stopped$' "$PM_INBOX"/*.md)
  run cat "$f"
  assert_output --partial "acli jira auth login --web"
}

@test "the search asks acli only for fields its search accepts (#351)" {
  issue PROJ-1 ai-auto
  run watch --once
  assert_success
  assert_output --partial "claimed 1"
  run grep 'workitem search' "$STUB_CALLS_DIR/acli.calls"
  assert_success
  refute_output --regexp '--fields [^ ]*(parent|updated|created)'
}

@test "a non-zero acli write exit stops the watcher too" {
  issue PROJ-1 ai-auto
  ACLI_STUB_EDIT_EXIT=1 run watch --once
  assert_failure 3
  assert_equal "$(pinged)" ""
}

@test "a custom JQL that forgets the claimed label still never re-claims" {
  printf -- '- **Watch JQL**: `labels = "ai-auto"`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  issue PROJ-1 ai-auto ai-auto:claimed
  run watch --once
  assert_output --partial "claimed 0"
  assert_equal "$(edits)" 0
}

@test "the ticket-filed message surfaces in the PM's prompt-hook summary with its Jira key" {
  issue PROJ-12 ai-auto
  watch --once >/dev/null
  run bash -c "echo '{}' | TASK_FORCE_ROLE=pm-$NAME '$RADIO' prompt-hook"
  assert_success
  assert_output --partial "from=watch-$NAME intent=ticket-filed issue=PROJ-12"
}

@test "local-only install: runs from a worktree off the untracked doc in the main checkout" {
  git -C "$MAIN_REPO" config task-force.install local-only
  printf '/.claude/jira-workflow.md\n' >>"$MAIN_REPO/.git/info/exclude"
  assert_equal "$(git -C "$MAIN_REPO" status --porcelain)" ""
  git -C "$MAIN_REPO" worktree add -q "$BATS_TEST_TMPDIR/wt" -b side
  issue PROJ-1 ai-auto
  cd "$BATS_TEST_TMPDIR/wt"
  run watch --once
  assert_success
  assert_output --partial "ticket-filed PROJ-1"
}

@test "the shipped template's settings bullets parse, and task-init keeps an override below the end marker" {
  rm "$MAIN_REPO/.claude/jira-workflow.md" "$ACLI_STUB_ISSUES"
  echo '[]' >"$ACLI_STUB_ISSUES"
  bash "$JIRA_TASK_INIT" --site https://acme.atlassian.net --key PROJ --board B --workflow --force </dev/null >/dev/null
  printf -- '- **Watch label**: `bot-fix`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  bash "$JIRA_TASK_INIT" --workflow --force </dev/null >/dev/null
  issue PROJ-1 bot-fix
  run watch --once
  assert_success
  assert_output --partial "in flight 1/2"
  assert_stub_called acli 'project = "PROJ" AND issuetype = "Bug" AND labels = "bot-fix" AND labels not in ("bot-fix:claimed", "bot-fix:failed") ORDER BY created ASC'
}

@test "refuses outside a claude-jira repo" {
  rm "$MAIN_REPO/.claude/jira-workflow.md"
  run watch --once
  assert_failure
  assert_output --partial "claude-jira only"
}

@test "one watcher per repo: a live lock refuses a second" {
  mkdir -p "$LEDGER/.lock"
  echo $$ >"$LEDGER/.lock/pid"
  run watch --once
  assert_failure
  assert_output --partial "already running"
  # A stale lock (dead pid) is taken over.
  echo 999999 >"$LEDGER/.lock/pid"
  run watch --once
  assert_success
}
