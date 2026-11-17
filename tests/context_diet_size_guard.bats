#!/usr/bin/env bats
# Size guard for the always-loaded workflow doc (#401, context-diet epic #395).
#
# Every PM, planner, worker and reviewer session loads the workflow doc whole.
# #397–#400 cut it to what every role needs at every turn; this pins that, so a
# new section cannot grow it back unnoticed. Each loadout's task-init renders
# its template into a scratch repo, and the managed region (the bytes task-init
# owns, between its markers) must fit the budget. Repo-specific notes below the
# end marker are the user's and do not count.
#
# Over budget? Move the long form to the command's --help and
# docs/shell-commands.md and leave an index line (the #397 treatment), or
# to an on-demand skill (#398). Raise the budget only for a rule every role must
# never miss, and say so in the PR.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

BUDGET=10240

setup() {
  setup_repo
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# Bytes between the start and end markers of the installed doc.
_managed_bytes() {
  awk '$0 == "<!-- task-init:managed:start -->" { f = 1; next }
       $0 == "<!-- task-init:managed:end -->"   { f = 0 }
       f' "$1" | wc -c | tr -d ' '
}

# _assert_within_budget <loadout> <installed doc, relative to the repo>
_assert_within_budget() {
  local loadout="$1" doc="$2" bytes
  run "$REPO_ROOT_REAL/$loadout/bin/task-init" </dev/null
  assert_success
  assert [ -f "$MAIN_REPO/$doc" ]
  grep -qxF '<!-- task-init:managed:end -->' "$MAIN_REPO/$doc"
  bytes=$(_managed_bytes "$MAIN_REPO/$doc")
  # A region that rendered empty would pass any budget.
  [[ "$bytes" -gt 1000 ]] || fail "$loadout: managed region is only $bytes bytes"
  [[ "$bytes" -le "$BUDGET" ]] ||
    fail "$loadout: managed region of $doc is $bytes bytes, over the $BUDGET-byte budget"
}

@test "claude-gh workflow doc's managed region fits the budget" {
  _assert_within_budget claude-gh .claude/gh-workflow.md
}

@test "claude-jira workflow doc's managed region fits the budget" {
  _assert_within_budget claude-jira .claude/jira-workflow.md
}

@test "claude-local workflow doc's managed region fits the budget" {
  _assert_within_budget claude-local .claude/local-workflow.md
}

@test "claude-notion workflow doc's managed region fits the budget" {
  _assert_within_budget claude-notion .claude/notion-workflow.md
}

@test "kiro-gh workflow doc's managed region fits the budget" {
  _assert_within_budget kiro-gh .kiro/steering/gh-workflow.md
}

@test "kiro-local workflow doc's managed region fits the budget" {
  _assert_within_budget kiro-local .kiro/steering/local-workflow.md
}

@test "kiro-notion workflow doc's managed region fits the budget" {
  _assert_within_budget kiro-notion .kiro/steering/notion-workflow.md
}

@test "every shipped template has a guard above" {
  local t n
  n=0
  for t in "$REPO_ROOT_REAL"/*/steering/*.example.md; do
    n=$((n + 1))
  done
  assert_equal "$n" 7
}
