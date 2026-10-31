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
    '. + [{key: $k, fields: {labels: $l, summary: ("summary of " + $k), status: {name: "To Do"}}}]' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}

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
  assert_output --partial "PROJ-1 released"
  assert_output --partial "ticket-filed PROJ-2"
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

@test "a failed claim (acli exits 0, successCount 0) is never followed by a ping" {
  issue PROJ-1 ai-auto; issue PROJ-2 ai-auto
  ACLI_STUB_EDIT_FAIL=PROJ-1 run watch --once
  assert_success
  assert_output --partial "label swap on PROJ-1"
  assert_equal "$(pinged)" "PROJ-2"
  assert [ ! -e "$LEDGER/PROJ-1" ]
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
