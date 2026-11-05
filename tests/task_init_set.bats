#!/usr/bin/env bats
# task-init --set "<setting>=<value>" (#346): any workflow-doc setting bullet
# from the command line, so a config tool can drive status names and the Watch
# settings the way it drives --site / --key / --board.
#
# Asserts:
#   - a status name and a Watch number are written into the managed region
#   - a re-run keeps a setting it was not given; --force with --set overrides
#   - an unknown label is refused with the valid list, and nothing is written
#   - an empty value restores the template default
#   - --local-only, the local and kiro loadouts, and a tracker bullet set via
#     --set fill the placeholder everywhere, as its shorthand flag does
#   - task-config set / add assistant carry the bullets across

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

DOC=.claude/jira-workflow.md

setup() {
  setup_repo
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# The value of one bullet in the managed region of <doc>.
_bullet() {
  local doc="$1" label="$2"
  awk '/^<!-- task-init:managed:end -->$/ { exit } { print }' "$doc" \
    | sed -nE "s|^- \*\*$label\*\*: \`([^\`]*)\`.*|\1|p"
}

@test "sets a status name and a Watch number" {
  run "$JIRA_TASK_INIT" --site https://acme.atlassian.net --key P --board B \
    --set "Status when done=Closed" --set "Watch poll seconds=60" </dev/null
  assert_success
  run _bullet "$DOC" "Status when done"
  assert_output "Closed"
  run _bullet "$DOC" "Watch poll seconds"
  assert_output "60"
  # The rest of the line is the template's.
  run grep -F -- '- **Status when in review**: `In Review` (leave blank' "$DOC"
  assert_success
}

@test "the label is matched case-insensitively and split on the first =" {
  run "$JIRA_TASK_INIT" --set "watch JQL=project = P AND labels = x" </dev/null
  assert_success
  run _bullet "$DOC" "Watch JQL"
  assert_output "project = P AND labels = x"
}

@test "a re-run keeps a setting it was not given" {
  "$JIRA_TASK_INIT" --set "Status when done=Closed" --set "Watch poll seconds=60" </dev/null
  run "$JIRA_TASK_INIT" --force --set "Status when in review=QA" </dev/null
  assert_success
  run _bullet "$DOC" "Status when done"
  assert_output "Closed"
  run _bullet "$DOC" "Watch poll seconds"
  assert_output "60"
  run _bullet "$DOC" "Status when in review"
  assert_output "QA"
}

@test "a re-run with the same --set gives the same file" {
  "$JIRA_TASK_INIT" --site https://acme.atlassian.net --set "Watch label=bot" </dev/null
  cp "$DOC" first.md
  run "$JIRA_TASK_INIT" --force --site https://acme.atlassian.net --set "Watch label=bot" </dev/null
  assert_success
  run cmp first.md "$DOC"
  assert_success
}

@test "--force with --set overrides the value already in the doc" {
  "$JIRA_TASK_INIT" --set "Watch max in flight=4" </dev/null
  run "$JIRA_TASK_INIT" --force --set "Watch max in flight=1" </dev/null
  assert_success
  run _bullet "$DOC" "Watch max in flight"
  assert_output "1"
}

@test "an unknown label is refused with the valid list, and nothing is written" {
  run "$JIRA_TASK_INIT" --set "Watch nonsense=1" </dev/null
  assert_failure 2
  assert_output --partial "unknown setting 'Watch nonsense'"
  assert_output --partial "Status when done"
  assert_output --partial "Watch poll seconds"
  assert [ ! -e "$DOC" ]
  assert [ ! -e .claude/settings.json ]
}

@test "a spec without = is refused" {
  run "$JIRA_TASK_INIT" --set "Watch label" </dev/null
  assert_failure 2
  assert_output --partial '"<setting>=<value>"'
}

@test "a bare trailing --set is refused on every loadout" {
  local init
  for init in "$JIRA_TASK_INIT" "$CLAUDE_GH_TASK_INIT" "$CLAUDE_LOCAL_TASK_INIT" \
    "$CLAUDE_NOTION_TASK_INIT" "$KIRO_GH_TASK_INIT" "$KIRO_LOCAL_TASK_INIT" "$KIRO_TASK_INIT"; do
    run "$init" --set </dev/null
    assert_failure 2
    assert_output --partial '--set needs "<setting>=<value>"'
  done
  assert [ ! -e "$DOC" ]
}

@test "a value with a backtick is refused, naming the setting" {
  run "$JIRA_TASK_INIT" --set 'Watch label=a`b' </dev/null
  assert_failure 2
  assert_output --partial "value for 'Watch label' may not contain a backtick or a newline"
  assert [ ! -e "$DOC" ]
}

@test "a value with a newline is refused, naming the setting" {
  run "$JIRA_TASK_INIT" --set "Watch JQL=a
b" </dev/null
  assert_failure 2
  assert_output --partial "value for 'Watch JQL' may not contain a backtick or a newline"
  assert [ ! -e "$DOC" ]
}

@test "an empty value restores the template default" {
  "$JIRA_TASK_INIT" --set "Watch poll seconds=60" </dev/null
  run "$JIRA_TASK_INIT" --force --set "Watch poll seconds=" </dev/null
  assert_success
  run _bullet "$DOC" "Watch poll seconds"
  assert_output "300"
}

@test "without --force, an existing doc is kept and the run says --set was not applied" {
  "$JIRA_TASK_INIT" </dev/null
  run "$JIRA_TASK_INIT" --set "Watch label=bot" </dev/null
  assert_success
  assert_output --partial "--set is not applied"
  run _bullet "$DOC" "Watch label"
  assert_output "ai-auto"
}

@test "a bullet below the end marker is the user's: neither rewritten nor carried" {
  "$JIRA_TASK_INIT" </dev/null
  printf '%s\n' '- **Watch poll seconds**: `30`' >>"$DOC"
  run "$JIRA_TASK_INIT" --force --set "Watch label=bot" </dev/null
  assert_success
  run _bullet "$DOC" "Watch poll seconds"
  assert_output "300"
  run tail -n 1 "$DOC"
  assert_output '- **Watch poll seconds**: `30`'
}

@test "a tracker bullet via --set fills its placeholder everywhere, as --key does" {
  run "$JIRA_TASK_INIT" --set "Project key(s)=ML" </dev/null
  assert_success
  run cat "$DOC"
  assert_output --partial 'issue keys look like `ML-123`'
  refute_output --partial "{KEY}"
}

@test "--local-only: --set lands in the untracked doc" {
  run "$JIRA_TASK_INIT" --local-only --set "Status when done=Shipped" </dev/null
  assert_success
  run _bullet "$DOC" "Status when done"
  assert_output "Shipped"
  run git status --porcelain --untracked-files=all
  assert_output ""
}

@test "claude-local and kiro-gh take --set too" {
  run "$CLAUDE_LOCAL_TASK_INIT" --workflow --set "Status when done=closed" </dev/null
  assert_success
  run _bullet .claude/local-workflow.md "Status when done"
  assert_output "closed"
  setup_kiro_agents
  run "$KIRO_GH_TASK_INIT" --workflow --set "Status when in review=QA" </dev/null
  assert_success
  run _bullet .kiro/steering/gh-workflow.md "Status when in review"
  assert_output "QA"
  run "$KIRO_GH_TASK_INIT" --workflow --set "Watch label=x" </dev/null
  assert_failure 2
}

@test "task-config set assistant carries the bullets across" {
  "$CLAUDE_GH_TASK_INIT" --owner acme --repo widgets --project 7 \
    --set "Status when done=Shipped" </dev/null
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "Status when done=Shipped"
  run _bullet .kiro/steering/gh-workflow.md "Status when done"
  assert_output "Shipped"
  run _bullet .kiro/steering/gh-workflow.md "Owner"
  assert_output "acme"
}

@test "task-config add assistant carries the bullets across" {
  setup_stubs
  setup_task_force_home
  "$CLAUDE_GH_TASK_INIT" --owner acme --repo widgets --project 7 \
    --set "Status when in review=QA" </dev/null
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  run _bullet .kiro/steering/gh-workflow.md "Status when in review"
  assert_output "QA"
}
