#!/usr/bin/env bats
# bin/task-monitor-queue (#275): the PM's short-term queue, the "Next" section of
# task-monitor. Every test runs against a scratch repo and a scratch
# $TASK_FORCE_HOME, and under /bin/bash, which is 3.2 on macOS.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

NEXT="$REPO_ROOT_REAL/bin/task-monitor-queue"
SNAP="$REPO_ROOT_REAL/bin/task-monitor-snapshot"

setup() {
  setup_repo
  setup_task_force_home
  unset TASK_FORCE_ROLE
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  QUEUE="$TASK_FORCE_HOME/monitor/$NAME/queue"
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

nx() { /bin/bash "$NEXT" "$@"; }

# The queue file with tabs made visible.
queue_file() { sed 's/\t/<TAB>/' "$QUEUE"; }

@test "show: an empty queue says so and writes nothing" {
  run nx
  assert_success
  assert_output "queue: (empty)"
  assert [ ! -e "$TASK_FORCE_HOME/monitor" ]
}

@test "set: writes refs in order, one per line, notes after a tab, and answers with one line" {
  run nx set 267 '#266' 180 --note 267='kiro hooks first'
  assert_success
  assert_output "queue: 267 266 180"
  run queue_file
  assert_output "$(printf '267<TAB>kiro hooks first\n266\n180')"
}

@test "show: numbered, with notes" {
  nx set 8 5 --note 5='after the release' >/dev/null
  run nx show
  assert_success
  assert_output "$(printf '1  8\n2  5  after the release')"
}

@test "set: replaces the queue, keeps a surviving ref's note, an empty --note clears it" {
  nx set 1 2 3 --note 2=two --note 3=three >/dev/null
  run nx set 3 2
  assert_output "queue: 3 2"
  run queue_file
  assert_output "$(printf '3<TAB>three\n2<TAB>two')"
  nx set 3 2 --note 3= >/dev/null
  run queue_file
  assert_output "$(printf '3\n2<TAB>two')"
}

@test "set: a ref given twice, in any spelling, is queued once" {
  run nx set 7 '#7' https://github.com/acme/widgets/issues/7 9
  assert_output "queue: 7 9"
}

@test "add: appends new refs; a queued one keeps its place and only takes the note" {
  nx set 1 2 >/dev/null
  run nx add 3 '#1' --note 1='first, still'
  assert_success
  assert_output "queue: 1 2 3"
  run queue_file
  assert_output "$(printf '1<TAB>first, still\n2\n3')"
}

@test "add: onto an empty queue creates the file" {
  run nx add PROJ-42
  assert_success
  assert_output "queue: PROJ-42"
  assert [ -f "$QUEUE" ]
}

@test "rm: drops by key, so a URL removes a bare number; unknown refs are ignored" {
  nx set 267 266 180 >/dev/null
  run nx rm https://github.com/acme/widgets/issues/267/ nope
  assert_success
  assert_output "queue: 266 180"
}

@test "rm: a task file path matches the file name it was queued by" {
  nx set 012-fix-it.md 013-other.md >/dev/null
  run nx rm /abs/repo/tasks/012-fix-it.md
  assert_output "queue: 013-other.md"
}

@test "rm --quiet prints nothing; emptying the queue removes the file" {
  nx set 5 >/dev/null
  run nx rm --quiet 5
  assert_success
  assert_output ""
  assert [ ! -e "$QUEUE" ]
}

@test "rm: with no queue file at all, creates nothing" {
  run nx rm 5
  assert_success
  assert_output "queue: (empty)"
  assert [ ! -e "$TASK_FORCE_HOME/monitor" ]
}

@test "clear: empties the queue and removes the file" {
  nx set 1 2 >/dev/null
  run nx clear
  assert_success
  assert_output "queue: (empty)"
  assert [ ! -e "$QUEUE" ]
}

@test "a note is one line: tabs and newlines become spaces" {
  nx set 4 --note "4=$(printf 'a\tb\nc')" >/dev/null
  run queue_file
  assert_output "4<TAB>a b c"
}

@test "refused: a ref with whitespace, a note for an unqueued ref, refs on clear, nothing on set" {
  run nx set 'a b'
  assert_failure 2
  assert_output --partial "cannot contain whitespace"
  run nx set 1 --note 9=x
  assert_failure 2
  assert_output --partial "9, which is not in the queue"
  run nx clear 1
  assert_failure 2
  run nx set
  assert_failure 2
  run nx rm 1 --note 1=x
  assert_failure 2
  assert [ ! -e "$QUEUE" ]
}

@test "refused: outside a git repo" {
  local d
  d=$(mktemp -d)
  run nx --repo "$d"
  rm -rf "$d"
  assert_failure 1
  assert_output --partial "not in a git repo"
}

@test "from a linked worktree, it writes the main repo's queue" {
  setup_worktree wt-a
  cd "$WORKTREE_BASE/wt-a"
  nx set 11 >/dev/null
  run cat "$QUEUE"
  assert_output "11"
}

@test "--repo names the repo from anywhere" {
  cd /
  nx set 3 --repo "$MAIN_REPO" >/dev/null
  run cat "$QUEUE"
  assert_output "3"
}

@test "the snapshot reads what this command writes, in order, with notes" {
  mkdir -p .claude
  touch .claude/notion-workflow.md
  nx set PROJ-2 PROJ-1 --note PROJ-1='after the release' >/dev/null
  run /bin/bash "$SNAP" --local
  assert_success
  assert_equal "$(jq -r '.repos[0].next.source' <<<"$output")" queue
  assert_equal "$(jq -r '[.repos[0].next.items[].ref] | join(" ")' <<<"$output")" "PROJ-2 PROJ-1"
  assert_equal "$(jq -r '.repos[0].next.items[1].note' <<<"$output")" "after the release"
}

@test "task-work takes the ref it dispatches off the queue, whatever form it was queued in" {
  setup_stubs
  export AW_IMPL=claude-gh
  nx set 41 42 43 --note 43=later >/dev/null
  run "$TASK_WORK" "https://github.com/owner/repo/issues/42"
  assert_success
  run queue_file
  assert_output "$(printf '41\n43<TAB>later')"
}

@test "task-work with no ref leaves the queue alone" {
  setup_stubs
  export AW_IMPL=claude-gh
  nx set 41 >/dev/null
  run "$TASK_WORK" "41"
  assert_success
  run cat "$QUEUE"
  assert_output "41"
}

@test "every PM prompt teaches task-monitor-queue set, and that task-work drops what it dispatches" {
  local f
  for f in "$REPO_ROOT_REAL"/claude-*/commands/pm.md "$REPO_ROOT_REAL"/.claude/commands/pm.md; do
    run grep -c 'task-monitor-queue set .*`task-work` takes it off the queue itself' "$f"
    assert_output 1
  done
  for f in "$REPO_ROOT_REAL"/kiro-*/agents/pm.json; do
    run jq -r '.prompt | test("task-monitor-queue set .*`task-work` takes it off the queue itself")' "$f"
    assert_output true
  done
}

@test "a ref's leading #s are all stripped, so ##5 is stored as 5 and not read back as a comment" {
  run nx set '##5' 6
  assert_output "queue: 5 6"
  run nx show
  assert_output "$(printf '1  5\n2  6')"
  run nx set '##'
  assert_failure 2
  assert_output --partial "empty ref"
}

@test "-- ends the options, so a ref may start with -" {
  run nx add -- -9 10
  assert_success
  assert_output "queue: -9 10"
  run nx rm -- -9
  assert_output "queue: 10"
}

@test "a URL's query string and fragment do not change its key" {
  nx set 'https://www.notion.so/acme/Fix-auth-abc123?pvs=4' 7 >/dev/null
  run nx rm 'https://www.notion.so/acme/Fix-auth-abc123'
  assert_output "queue: 7"
  nx set 'https://www.notion.so/acme/Fix-auth-abc123' 7 >/dev/null
  run nx add 'https://www.notion.so/acme/Fix-auth-abc123#section' 'https://github.com/acme/widgets/issues/7?x=1'
  assert_output "queue: https://www.notion.so/acme/Fix-auth-abc123 7"
}
