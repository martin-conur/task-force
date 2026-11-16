#!/usr/bin/env bats
# The workflow docs' Shell Commands section is an index (#397, epic #395).
# Every agent session loads the workflow doc, so the command reference lives in
# each command's --help and docs/shell-commands.md, and the doc keeps one line
# per command.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

INDEXED=(
  task-work task-done task-recreate-worker task-reviewer task-pm task-config
  task-init task-remove ci-guard task-monitor task-monitor-snapshot
  task-monitor-queue
)

@test "the Shell Commands section is under 2 KB in every workflow doc" {
  local doc bytes
  for doc in "${WORKFLOW_DOCS[@]}"; do
    bytes=$(shell_commands_section "$doc" | wc -c | tr -d ' ')
    [ "$bytes" -gt 0 ] || { echo "no Shell Commands section in $doc"; return 1; }
    [ "$bytes" -lt 2048 ] || { echo "$doc: Shell Commands is $bytes bytes"; return 1; }
  done
}

@test "every workflow doc indexes every command, inside the managed region" {
  local cmd
  for cmd in "${INDEXED[@]}"; do
    assert_indexed_everywhere "$cmd"
  done
}

@test "the local loadouts also index task-board" {
  local doc
  for doc in "$CLAUDE_LOCAL_TEMPLATE" "$KIRO_LOCAL_TEMPLATE"; do
    shell_commands_section "$doc" | grep -q '^- `task-board`' \
      || { echo "no task-board line in $doc"; return 1; }
  done
}

@test "the index keeps the Reviewer profile setting task-reviewer reads (#357)" {
  local doc
  for doc in "${WORKFLOW_DOCS[@]}"; do
    shell_commands_section "$doc" | grep -qx -- '- \*\*Reviewer profile\*\*: `none`' \
      || { echo "no Reviewer profile bullet in $doc"; return 1; }
  done
}

@test "the index keeps the merge rule: never gh pr merge --delete-branch (#271)" {
  local doc
  for doc in "${WORKFLOW_DOCS[@]}"; do
    shell_commands_section "$doc" | grep -qF 'git push origin --delete task/<slug>' \
      || { echo "no remote-branch delete in $doc"; return 1; }
    shell_commands_section "$doc" | grep -qF 'never `gh pr merge --delete-branch`' \
      || { echo "no --delete-branch warning in $doc"; return 1; }
  done
}

@test "the index points at --help and docs/shell-commands.md" {
  local doc
  for doc in "${WORKFLOW_DOCS[@]}"; do
    shell_commands_section "$doc" | grep -qF '`docs/shell-commands.md`' \
      || { echo "no docs pointer in $doc"; return 1; }
  done
  [ -f "$SHELL_COMMANDS_DOC" ]
}

@test "docs/shell-commands.md has a section for every command" {
  local h
  for h in task-work task-done task-recreate-worker task-config 'task-config profile' \
           'task-init --local-only' 'task-init --set' task-remove ci-guard \
           task-monitor-snapshot task-monitor task-monitor-queue; do
    grep -qE "^##+ $h\$" "$SHELL_COMMANDS_DOC" || { echo "no heading for $h"; return 1; }
  done
  grep -qx '## Loadout differences' "$SHELL_COMMANDS_DOC"
}

@test "every indexed command's --help points at docs/shell-commands.md" {
  local repo cmd
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  mkdir -p "$repo/.claude"
  cp "$CLAUDE_GH_TEMPLATE" "$repo/.claude/gh-workflow.md"
  cd "$repo"
  for cmd in task-work task-done task-recreate-worker task-reviewer task-pm \
             task-config task-remove ci-guard task-monitor-snapshot task-monitor-queue; do
    run "$REPO_ROOT_REAL/bin/$cmd" --help
    [[ "$output" == *"docs/shell-commands.md"* ]] || { echo "$cmd --help: no docs pointer"; echo "$output"; return 1; }
  done
  run "$REPO_ROOT_REAL/bin/task-config" profile --help
  assert_output --partial 'docs/shell-commands.md'
  for cmd in "$REPO_ROOT_REAL"/*/bin/task-init; do
    run "$cmd" --help
    [[ "$output" == *"docs/shell-commands.md"* ]] || { echo "$cmd --help: no docs pointer"; return 1; }
  done
  run grep -qF 'docs/shell-commands.md' "$REPO_ROOT_REAL/monitor/src/main.rs"
  assert_success
}
