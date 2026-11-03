#!/usr/bin/env bats
# bin/task-merge-gate (#329): the PM merges an auto ticket's PR by itself only
# with the opt-in label, a clean review, CI that ran and passed for the head
# SHA, and a small diff. Jira is the acli stub playing a JSON file, GitHub the
# gh stub, the review the radio messages on disk. Scratch repo and home, under
# /bin/bash.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

bats_require_minimum_version 1.5.0

GATE="$REPO_ROOT_REAL/bin/task-merge-gate"
SHA=0123456789abcdef0123456789abcdef01234567

setup() {
  setup_repo
  setup_task_force_home
  setup_stubs
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  mkdir -p "$MAIN_REPO/.claude"
  cat >"$MAIN_REPO/.claude/jira-workflow.md" <<'DOC'
<!-- task-init:managed:start -->
- **Site**: `https://acme.atlassian.net`
- **Project key(s)**: `PROJ`
- **Watch label**: `ai-auto`
- **Merge label**: `ai-auto-merge`
- **Merge max changed lines**: `200`
- **Merge max files**: `10`
<!-- task-init:managed:end -->
DOC
  export ACLI_STUB_ISSUES="$BATS_TEST_TMPDIR/issues.json"
  echo '[]' >"$ACLI_STUB_ISSUES"
  # The all-green baseline: each test breaks one thing.
  issue PROJ-1 ai-auto:claimed ai-auto-merge
  pr_json 40 2 3
  export GH_STUB_RUNS_JSON='[{"name":"ci","status":"completed","conclusion":"success"},{"name":"docs","status":"completed","conclusion":"skipped"}]'
  msg "worker-$NAME-proj-1" review-requested 2026-11-03T10:00:00Z
  msg "reviewer-$NAME-pr7" review-complete-clean 2026-11-03T10:20:00Z processed
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

gate() { /bin/bash "$GATE" "$@"; }

# issue <key> <label>...
issue() {
  local key="$1"; shift
  local labels
  labels=$(printf '%s\n' "$@" | jq -R . | jq -s -c 'map(select(. != ""))')
  jq --arg k "$key" --argjson l "$labels" '. + [{key: $k, fields: {labels: $l}}]' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
set_labels() {
  jq --arg k "$1" --arg l "$2" 'map(if .key == $k then .fields.labels = ($l | split(",") | map(select(. != ""))) else . end)' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}

# pr_json <additions> <deletions> <files> [state]
pr_json() {
  export GH_STUB_PR_JSON="{\"headRefOid\":\"$SHA\",\"additions\":$1,\"deletions\":$2,\"changedFiles\":$3,\"state\":\"${4:-OPEN}\",\"url\":\"https://github.com/o/r/pull/7\"}"
}

# msg <from> <intent> <created_at> [inbox|processed] [pr] — a radio message on disk.
msg() {
  local dir="$TASK_FORCE_HOME/radio/mailbox/pm-$NAME/${4:-inbox}" id
  id="$(printf '%s' "$3" | tr -d ':-')-from-$1-$RANDOM"
  mkdir -p "$dir"
  printf -- '---\nid: %s\nfrom: %s\nto: pm-%s\nintent: %s\npr: %s\ncreated_at: %s\n---\nbody\n' \
    "$id" "$1" "$NAME" "$2" "${5:-7}" "$3" >"$dir/$id.md"
}

comments() { cat "$STUB_CALLS_DIR/acli.comments" 2>/dev/null || true; }

@test "all four rules hold: merge, exit 0, and the outcome is commented on the ticket" {
  run gate 7 PROJ-1
  assert_success
  assert_output "merge"
  assert_stub_called gh "run list -c $SHA"
  run comments
  assert_output --partial "PROJ-1: task-merge-gate on PR #7 (https://github.com/o/r/pull/7): merge"
  run grep 'merge-gate: pr=7 key=PROJ-1' "$TASK_FORCE_HOME/radio/log"
  assert_success
}

@test "a PR URL and a browse URL work as arguments" {
  run gate https://github.com/o/r/pull/7 https://acme.atlassian.net/browse/proj-1 --no-comment
  assert_success
  assert_output "merge"
  assert_equal "$(comments)" ""
}

# The #329 addendum: the first end-to-end run merged an auto ticket without the
# opt-in. A clean review on an auto ticket without the label is ask:, never merge.
@test "rule 1: a clean review on an auto ticket without the opt-in label asks, never merges" {
  set_labels PROJ-1 "ai-auto:claimed"
  run gate 7 PROJ-1
  assert_failure 1
  assert_output "ask: PROJ-1 has no ai-auto-merge label (merging an auto ticket is opt-in)"
  refute_output --regexp '^merge$'
  run comments
  assert_output --partial "PROJ-1: task-merge-gate on PR #7 (https://github.com/o/r/pull/7): ask: PROJ-1 has no ai-auto-merge label"
}

@test "rule 1: the merge label is configurable" {
  printf '\n## Repo-specific notes\n- **Merge label**: `bot-merge`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "no bot-merge label"
  set_labels PROJ-1 "ai-auto:claimed,bot-merge"
  run gate 7 PROJ-1 --no-comment
  assert_success
}

@test "rule 2: a review with findings asks" {
  msg "reviewer-$NAME-pr7" review-complete-with-findings 2026-11-03T10:30:00Z
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: the latest review of PR #7 has findings"
}

@test "rule 2: no review on record asks" {
  rm -rf "$TASK_FORCE_HOME/radio/mailbox"
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: no review-complete-clean from reviewer-$NAME-pr7 on record"
}

@test "rule 2: a re-review request newer than the clean verdict asks" {
  msg "worker-$NAME-proj-1" re-review-requested 2026-11-03T11:00:00Z
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "PR #7 has changed since its last review"
}

@test "rule 2: a clean verdict for another PR, or from a role that is not its reviewer, does not count" {
  rm -rf "$TASK_FORCE_HOME/radio/mailbox"
  msg "reviewer-$NAME-pr8" review-complete-clean 2026-11-03T10:20:00Z inbox 8
  msg "worker-$NAME-proj-1" review-complete-clean 2026-11-03T10:21:00Z
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "no review-complete-clean from reviewer-$NAME-pr7"
}

@test "rule 3: no CI run for the head SHA asks (an empty list is not a pass)" {
  export GH_STUB_RUNS_JSON='[]'
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: no CI run exists for head 0123456789ab — an empty check list is not a pass"
}

@test "rule 3: a failed run asks, and names it" {
  export GH_STUB_RUNS_JSON='[{"name":"ci","status":"completed","conclusion":"failure"}]'
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: CI did not pass for 0123456789ab: ci (failure)"
}

@test "rule 3: a run still in progress asks" {
  export GH_STUB_RUNS_JSON='[{"name":"ci","status":"in_progress","conclusion":""}]'
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: CI is still running for 0123456789ab: ci"
}

@test "rule 3: gh failing to list runs asks" {
  export GH_STUB_RUNS_EXIT=1
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "ask: could not list CI runs"
}

@test "rule 4: over the line cap asks" {
  pr_json 150 51 3
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: the diff changes 201 lines, over the 200-line cap"
}

@test "rule 4: over the file cap asks" {
  pr_json 10 0 11
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: the diff touches 11 files, over the 10-file cap"
}

@test "rule 4: the caps are configurable, and exactly at the cap passes" {
  printf -- '- **Merge max changed lines**: `20`\n- **Merge max files**: `2`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  pr_json 15 5 2
  run gate 7 PROJ-1 --no-comment
  assert_success
  pr_json 15 6 3
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: the diff changes 21 lines, over the 20-line cap; the diff touches 3 files, over the 2-file cap"
}

@test "every failing rule is listed" {
  set_labels PROJ-1 "ai-auto:claimed"
  export GH_STUB_RUNS_JSON='[]'
  pr_json 300 0 3
  msg "reviewer-$NAME-pr7" review-complete-with-findings 2026-11-03T10:30:00Z
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "no ai-auto-merge label"
  assert_output --partial "300 lines"
  assert_output --partial "has findings"
  assert_output --partial "no CI run exists"
}

@test "a PR that is not open asks" {
  pr_json 1 1 1 MERGED
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output "ask: PR #7 is MERGED, not open"
}

@test "gh failing to read the PR asks" {
  unset GH_STUB_PR_JSON
  run gate 7 PROJ-1 --no-comment
  assert_failure 1
  assert_output --partial "ask: could not read PR #7 through gh"
}

@test "acli failing to read the ticket asks, never manual, and comments nothing" {
  export ACLI_STUB_VIEW_EXIT=1
  run gate 7 PROJ-1
  assert_failure 1
  assert_output --partial "ask: could not read PROJ-1's labels through acli (exit 1"
  assert_equal "$(comments)" ""
}

@test "manual: a ticket task-watch never claimed gets the base flow, exit 3, no comment" {
  issue PROJ-2 ai-auto-merge
  run gate 7 PROJ-2
  assert_failure 3
  assert_output "manual: PROJ-2 did not come through task-watch (no ai-auto:claimed label, no watch ledger entry)"
  assert_equal "$(comments)" ""
}

@test "an auto ticket that lost its claimed label is still auto through the watch ledger" {
  issue PROJ-3
  mkdir -p "$TASK_FORCE_HOME/watch/$NAME"
  printf 'STATE=running\n' >"$TASK_FORCE_HOME/watch/$NAME/PROJ-3"
  run gate 7 PROJ-3 --no-comment
  assert_failure 1
  assert_output --partial "ask: PROJ-3 has no ai-auto-merge label"
}

@test "the claimed label follows the watch label setting" {
  printf -- '- **Watch label**: `bot`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  run gate 7 PROJ-1 --no-comment
  assert_failure 3
  issue PROJ-4 bot:claimed ai-auto-merge
  run gate 7 PROJ-4 --no-comment
  assert_success
}

@test "a failed comment warns on stderr and does not change the verdict" {
  export ACLI_STUB_COMMENT_FAIL=1
  run --separate-stderr gate 7 PROJ-1
  assert_success
  assert_output "merge"
  [[ "$stderr" == *"warning: could not comment on PROJ-1"* ]]
}

@test "the shipped template's merge bullets parse to the documented defaults" {
  cp "$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md" "$MAIN_REPO/.claude/jira-workflow.md"
  run grep -E '^- \*\*(Merge label|Merge max changed lines|Merge max files)\*\*' "$MAIN_REPO/.claude/jira-workflow.md"
  assert_line '- **Merge label**: `ai-auto-merge`'
  assert_line '- **Merge max changed lines**: `200`'
  assert_line '- **Merge max files**: `10`'
  run gate 7 PROJ-1 --no-comment
  assert_success
}

@test "a non-numeric cap is a usage error, not a merge" {
  printf -- '- **Merge max files**: `lots`\n' >>"$MAIN_REPO/.claude/jira-workflow.md"
  run gate 7 PROJ-1
  assert_failure 2
  refute_output --regexp '^merge$'
}

@test "refuses outside a claude-jira repo, and on bad arguments" {
  rm "$MAIN_REPO/.claude/jira-workflow.md"
  run gate 7 PROJ-1
  assert_failure 2
  assert_output --partial "claude-jira only"
  run gate 7
  assert_failure 2
  run gate abc PROJ-1
  assert_failure 2
}

@test "the claude-jira PM prompt runs the gate after a clean review and overrides proceed-to-merge for auto tickets" {
  run grep -c 'task-merge-gate' "$REPO_ROOT_REAL/claude-jira/commands/pm.md"
  assert_success
  run grep -F 'does not apply' "$REPO_ROOT_REAL/claude-jira/commands/pm.md"
  assert_success
}
