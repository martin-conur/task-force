#!/usr/bin/env bats
# bin/task-monitor-snapshot (#273): the JSON data layer of task-monitor.
#
# Every source and every signal gets its own test, against a scratch repo, a
# scratch $TASK_FORCE_HOME and a `gh` stub that serves fixture files — so nothing
# here reads the real radio state or the real forge. Each test runs the binary
# under /bin/bash, which is 3.2 on macOS: the snapshot must work there (#266).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

SNAP="$REPO_ROOT_REAL/bin/task-monitor-snapshot"

setup() {
  setup_repo
  setup_task_force_home
  STUB_BIN=$(mktemp -d)
  STUB_CALLS_DIR=$(mktemp -d)
  GH_FIX=$(mktemp -d)
  export STUB_BIN STUB_CALLS_DIR GH_FIX
  # The gh stub: each call is answered from a fixture file, or fails when the
  # file is absent — which is how a test says "the forge did not answer".
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_CALLS_DIR/gh.calls"
_serve() { [[ -f "$GH_FIX/$1" ]] || exit 1; cat "$GH_FIX/$1"; exit 0; }
case "$1 $2" in
  "issue view") n="${3##*/}"; _serve "issue-$n.json" ;;
  "pr view")    _serve "pr-$3.json" ;;
  "pr list")
    case "$*" in
      *"--state open"*)   _serve pr-open.json ;;
      *"--state merged"*) _serve pr-merged.json ;;
    esac ;;
  "project item-list") _serve project.json ;;
esac
exit 1
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  unset TASK_FORCE_ROLE
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  SESS="$TASK_FORCE_HOME/radio/sessions"
  MBOX="$TASK_FORCE_HOME/radio/mailbox"
  mkdir -p "$SESS" "$MBOX" "$WORKTREE_BASE"
  echo '[]' > "$GH_FIX/pr-open.json"
  echo '[]' > "$GH_FIX/pr-merged.json"
  loadout gh
}

teardown() {
  rm -rf "$GH_FIX" "${OTHER_REPO:-}" "${OTHER_REPO:+$OTHER_REPO-worktrees}"
  teardown_all
}

# ----- fixtures ---------------------------------------------------------------

# Configure the scratch repo for <tracker> on claude: its workflow doc is the
# detection key, and gh's carries the project and the three statuses.
loadout() {
  rm -rf "$MAIN_REPO/.claude"
  mkdir -p "$MAIN_REPO/.claude"
  if [[ "$1" == gh ]]; then
    cat > "$MAIN_REPO/.claude/gh-workflow.md" <<'DOC'
- **Owner**: `acme`
- **Repo**: `widgets`
- **Project number**: `7`
- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review`
- **Status when done**: `Done`
DOC
  else
    touch "$MAIN_REPO/.claude/$1-workflow.md"
  fi
}

# sidecar <slug> <key> <ref> [extra KEY=VALUE lines...]
sidecar() {
  local slug="$1" key="$2" ref="$3"; shift 3
  { printf 'BASE_BRANCH=main\nSLUG=%s\n%s=%s\nTAB_ID=4\n' "$slug" "$key" "$ref"
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$WORKTREE_BASE/.$slug.info"
}

# session <role> <state> [extra KEY=VALUE lines...]
session() {
  local role="$1" state="$2"; shift 2
  { printf 'ROLE=%s\nTAB=%s\nTAB_ID=4\nZELLIJ_SESSION=zs\nREPO=%s\nREPO_NAME=%s\nSTATE=%s\nLAST_HEARTBEAT=2026-10-20T10:00:00Z\nAGENT=claude\nLOADOUT=claude-gh\n' \
      "$role" "$role" "$MAIN_REPO" "$NAME" "$state"
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$SESS/$role.info"
}

# msg <mailbox-role> <inbox|processed> <seq> <from> <intent> [pr]
# <seq> orders messages: it becomes the created_at second.
msg() {
  local box="$MBOX/$1/$2" id="20261020-1000$(printf '%02d' "$3")-from-$4-x$3"
  mkdir -p "$box"
  { printf -- '---\nid: %s\nfrom: %s\nto: %s\nintent: %s\n' "$id" "$4" "$1" "$5"
    [[ -n "${6:-}" ]] && printf 'pr: %s\n' "$6"
    printf 'created_at: 2026-10-20T10:00:%02dZ\n---\nbody\n' "$3"; } > "$box/$id.md"
}

# ISO time <secs> seconds ago.
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# pr_fixture <n> <head> <body> [merged-secs-ago]
pr_fixture() {
  local merged=null
  [[ -n "${4:-}" ]] && merged="\"$(ago "$4")\""
  jq -n --argjson n "$1" --arg h "$2" --arg b "$3" --argjson m "$merged" '{
    number: $n, title: ("PR title \($n)"), body: $b, url: ("https://github.com/acme/widgets/pull/\($n)"),
    headRefName: $h, isDraft: false, state: (if $m == null then "OPEN" else "MERGED" end),
    mergedAt: $m, mergeCommit: (if $m == null then null else {oid: ("sha\($n)")} end)}'
}

open_prs()   { jq -s . "$@" > "$GH_FIX/pr-open.json"; }
merged_idx() { jq -s 'map({number, mergedAt, headRefName})' "$@" > "$GH_FIX/pr-merged.json"; }

issue() {
  jq -n --argjson n "$1" --arg t "$2" --arg b "$3" \
    '{number: $n, title: $t, body: $b, url: ("https://github.com/acme/widgets/issues/\($n)")}' \
    > "$GH_FIX/issue-$1.json"
}

snap() { run /bin/bash -c 'cd "$1" && shift && /bin/bash "$@"' _ "$MAIN_REPO" "$SNAP" "$@"; }

# jq over the last snapshot's first repo.
q() { jq -r ".repos[0] | $1" <<<"$output"; }

gh_calls() { cat "$STUB_CALLS_DIR/gh.calls" 2>/dev/null || true; }

# ----- the document -------------------------------------------------------------

@test "prints schema 1 with the three sections and the attention block" {
  snap --json
  assert_success
  assert_equal "$(jq -r .schema <<<"$output")" 1
  assert_equal "$(jq -r .mode <<<"$output")" full
  assert_equal "$(q .name)" "$NAME"
  assert_equal "$(q .loadout)" claude-gh
  assert_equal "$(q '[.in_flight, .next.items, .done.items, .attention.signals] | map(type) | join(",")')" "array,array,array,array"
  assert_equal "$(q .attention.active)" false
}

@test "--help exits 0 and names the flags" {
  run /bin/bash "$SNAP" --help
  assert_success
  assert_output --partial "--local"
  assert_output --partial "--all"
}

@test "refuses outside a git repo without --all" {
  local d; d=$(mktemp -d)
  run /bin/bash -c 'cd "$1" && /bin/bash "$2"' _ "$d" "$SNAP"
  rm -rf "$d"
  assert_failure
  assert_output --partial "not in a git repo"
}

# ----- in flight ----------------------------------------------------------------

@test "in flight: a sidecar with no radio session is still in flight" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  snap
  assert_success
  assert_equal "$(q '.in_flight | length')" 1
  assert_equal "$(q '.in_flight[0].slug')" issue-5
  assert_equal "$(q '.in_flight[0].session')" null
  assert_equal "$(q '.in_flight[0].status')" implementing
}

@test "in flight: the worker session's STATE and heartbeat are joined" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  session "worker-$NAME-issue-5" awaiting
  snap
  assert_equal "$(q '.in_flight[0].session.state')" awaiting
  assert_equal "$(q '.in_flight[0].session.since')" 2026-10-20T10:00:00Z
}

@test "in flight gh: issue title and the first prose paragraph of its body" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Fix the widget" $'## Problem\n\nThe widget\nbreaks on Tuesdays.\n\nSecond paragraph.'
  snap
  assert_equal "$(q '.in_flight[0].title')" "Fix the widget"
  assert_equal "$(q '.in_flight[0].description')" "The widget breaks on Tuesdays."
  assert_equal "$(q '.in_flight[0].label')" "#5"
}

@test "in flight local: title and description come from the tasks/ file" {
  loadout local
  mkdir -p "$MAIN_REPO/tasks"
  printf -- '---\nid: 003\ntitle: Add login\nstatus: in-progress\n---\n\n# Add login\n\nUsers can sign in.\n' \
    > "$MAIN_REPO/tasks/003-add-login.md"
  sidecar add-login TASK_FILE "$MAIN_REPO/tasks/003-add-login.md"
  snap
  assert_equal "$(q '.in_flight[0].title')" "Add login"
  assert_equal "$(q '.in_flight[0].description')" "Users can sign in."
  assert_equal "$(q '.in_flight[0].label')" "003"
}

@test "in flight jira: ref and slug before a PR exists, a browse URL shortened to its key" {
  loadout jira
  sidecar kiro-config JIRA_REF https://acme.atlassian.net/browse/PROJ-42
  snap
  assert_equal "$(q '.in_flight[0].title')" "PROJ-42 · kiro-config"
  assert_equal "$(q '.in_flight[0].label')" "PROJ-42"
  assert_equal "$(q '.in_flight[0].description')" null
}

@test "in flight notion: the slug stands alone and the page URL is kept" {
  loadout notion
  sidecar my-task NOTION_URL https://www.notion.so/My-Task-abc123def456abc123def456abc123de
  snap
  assert_equal "$(q '.in_flight[0].title')" "my-task"
  assert_equal "$(q '.in_flight[0].url')" "https://www.notion.so/My-Task-abc123def456abc123def456abc123de"
}

@test "in flight: once a PR exists its title and ## Summary replace the issue's" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Issue title" "Issue body."
  pr_fixture 9 task/issue-5 $'Closes #5\n\n## Summary\n\nThe widget now works\non Tuesdays.\n\n## Test plan\n\nran it' > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  assert_equal "$(q '.in_flight[0].title')" "PR title 9"
  assert_equal "$(q '.in_flight[0].description')" "The widget now works on Tuesdays."
  assert_equal "$(q '.in_flight[0].pr.number')" 9
  assert_equal "$(q '.in_flight[0].status')" pr-open
}

@test "in flight: a PR with no ## Summary falls back to the paragraph after Closes" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  pr_fixture 9 task/issue-5 $'Closes #5\n\nWhat changed, plainly.\n\nMore.' > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  assert_equal "$(q '.in_flight[0].description')" "What changed, plainly."
}

@test "in flight jira: a PR is linked through its task/<slug> head branch" {
  loadout jira
  sidecar proj-42 JIRA_REF PROJ-42
  pr_fixture 3 task/proj-42 $'## Summary\n\nJira work.' > "$BATS_TEST_TMPDIR/p3"
  open_prs "$BATS_TEST_TMPDIR/p3"
  snap
  assert_equal "$(q '.in_flight[0].title')" "PR title 3"
  assert_equal "$(q '.in_flight[0].description')" "Jira work."
}

@test "status: derived from the latest review intent exchanged about the PR" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  local w="worker-$NAME-issue-5"
  msg "pm-$NAME" processed 1 "$w" review-requested 9
  msg "pm-$NAME" processed 2 "reviewer-$NAME-pr9" review-complete-with-findings 9
  snap
  assert_equal "$(q '.in_flight[0].status')" waiting-merge
  msg "$w" processed 3 "pm-$NAME" changes-requested 9
  snap
  assert_equal "$(q '.in_flight[0].status')" changes-requested
  assert_equal "$(q '.in_flight[0].last_intent.intent')" changes-requested
  msg "pm-$NAME" processed 4 "$w" re-review-requested 9
  snap
  assert_equal "$(q '.in_flight[0].status')" re-review
}

@test "reviewers attach to their PR's item instead of being items themselves" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  sidecar review-pr9 GH_URL https://github.com/acme/widgets/pull/9 PR_NUMBER=9 ISSUE_NUMBER=5
  session "reviewer-$NAME-pr9" busy
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  assert_equal "$(q '.in_flight | length')" 1
  assert_equal "$(q '.in_flight[0].reviewers[0].role')" "reviewer-$NAME-pr9"
  assert_equal "$(q '.in_flight[0].reviewers[0].session.state')" busy
  assert_equal "$(q '.in_flight[0].status')" under-review
}

# ----- next -----------------------------------------------------------------------

@test "next: the PM queue, in its order, with notes, minus what is in flight" {
  issue 8 "Eight" "Body eight."
  issue 6 "Six" "Body six."
  issue 5 "Five" "Body five."
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  mkdir -p "$TASK_FORCE_HOME/monitor/$NAME"
  printf '8\tafter the release\n# a comment\n5\n6\n' > "$TASK_FORCE_HOME/monitor/$NAME/queue"
  snap
  assert_equal "$(q .next.source)" queue
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#8 #6"
  assert_equal "$(q '.next.items[0].note')" "after the release"
  assert_equal "$(q '.next.items[0].title')" "Eight"
}

@test "next gh fallback: project items in none of the three statuses, minus in flight and other repos" {
  sidecar issue-2 GH_URL https://github.com/acme/widgets/issues/2
  jq -n '{items: [
    {status: "Backlog",     content: {type: "Issue", number: 1, title: "one",   body: "B1.", url: "https://github.com/acme/widgets/issues/1", repository: "acme/widgets"}},
    {status: "In progress", content: {type: "Issue", number: 3, title: "three", body: "",    url: "https://github.com/acme/widgets/issues/3", repository: "acme/widgets"}},
    {status: null,          content: {type: "Issue", number: 2, title: "two",   body: "",    url: "https://github.com/acme/widgets/issues/2", repository: "acme/widgets"}},
    {status: "Ready",       content: {type: "Issue", number: 4, title: "four",  body: "",    url: "https://github.com/acme/widgets/issues/4", repository: "acme/other"}},
    {status: "done",        content: {type: "Issue", number: 5, title: "five",  body: "",    url: "https://github.com/acme/widgets/issues/5", repository: "acme/widgets"}},
    {status: "Ready",       content: {type: "DraftIssue", title: "draft", body: ""}},
    {status: "Ready",       content: {type: "Issue", number: 6, title: "six",   body: "",    url: "https://github.com/acme/widgets/issues/6", repository: "acme/widgets"}}
  ]}' > "$GH_FIX/project.json"
  snap
  assert_equal "$(q .next.source)" tracker
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#1 #6"
  assert_equal "$(q '.next.items[0].description')" "B1."
  run grep -F "project item-list 7 --owner acme" "$STUB_CALLS_DIR/gh.calls"
  assert_success
}

@test "next gh fallback: draft items are left out even when the doc names no repo" {
  sed -i.bak '/\*\*Repo\*\*/d' "$MAIN_REPO/.claude/gh-workflow.md"
  jq -n '{items: [
    {status: "Ready", content: {type: "DraftIssue", title: "draft", body: ""}},
    {status: "Ready", content: {type: "Issue", number: 6, title: "six", body: "", url: "https://github.com/acme/widgets/issues/6", repository: "acme/widgets"}}
  ]}' > "$GH_FIX/project.json"
  snap
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#6"
}

@test "next local fallback: the tasks/ backlog by id, skipping in-progress, done and in-flight" {
  loadout local
  mkdir -p "$MAIN_REPO/tasks"
  local t
  for t in "010|ten|todo" "002|two|todo" "003|three|done" "004|four|in-progress" "005|five|todo"; do
    IFS='|' read -r id title status <<<"$t"
    printf -- '---\nid: %s\ntitle: %s\nstatus: %s\n---\n' "$id" "$title" "$status" > "$MAIN_REPO/tasks/$id-$title.md"
  done
  sidecar five TASK_FILE "$MAIN_REPO/tasks/005-five.md"
  snap
  assert_equal "$(q .next.source)" tracker
  assert_equal "$(q '[.next.items[].title] | join(" ")')" "two ten"
}

@test "next jira: no fallback, the section is empty" {
  loadout jira
  snap
  assert_equal "$(q .next.source)" none
  assert_equal "$(q '.next.items | length')" 0
}

# ----- done -----------------------------------------------------------------------

@test "done: merged PRs that close an item, with summary, body and merge sha; unlinked ones left out" {
  pr_fixture 11 task/x $'Closes #4\n\n## Summary\n\nShipped it.' 3600 > "$GH_FIX/pr-11.json"
  pr_fixture 12 chore/bump "no issue here" 1800 > "$GH_FIX/pr-12.json"
  merged_idx "$GH_FIX/pr-11.json" "$GH_FIX/pr-12.json"
  snap
  assert_equal "$(q '.done.items | length')" 1
  assert_equal "$(q '.done.items[0].label')" "#4"
  assert_equal "$(q '.done.items[0].summary')" "Shipped it."
  assert_equal "$(q '.done.items[0].merge_sha')" sha11
  assert_equal "$(q '.done.items[0].body')" $'Closes #4\n\n## Summary\n\nShipped it.'
}

@test "done: the last 24 hours or the last 10, whichever is more" {
  local n files=()
  # 12 merged an hour apart within the day, then 5 older ones.
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pr_fixture "$n" "task/issue-$n" "Closes #$n" "$((n * 3600))" > "$GH_FIX/pr-$n.json"; files+=("$GH_FIX/pr-$n.json")
  done
  for n in 13 14 15 16 17; do
    pr_fixture "$n" "task/issue-$n" "Closes #$n" "$((n * 86400))" > "$GH_FIX/pr-$n.json"; files+=("$GH_FIX/pr-$n.json")
  done
  merged_idx "${files[@]}"
  snap
  assert_equal "$(q '.done.items | length')" 12
  assert_equal "$(q '.done.items[0].number')" 1
  # With only three inside the day, the floor of 10 applies.
  merged_idx "$GH_FIX/pr-1.json" "$GH_FIX/pr-2.json" "$GH_FIX/pr-3.json" \
    "$GH_FIX"/pr-1[3-7].json "$GH_FIX"/pr-1[0-2].json "$GH_FIX/pr-9.json"
  snap
  assert_equal "$(q '.done.items | length')" 10
}

@test "done: each merged PR is fetched from the forge once, then served from the cache" {
  pr_fixture 11 task/x "Closes #4" 3600 > "$GH_FIX/pr-11.json"
  merged_idx "$GH_FIX/pr-11.json"
  snap
  snap
  assert_equal "$(q '.done.items[0].label')" "#4"
  run grep -c "^gh pr view 11 " "$STUB_CALLS_DIR/gh.calls"
  assert_output 1
  assert [ -s "$TASK_FORCE_HOME/monitor/$NAME/prs/11.json" ]
}

@test "done jira: linked through the task/<slug> head branch, the key in its own case" {
  loadout jira
  pr_fixture 11 task/proj-7 "no closes line" 3600 > "$GH_FIX/pr-11.json"
  merged_idx "$GH_FIX/pr-11.json"
  snap
  assert_equal "$(q '.done.items[0].label')" PROJ-7
  assert_equal "$(q '.done.items[0].summary')" "no closes line"
}

# ----- attention ------------------------------------------------------------------

@test "attention: an unread PM inbox lights the repo, with the count in words" {
  msg "pm-$NAME" inbox 1 "worker-$NAME-a" review-requested 3
  msg "pm-$NAME" inbox 2 "worker-$NAME-b" review-requested 4
  msg "pm-$NAME" processed 3 "worker-$NAME-c" review-requested 5
  snap
  assert_equal "$(q .attention.active)" true
  assert_equal "$(q '.attention.signals | map(.kind) | join(",")')" unread-inbox
  assert_equal "$(q '.attention.signals[0].text')" "✉ 2 unread"
  assert_equal "$(q .pm.unread)" 2
}

@test "attention: an --also alias's inbox counts toward the primary PM's repo, not its own" {
  OTHER_REPO=$(mktemp -d)
  git -C "$OTHER_REPO" init -q -b main
  local other; other=$(basename "$OTHER_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  session "pm-$NAME" idle
  printf 'ROLE=pm-%s\nALIAS=pm-%s\nREPO=%s\n' "$other" "$NAME" "$OTHER_REPO" > "$SESS/pm-$other.info"
  msg "pm-$other" inbox 1 "worker-$other-a" review-requested 3
  snap --all
  assert_equal "$(jq -r --arg n "$NAME" '.repos[] | select(.name == $n) | .pm.unread' <<<"$output")" 1
  assert_equal "$(jq -r --arg n "$other" '.repos[] | select(.name == $n) | [.pm.alias_of, .pm.unread, .attention.active] | join(",")' <<<"$output")" "pm-$NAME,0,false"
}

@test "attention: a finished review on an open PR waits until the PM answers it" {
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  msg "pm-$NAME" processed 1 "reviewer-$NAME-pr9" review-complete-clean 9
  snap
  assert_equal "$(q '.attention.signals | map(.kind) | join(",")')" review-waiting-merge
  assert_equal "$(q '.attention.signals[0].prs | join(",")')" 9
  assert_equal "$(q '.attention.signals[0].text')" "1 review waiting merge"
  msg "worker-$NAME-issue-5" processed 2 "pm-$NAME" approved-and-merged 9
  snap
  assert_equal "$(q .attention.active)" false
}

@test "attention: a later changes-requested settles the review" {
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  msg "pm-$NAME" processed 1 "reviewer-$NAME-pr9" review-complete-with-findings 9
  msg "worker-$NAME-issue-5" processed 2 "pm-$NAME" changes-requested 9
  snap
  assert_equal "$(q .attention.active)" false
}

@test "attention: a review of a PR that is no longer open does not light the repo" {
  msg "pm-$NAME" processed 1 "reviewer-$NAME-pr9" review-complete-clean 9
  snap
  assert_equal "$(q .attention.active)" false
}

@test "attention: a worker awaiting the user lights the repo and is named" {
  session "worker-$NAME-issue-5" awaiting
  session "worker-$NAME-issue-6" busy
  snap
  assert_equal "$(q '.attention.signals | map(.kind) | join(",")')" worker-awaiting
  assert_equal "$(q '.attention.signals[0].text')" "❓ issue-5 is asking"
}

@test "attention: nothing but the three signals lights a repo" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  session "worker-$NAME-issue-5" busy
  session "pm-$NAME" awaiting
  msg "pm-$NAME" processed 1 "worker-$NAME-issue-5" review-requested 9
  msg "worker-$NAME-issue-5" inbox 2 "pm-$NAME" changes-requested 9
  snap
  assert_equal "$(q .attention.active)" false
}

@test "attention: roles are attributed to the longest repo name they start with" {
  # A sibling repo named <name>-x: its worker's role starts with worker-<name>-.
  session "worker-$NAME-x-slug" awaiting "REPO_NAME=$NAME-x"
  snap
  assert_equal "$(q .attention.active)" false
}

# ----- modes and discovery ----------------------------------------------------------

@test "--local makes no forge call and merges with the last full run" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Fix the widget" "Body."
  pr_fixture 11 task/x "Closes #4" 3600 > "$GH_FIX/pr-11.json"
  merged_idx "$GH_FIX/pr-11.json"
  snap
  assert_equal "$(q '.forge.stale')" false
  : > "$STUB_CALLS_DIR/gh.calls"
  session "worker-$NAME-issue-5" awaiting
  snap --local
  assert_success
  assert_equal "$(gh_calls)" ""
  assert_equal "$(jq -r .mode <<<"$output")" local
  assert_equal "$(q '.in_flight[0].title')" "Fix the widget"
  assert_equal "$(q '.in_flight[0].session.state')" awaiting
  assert_equal "$(q '.done.items[0].label')" "#4"
  assert_equal "$(q '.forge.stale')" true
}

@test "--local with no previous run falls back to the slug and writes nothing" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Fix the widget" "Body."
  snap --local
  assert_success
  assert_equal "$(gh_calls)" ""
  assert_equal "$(q '.in_flight[0].title')" issue-5
  assert [ ! -e "$TASK_FORCE_HOME/monitor" ]
}

@test "a full run whose forge does not answer keeps the last result" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Fix the widget" "Body."
  pr_fixture 9 task/issue-5 $'## Summary\n\nDone.' > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  rm -f "$GH_FIX"/*.json
  snap
  assert_success
  assert_equal "$(q '.in_flight[0].title')" "PR title 9"
  assert_equal "$(q '.forge.stale')" true
}

@test "--all adds every repo a radio session names, resolving a worktree to its main repo" {
  OTHER_REPO=$(mktemp -d)
  git -C "$OTHER_REPO" init -q -b main
  git -C "$OTHER_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$OTHER_REPO-worktrees"
  git -C "$OTHER_REPO" worktree add -q "$OTHER_REPO-worktrees/w" -b task/w
  local other; other=$(basename "$OTHER_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  printf 'ROLE=worker-%s-w\nREPO=%s\nREPO_NAME=%s\nSTATE=awaiting\n' "$other" "$OTHER_REPO-worktrees/w" "$other" \
    > "$SESS/worker-$other-w.info"
  snap
  assert_equal "$(jq '.repos | length' <<<"$output")" 1
  snap --all
  assert_equal "$(jq -r '[.repos[].name] | join(" ")' <<<"$output")" "$NAME $other"
  assert_equal "$(jq -r --arg n "$other" '.repos[] | select(.name == $n) | .attention.signals[0].kind' <<<"$output")" worker-awaiting
}

@test "the description cache keeps only refs a run still looks up" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  issue 5 "Fix the widget" "Body."
  snap
  assert_equal "$(jq -r '.issues | keys | join(",")' "$TASK_FORCE_HOME/monitor/$NAME/forge.json")" \
    https://github.com/acme/widgets/issues/5
  rm "$WORKTREE_BASE/.issue-5.info"
  snap
  assert_equal "$(jq -r '.issues | length' "$TASK_FORCE_HOME/monitor/$NAME/forge.json")" 0
}

@test "the forge cache is written under \$TASK_FORCE_HOME" {
  snap
  assert [ -s "$TASK_FORCE_HOME/monitor/$NAME/forge.json" ]
}

# ----- text extraction ----------------------------------------------------------------

@test "tm_first_paragraph skips headings and comments, and stops at a list item" {
  run bash -c "source '$REPO_ROOT_REAL/lib/monitor-text.sh'; printf '%s\n' '<!-- c -->' '# H' '' 'one' 'two' '- item' | tm_first_paragraph"
  assert_output "one two"
  run bash -c "source '$REPO_ROOT_REAL/lib/monitor-text.sh'; printf '%s\n' '## H' '- first item' 'wraps' '- second' | tm_first_paragraph"
  assert_output "first item wraps"
}

@test "tm_pr_summary prefers ## Summary, then after Closes, then the first paragraph" {
  local lib="$REPO_ROOT_REAL/lib/monitor-text.sh"
  run bash -c "source '$lib'; printf '%s\n' 'Closes #1' '' 'after' '' '## Summary' '' 'sum' | tm_pr_summary"
  assert_output "sum"
  run bash -c "source '$lib'; printf '%s\n' 'intro' '' 'Fixes #1' '' 'after' | tm_pr_summary"
  assert_output "after"
  run bash -c "source '$lib'; printf '%s\n' 'just this' | tm_pr_summary"
  assert_output "just this"
}
