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

# --separate-stderr, for the skipped-repo warnings (#296).
bats_require_minimum_version 1.5.0

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
  "api graphql") _serve project.json ;;
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
# Adds the live worktree the sidecar describes, as task-work does: a sidecar
# whose worktree is gone is an orphan, not in flight (#286). ORPHAN=missing
# writes the sidecar alone; ORPHAN=unregistered adds a plain directory git does
# not know as a worktree.
sidecar() {
  local slug="$1" key="$2" ref="$3"; shift 3
  case "${ORPHAN:-}" in
    missing) ;;
    unregistered) mkdir -p "$WORKTREE_BASE/$slug" ;;
    *) git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug" ;;
  esac
  { printf 'BASE_BRANCH=main\nSLUG=%s\n%s=%s\nTAB_ID=4\n' "$slug" "$key" "$ref"
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$WORKTREE_BASE/.$slug.info"
}

# session <role> <state> [extra KEY=VALUE lines...]
# The heartbeat is a minute old unless $HB says otherwise.
session() {
  local role="$1" state="$2" hb="${HB:-$(ago 60)}"; shift 2
  { printf 'ROLE=%s\nTAB=%s\nTAB_ID=4\nZELLIJ_SESSION=zs\nREPO=%s\nREPO_NAME=%s\nSTATE=%s\nLAST_HEARTBEAT=%s\nAGENT=claude\nLOADOUT=claude-gh\n' \
      "$role" "$role" "$MAIN_REPO" "$NAME" "$state" "$hb"
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

@test "a repo with both assistants installed reports the active one's loadout (#293)" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  cp "$MAIN_REPO/.claude/gh-workflow.md" "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  git -C "$MAIN_REPO" config task-force.assistant kiro
  snap --local --json
  assert_success
  assert_equal "$(q .loadout)" kiro-gh
  assert_equal "$(q .agent)" kiro
  git -C "$MAIN_REPO" config task-force.assistant claude
  snap --local --json
  assert_equal "$(q .loadout)" claude-gh
}

@test "worktree_base names the directory holding the repo's sidecars" {
  # The front end watches it for a new .<slug>.info, so it must be the
  # directory task-work writes them to, not a path the reader re-derives.
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  snap
  assert_success
  [[ -f "$(q .worktree_base)/.issue-5.info" ]]
  assert_equal "$(q '.in_flight[0].worktree | split("/") | .[:-1] | join("/")')" "$(q .worktree_base)"
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

@test "in flight: a sidecar whose worktree directory is gone is an orphan, not in flight" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  ORPHAN=missing sidecar issue-6 GH_URL https://github.com/acme/widgets/issues/6
  snap
  assert_success
  assert_equal "$(q '[.in_flight[].slug] | join(" ")')" issue-5
  assert_equal "$(q '.orphans | length')" 1
  assert_equal "$(q '.orphans[0].slug')" issue-6
  assert_equal "$(q '.orphans[0].reason')" missing
  [[ "$(q '.orphans[0].info_path')" == */.issue-6.info ]]
  [[ -f "$(q '.orphans[0].info_path')" ]]
}

@test "in flight: a directory git does not list as a worktree is an orphan" {
  ORPHAN=unregistered sidecar issue-6 GH_URL https://github.com/acme/widgets/issues/6
  snap
  assert_success
  assert_equal "$(q '.in_flight | length')" 0
  assert_equal "$(q '.orphans[0].slug')" issue-6
  assert_equal "$(q '.orphans[0].reason')" unregistered
}

@test "in flight: a worktree removed with git worktree remove leaves an orphan sidecar" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  snap
  assert_equal "$(q '.in_flight | length')" 1
  assert_equal "$(q '.orphans')" "[]"
  git -C "$MAIN_REPO" worktree remove "$WORKTREE_BASE/issue-5"
  snap
  assert_equal "$(q '.in_flight | length')" 0
  assert_equal "$(q '.orphans[0].reason')" missing
}

@test "in flight: an orphaned reviewer sidecar attaches to nothing" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  ORPHAN=missing sidecar review-pr9 GH_URL https://github.com/acme/widgets/pull/9 PR_NUMBER=9 ISSUE_NUMBER=5
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  assert_equal "$(q '.in_flight[0].reviewers | length')" 0
  assert_equal "$(q '.orphans[0].slug')" review-pr9
}

@test "in flight: the worker session's STATE and heartbeat are joined" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  HB=2026-10-20T10:00:00Z session "worker-$NAME-issue-5" awaiting
  snap
  assert_equal "$(q '.in_flight[0].session.state')" awaiting
  assert_equal "$(q '.in_flight[0].session.last_heartbeat')" 2026-10-20T10:00:00Z
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

# The describer jira and notion fall back to, and gh / local reach whenever the
# forge does not answer. It bound `$label` until #296, which jq 1.6 refuses to
# compile (`label` is a keyword there): the empty output then broke the next
# --argjson and the whole snapshot. CI runs this file under jq 1.6 too.
@test "the default item describer prints the item object for a key, a URL and a bare slug" {
  run /bin/bash -c 'source "$1/lib/trackers/_default.sh"
    _aw_tracker_item_describe_default PROJ-42 kiro-config
    _aw_tracker_item_describe_default https://www.notion.so/My-Task-abc my-task
    _aw_tracker_item_describe_default "" lone-slug' _ "$REPO_ROOT_REAL"
  assert_success
  assert_line --index 0 '{"ref":"PROJ-42","label":"PROJ-42","number":null,"title":"PROJ-42 · kiro-config","description":null,"url":null}'
  assert_line --index 1 '{"ref":"https://www.notion.so/My-Task-abc","label":null,"number":null,"title":"my-task","description":null,"url":"https://www.notion.so/My-Task-abc"}'
  assert_line --index 2 '{"ref":"","label":null,"number":null,"title":"lone-slug","description":null,"url":null}'
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

# #307: a reviewer's `pr` went out as the string "9", and the front end's u64
# refused the whole document, so the board stopped refreshing whenever a review
# ran. Every PR number in the document is a number.
@test "PR numbers are numbers: reviewers[].pr, last_intent.pr, pr.number" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  sidecar review-pr9 GH_URL https://github.com/acme/widgets/pull/9 PR_NUMBER=9 ISSUE_NUMBER=5
  session "reviewer-$NAME-pr9" busy
  msg "pm-$NAME" processed 1 "worker-$NAME-issue-5" review-requested 9
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap
  assert_equal "$(q '.in_flight[0].reviewers[0].pr | type')" number
  assert_equal "$(q '.in_flight[0].reviewers[0].pr')" 9
  assert_equal "$(q '.in_flight[0].last_intent.pr | type')" number
  assert_equal "$(q '.in_flight[0].pr.number | type')" number
}

# The PR the worker named in its own messages, when no PR has its head branch.
@test "PR numbers are numbers: the radio fallback PR" {
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  msg "pm-$NAME" processed 1 "worker-$NAME-issue-5" review-requested 9
  snap
  assert_equal "$(q '.in_flight[0].pr.number | type')" number
  assert_equal "$(q '.in_flight[0].last_intent.pr | type')" number
}

# The regression guard #307 asked for: the Rust tests parsed hand-written JSON,
# which is how a string where the parser wants a number shipped. This scenario's
# real output must have the same shape, value for value type, as the checked-in
# fixture `cargo test` parses (monitor/src/snapshot.rs). Values differ run to
# run (paths, times), so only types are compared. Regenerate with
# TASK_FORCE_REGEN_FIXTURES=1 after an intended schema change.
@test "the shared snapshot fixture has the real snapshot's shape (reviewer attached)" {
  local fixture="$REPO_ROOT_REAL/tests/fixtures/task-monitor/snapshot-reviewer.json"
  issue 5 "Issue five" "The fifth issue."
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  sidecar review-pr9 GH_URL https://github.com/acme/widgets/pull/9 PR_NUMBER=9 ISSUE_NUMBER=5
  session "worker-$NAME-issue-5" idle
  session "reviewer-$NAME-pr9" busy
  session "pm-$NAME" idle
  msg "pm-$NAME" processed 1 "worker-$NAME-issue-5" review-requested 9
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  snap --json
  assert_success
  if [[ -n "${TASK_FORCE_REGEN_FIXTURES:-}" ]]; then
    mkdir -p "$(dirname "$fixture")"
    # Scrub the scratch paths and repo name, so the checked-in file reads clean.
    jq --arg root "$MAIN_REPO" --arg name "$NAME" '
      walk(if type == "string" then split($root) | join("/src/widgets")
                                    | split($name) | join("widgets") else . end)' \
      <<<"$output" > "$fixture"
  fi
  local shape='walk(if type == "object" or type == "array" then . else type end)'
  assert_equal "$(jq -cS "$shape" <<<"$output")" "$(jq -cS "$shape" "$fixture")"
  assert_equal "$(jq -r '.repos[0].in_flight[0].reviewers[0].pr | type' "$fixture")" number
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

# project_page <compact-items-json> [hasNextPage]
# One page of the GraphQL answer aw_tracker_next_fallback asks for, built from
# compact items: {status, prio, type, number, title, body, repo, state, subs,
# archived}. The project's Priority options are p0, p1, p2, in that order.
project_page() {
  jq -c --argjson more "${2:-false}" '{data: {repositoryOwner: {projectV2: {
    priority: {options: [{id: "p0"}, {id: "p1"}, {id: "p2"}]},
    items: {pageInfo: {hasNextPage: $more, endCursor: "c"}, nodes: map({
      isArchived: (.archived // false),
      status: (if .status then {name: .status} else null end),
      priority: (if .prio then {optionId: .prio} else null end),
      content: (if .type == "DraftIssue" then {__typename: "DraftIssue"} else
        {__typename: "Issue", number, title: (.title // "t\(.number)"), body: (.body // ""),
         url: "https://github.com/acme/widgets/issues/\(.number)", state: (.state // "OPEN"),
         repository: {nameWithOwner: (.repo // "acme/widgets")},
         subIssuesSummary: {total: (.subs // 0)}} end)})}}}}}' <<<"$1"
}

@test "next gh fallback: project issues in none of the three statuses, minus in flight and other repos" {
  sidecar issue-2 GH_URL https://github.com/acme/widgets/issues/2
  project_page '[
    {"status": "Backlog",     "number": 1, "body": "B1."},
    {"status": "In progress", "number": 3},
    {"status": null,          "number": 2},
    {"status": "Ready",       "number": 4, "repo": "acme/other"},
    {"status": "done",        "number": 5},
    {"status": "Ready",       "type": "DraftIssue"},
    {"status": "Ready",       "number": 6}
  ]' > "$GH_FIX/project.json"
  snap
  assert_equal "$(q .next.source)" tracker
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#1 #6"
  assert_equal "$(q '.next.items[0].description')" "B1."
  run grep -F -- "-f owner=acme -F number=7" "$STUB_CALLS_DIR/gh.calls"
  assert_success
}

@test "next gh fallback: epics with sub-issues, closed issues and archived items are left out" {
  project_page '[
    {"status": "Backlog", "number": 1, "subs": 3},
    {"status": "Backlog", "number": 2, "state": "CLOSED"},
    {"status": "Backlog", "number": 3, "archived": true},
    {"status": "Backlog", "number": 4}
  ]' > "$GH_FIX/project.json"
  snap
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#4"
}

@test "next gh fallback: ordered by the Priority field's option order, then API order" {
  project_page '[
    {"status": "Backlog", "number": 1, "prio": "p2"},
    {"status": "Backlog", "number": 2},
    {"status": "Backlog", "number": 3, "prio": "p0"},
    {"status": "Backlog", "number": 4, "prio": "p2"}
  ]' > "$GH_FIX/project.json"
  # A second page, as `gh api graphql --paginate` prints it: one response after another.
  project_page '[{"status": "Backlog", "number": 5, "prio": "p1"}]' >> "$GH_FIX/project.json"
  snap
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#3 #5 #1 #4 #2"
}

@test "next gh fallback: an unknown project is a failed ask, so the last answer is kept" {
  project_page '[{"status": "Backlog", "number": 4}]' > "$GH_FIX/project.json"
  snap
  echo '{"data": {"repositoryOwner": {"projectV2": null}}}' > "$GH_FIX/project.json"
  snap
  assert_equal "$(q '[.next.items[].label] | join(" ")')" "#4"
}

@test "next gh fallback: draft items are left out even when the doc names no repo" {
  sed -i.bak '/\*\*Repo\*\*/d' "$MAIN_REPO/.claude/gh-workflow.md"
  project_page '[
    {"status": "Ready", "type": "DraftIssue"},
    {"status": "Ready", "number": 6}
  ]' > "$GH_FIX/project.json"
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

# queue_line <line>... — the queue file, written as task-monitor-queue would.
queue_lines() {
  mkdir -p "$TASK_FORCE_HOME/monitor/$NAME"
  printf '%s\n' "$@" > "$TASK_FORCE_HOME/monitor/$NAME/queue"
}

NOTION_A=https://app.notion.com/p/3fdd9a72260f81559d2fdfe4589b5b1c
NOTION_B=https://www.notion.so/acme/Fix-auth-3fad9a72260f8184be21d483ce5d88d4?pvs=4

@test "next notion: the PM's title is the title, the page URL stays the url, the note is kept" {
  loadout notion
  queue_lines "$NOTION_A"$'\tsign-off first\tArms schema' "$NOTION_B"
  snap
  assert_equal "$(q '.next.items[0].title')" "Arms schema"
  assert_equal "$(q '.next.items[0].note')" "sign-off first"
  assert_equal "$(q '.next.items[0].url')" "$NOTION_A"
  assert_equal "$(q '.next.items[0].ref')" "$NOTION_A"
  # No title given: the label is the compact page id, the title is empty, and
  # the URL is not shown as either.
  assert_equal "$(q '.next.items[1].label')" "notion:3fad9a72…"
  assert_equal "$(q '.next.items[1].title')" ""
  assert_equal "$(q '.next.items[1].url')" "$NOTION_B"
  assert_equal "$(q '.next.items[0].label')" "notion:3fdd9a72…"
}

@test "next notion: a blank title cached by an earlier full run does not hide a title set later" {
  loadout notion
  queue_lines "$NOTION_A"
  snap
  assert_equal "$(jq -r --arg r "$NOTION_A" '.issues[$r].title' "$TASK_FORCE_HOME/monitor/$NAME/forge.json")" ""
  queue_lines "$NOTION_A"$'\t\tArms schema'
  snap --local
  assert_success
  assert_equal "$(q '.next.items[0].title')" "Arms schema"
  snap
  assert_equal "$(q '.next.items[0].title')" "Arms schema"
  # The PM's title is the queue's, never the cache's.
  assert_equal "$(jq -r --arg r "$NOTION_A" '.issues[$r].title' "$TASK_FORCE_HOME/monitor/$NAME/forge.json")" ""
}

@test "next jira: the PM's title replaces the bare key; a browse URL is labelled by its key" {
  loadout jira
  queue_lines $'PROJ-7\t\tRotate the keys' https://acme.atlassian.net/browse/PROJ-9 PROJ-8
  snap
  assert_equal "$(q '.next.items[0].title')" "Rotate the keys"
  assert_equal "$(q '.next.items[0].label')" "PROJ-7"
  assert_equal "$(q '.next.items[1].label')" "PROJ-9"
  assert_equal "$(q '.next.items[1].url')" https://acme.atlassian.net/browse/PROJ-9
  assert_equal "$(q '.next.items[2].title')" "PROJ-8"
}

@test "next gh: the tracker's real title wins over the PM's; one the forge cannot give yields to it" {
  issue 8 "Eight" "Body eight."
  queue_lines $'8\t\tPM name for eight' $'9\t\tPM name for nine'
  snap
  assert_equal "$(q '.next.items[0].title')" "Eight"
  assert_equal "$(q '.next.items[1].title')" "PM name for nine"
}

@test "next: a blank title served from the cache, when the tracker cannot answer, yields to the PM's" {
  mkdir -p "$TASK_FORCE_HOME/monitor/$NAME"
  echo '{"issues": {"9": {"ref": "9", "label": "#9", "number": 9, "title": "", "description": null, "url": null}}}' \
    > "$TASK_FORCE_HOME/monitor/$NAME/forge.json"
  queue_lines $'9\t\tPM name for nine'
  snap --local
  assert_success
  assert_equal "$(q '.next.items[0].label')" "#9"
  assert_equal "$(q '.next.items[0].title')" "PM name for nine"
}

@test "next local: the task file's title wins over the PM's" {
  loadout local
  mkdir -p "$MAIN_REPO/tasks"
  printf -- '---\nid: 004\ntitle: Add logout\nstatus: todo\n---\n\nBody.\n' > "$MAIN_REPO/tasks/004-add-logout.md"
  queue_lines $'004-add-logout.md\t\tPM name'
  snap
  assert_equal "$(q '.next.items[0].title')" "Add logout"
}

@test "the notion describer: a bare id, a Title-<id> segment, a query string, and a URL with no id" {
  run /bin/bash -c 'source "$1/lib/trackers/_default.sh"; source "$1/lib/trackers/notion.sh"
    aw_tracker_item_describe https://app.notion.com/p/3fdd9a72260f81559d2fdfe4589b5b1c "" | jq -r .label
    aw_tracker_item_describe "https://www.notion.so/My-Task-abc123def456abc123def456abc123de?pvs=4" my-task | jq -r ".label, .title"
    aw_tracker_item_describe https://www.notion.so/acme/some-page/ "" | jq -r .label
    aw_tracker_item_describe free-slug "" | jq -r .label' _ "$REPO_ROOT_REAL"
  assert_success
  assert_output "$(printf 'notion:3fdd9a72…\nnotion:abc123de…\nmy-task\nnotion:some-page\nfree-slug')"
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
  # What radio's alias hop does with a worker's `--to pm`: it lands in the
  # primary's inbox. The alias owns none.
  msg "pm-$NAME" inbox 1 "worker-$other-a" review-requested 3
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
  assert_equal "$(q '.attention.signals[0].prs | map(type) | join(",")')" number
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

@test "attention: an awaiting worker whose heartbeat is over an hour old does not light the repo" {
  HB=$(ago 3700) session "worker-$NAME-issue-5" awaiting
  snap
  assert_equal "$(q .attention.active)" false
  # The session itself still shows, so the front end can show it as gone quiet.
  sidecar issue-5 GH_URL https://github.com/acme/widgets/issues/5
  snap
  assert_equal "$(q '.in_flight[0].session.state')" awaiting
}

@test "attention: two messages in the same second are ordered by the radio log, not by id" {
  pr_fixture 9 task/issue-5 "Closes #5" > "$BATS_TEST_TMPDIR/p9"
  open_prs "$BATS_TEST_TMPDIR/p9"
  # Sent in this order within one second: the review, then the PM's answer. By
  # id they sort the other way round (from-pm-… < from-reviewer-…), which
  # would leave the review looking unanswered.
  local rev="20261020-100001-from-reviewer-$NAME-pr9-zq" pm="20261020-100001-from-pm-$NAME-a1"
  mkdir -p "$MBOX/pm-$NAME/processed" "$MBOX/worker-$NAME-issue-5/processed"
  printf -- '---\nid: %s\nfrom: reviewer-%s-pr9\nto: pm-%s\nintent: review-complete-clean\npr: 9\ncreated_at: 2026-10-20T10:00:01Z\n---\n' \
    "$rev" "$NAME" "$NAME" > "$MBOX/pm-$NAME/processed/$rev.md"
  printf -- '---\nid: %s\nfrom: pm-%s\nto: worker-%s-issue-5\nintent: changes-requested\npr: 9\ncreated_at: 2026-10-20T10:00:01Z\n---\n' \
    "$pm" "$NAME" "$NAME" > "$MBOX/worker-$NAME-issue-5/processed/$pm.md"
  printf '2026-10-20T10:00:01Z send id=%s from=x to=y intent=z\n' "$rev" "$pm" > "$TASK_FORCE_HOME/radio/log"
  snap
  assert_equal "$(q .attention.active)" false
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

@test "a repo whose forge has never answered is unavailable, not stale" {
  rm -f "$GH_FIX"/*.json
  snap
  assert_success
  assert_equal "$(q '[.forge.available, .forge.stale] | map(tostring) | join(",")')" "false,false"
  echo '[]' > "$GH_FIX/pr-open.json"
  snap
  assert_equal "$(q '[.forge.available, .forge.stale] | map(tostring) | join(",")')" "true,false"
  snap --local
  assert_equal "$(q '[.forge.available, .forge.stale] | map(tostring) | join(",")')" "true,true"
}

@test "--all adds every repo a radio session names, resolving a worktree to its main repo" {
  OTHER_REPO=$(mktemp -d)
  git -C "$OTHER_REPO" init -q -b main
  git -C "$OTHER_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$OTHER_REPO-worktrees"
  git -C "$OTHER_REPO" worktree add -q "$OTHER_REPO-worktrees/w" -b task/w
  local other; other=$(basename "$OTHER_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  printf 'ROLE=worker-%s-w\nREPO=%s\nREPO_NAME=%s\nSTATE=awaiting\nLAST_HEARTBEAT=%s\n' "$other" "$OTHER_REPO-worktrees/w" "$other" "$(ago 60)" \
    > "$SESS/worker-$other-w.info"
  snap
  assert_equal "$(jq '.repos | length' <<<"$output")" 1
  snap --all
  assert_equal "$(jq -r '[.repos[].name] | join(" ")' <<<"$output")" "$NAME $other"
  assert_equal "$(jq -r --arg n "$other" '.repos[] | select(.name == $n) | .attention.signals[0].kind' <<<"$output")" worker-awaiting
}

# A repo whose per-repo document comes out empty or not an object is skipped
# with a warning, not appended (#296). Empty is jq 1.6's own failure shape: it
# exits 0 having printed nothing, and `jq -e .` passed that file there. A jq
# shim answers the assembly call for OTHER_REPO's name only; every other call
# is the real jq.
_all_with_broken_other() {
  local payload="$1" real_jq shim
  real_jq=$(command -v jq)
  OTHER_REPO=$(mktemp -d)
  git -C "$OTHER_REPO" init -q -b main
  git -C "$OTHER_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local other; other=$(basename "$OTHER_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  printf 'ROLE=pm-%s\nREPO=%s\nREPO_NAME=%s\nSTATE=idle\nLAST_HEARTBEAT=%s\n' "$other" "$OTHER_REPO" "$other" "$(ago 60)" \
    > "$SESS/pm-$other.info"
  shim=$(mktemp -d "$BATS_TEST_TMPDIR/jqshim.XXXX")
  cat > "$shim/jq" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" --arg name $other "*monitor-assemble.jq*) printf '%s' '$payload'; exit 0 ;;
esac
exec "$real_jq" "\$@"
SHIM
  chmod +x "$shim/jq"
  run --separate-stderr env PATH="$shim:$PATH" /bin/bash -c 'cd "$1" && shift && /bin/bash "$@"' _ "$MAIN_REPO" "$SNAP" --all
}

@test "--all skips a repo whose document came out empty, and says so" {
  _all_with_broken_other ''
  assert_success
  assert_equal "$(jq -r '[.repos[].name] | join(" ")' <<<"$output")" "$NAME"
  assert [ -n "$(grep -E "skipped .*$(basename "$OTHER_REPO"): its snapshot failed" <<<"$stderr")" ]
}

@test "--all skips a repo whose document is not an object" {
  _all_with_broken_other '"oops"'
  assert_success
  assert_equal "$(jq -r '[.repos[] | type] | join(" ")' <<<"$output")" object
  assert_equal "$(jq -r '[.repos[].name] | join(" ")' <<<"$output")" "$NAME"
  assert [ -n "$(grep -E "skipped .*$(basename "$OTHER_REPO"): its snapshot failed" <<<"$stderr")" ]
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

# #278: kiro-cli has no hook for "waiting on the user", so worker-awaiting is
# claude-only. Every doc that describes the signal says so and names the
# kiro-cli version that was checked, so the claim can be re-tested later.
@test "every doc describing worker-awaiting names the kiro gap and the kiro-cli version" {
  local docs=(
    "$REPO_ROOT_REAL/.claude/gh-workflow.md"
    "$REPO_ROOT_REAL/claude-gh/steering/gh-workflow.example.md"
    "$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md"
    "$REPO_ROOT_REAL/claude-local/steering/local-workflow.example.md"
    "$REPO_ROOT_REAL/claude-notion/steering/notion-workflow.example.md"
    "$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
    "$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
    "$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
  )
  local f
  for f in "${docs[@]}"; do
    run grep -qF 'The `awaiting` signal is claude-only: kiro-cli (checked on' "$f"
    assert_success
    run grep -q 'claude-only for now' "$f"
    assert_failure
  done
  run grep -qF 'kiro-cli (checked on 2.32.0) has no hook that fires while it' "$REPO_ROOT_REAL/docs/task-monitor-schema.md"
  assert_success
  run grep -qF '#### No awaiting state on kiro' "$REPO_ROOT_REAL/README.md"
  assert_success
  run grep -qF '(#no-awaiting-state-on-kiro)' "$REPO_ROOT_REAL/README.md"
  assert_success
}
