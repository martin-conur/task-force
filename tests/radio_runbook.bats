#!/usr/bin/env bats
# The "When radio misbehaves" runbook (#191).
#
# The runbook's whole value is that its greps and field names match what
# `bin/radio` actually logs. That correspondence is invisible to every other
# test in the suite, so a rename in bin/radio would silently turn the runbook
# into a page of commands that quietly match nothing. These tests pin it, plus
# the #177 loadout-neutrality and the claude/kiro asymmetry the runbook has to
# keep honest (#190).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

CLAUDE_TEMPLATES=(
  "$REPO_ROOT_REAL/claude-gh/steering/gh-workflow.example.md"
  "$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md"
  "$REPO_ROOT_REAL/claude-local/steering/local-workflow.example.md"
  "$REPO_ROOT_REAL/claude-notion/steering/notion-workflow.example.md"
)

KIRO_TEMPLATES=(
  "$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
)

# Every log fragment the runbook tells a reader to grep for. Each must be a
# literal substring of bin/radio, or the documented command matches nothing.
# `loadout=unknown` is deliberately absent: it is assembled at runtime from a
# parameter default, and is asserted separately below.
DOCUMENTED_GREPS=(
  'send id='
  'send: woke'
  'is busy'
  'is awaiting'
  'looks dead'
  'no session for'
  'has no TAB_ID'
  'tab id unresolved'
  'no writable pane'
  'write-chars failed'
  'unregister role='
  'unregister: proceeding'
  'unregister: skipping'
  'skipping (empty payload on '
  'tab_id_src='
  'no tab binding for'
  'arrived during the drain turn'
  'no new message since the block'
  'BLOCKED_IDS'
  'AUTO_SUBMIT=1'
  'refusing to wipe'
)

# Print the runbook block (heading through EOF) of a workflow doc.
runbook_block() {
  sed -n '/^### When radio misbehaves$/,$p' "$1"
}

@test "the README carries the runbook with all five symptoms" {
  run cat "$REPO_ROOT_REAL/README.md"
  assert_success
  assert_output --partial "### When radio misbehaves"
  assert_output --partial "I pinged the worker and nothing happened."
  assert_output --partial "sitting unsubmitted in its prompt box."
  assert_output --partial "A role keeps disappearing from"
  assert_output --partial "I ran \`radio unregister\` and nothing happened."
  assert_output --partial "idling for a message that's in its own inbox."
  # The four sub-sections the ticket asks for.
  assert_output --partial "#### Symptom → cause → check"
  assert_output --partial "#### Reading the log"
  assert_output --partial "#### What \`radio unregister\` does, and doesn't"
  assert_output --partial "#### Undelivered mail is never dropped"
}

@test "every workflow doc carries the runbook section" {
  for f in "${CLAUDE_TEMPLATES[@]}" "${KIRO_TEMPLATES[@]}" "$REPO_ROOT_REAL/.claude/gh-workflow.md"; do
    assert [ -f "$f" ]
    run grep -qFx '### When radio misbehaves' "$f"
    assert_success
  done
}

@test "the runbook block is byte-identical across the claude templates and the dogfood copy" {
  local ref
  ref=$(runbook_block "${CLAUDE_TEMPLATES[0]}")
  assert [ -n "$ref" ]
  for f in "${CLAUDE_TEMPLATES[@]}" "$REPO_ROOT_REAL/.claude/gh-workflow.md"; do
    run runbook_block "$f"
    assert_success
    assert_output "$ref"
  done
}

@test "the runbook block is byte-identical across the kiro templates" {
  local ref
  ref=$(runbook_block "${KIRO_TEMPLATES[0]}")
  assert [ -n "$ref" ]
  for f in "${KIRO_TEMPLATES[@]}"; do
    run runbook_block "$f"
    assert_success
    assert_output "$ref"
  done
}

@test "every log string the runbook greps for exists in bin/radio" {
  # The anti-rot test: rename a log line in bin/radio and this fails rather
  # than leaving the runbook quietly pointing at nothing.
  for s in "${DOCUMENTED_GREPS[@]}"; do
    run grep -cF -- "$s" "$REPO_ROOT_REAL/bin/radio"
    assert_success
    refute_output "0"
  done
}

@test "the documented log greps are the ones the README and templates actually print" {
  # Each fragment must also appear in the docs — otherwise DOCUMENTED_GREPS
  # drifts into a list of strings nobody is told to search for.
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_TEMPLATES[0]}" "${KIRO_TEMPLATES[0]}"; do
    for s in 'unregister role=' 'unregister: proceeding' 'unregister: skipping' \
             'tab_id_src=' 'no tab binding for' 'arrived during the drain turn' \
             'BLOCKED_IDS' 'AUTO_SUBMIT=1'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
}

@test "loadout=unknown is a real re-seed outcome, not an invented grep" {
  # Assembled at runtime: the sidecar read falls back to ${TASK_FORCE_LOADOUT:-unknown}
  # and the re-seed line prints `loadout=$loadout`, so the literal string only
  # ever appears in the log.
  run grep -cF -- ':-unknown}' "$REPO_ROOT_REAL/bin/radio"
  assert_success
  refute_output "0"
  run grep -cF -- 'loadout=$loadout' "$REPO_ROOT_REAL/bin/radio"
  assert_success
  refute_output "0"
}

@test "the runbook stays loadout-generic (#177)" {
  # It ships verbatim into gh / jira / notion / local repos, so it must not
  # name one tracker's tooling.
  for f in "${CLAUDE_TEMPLATES[@]}" "${KIRO_TEMPLATES[@]}"; do
    local block
    block=$(runbook_block "$f")
    run grep -icE 'github|notion|jira|gh cli|task-board' <<<"$block"
    assert_output "0"
  done
}

@test "the kiro runbook promises no claude backstop and names the poll instead" {
  for f in "${KIRO_TEMPLATES[@]}"; do
    local block
    block=$(runbook_block "$f")
    # Same promise phrasings #190 banned from kiro docs.
    run grep -cE 'drain on its next Stop|surface via prompt-hook|injects (a summary|the inbox)' <<<"$block"
    assert_output "0"
    # …and the honest replacement.
    run grep -cF 'the zellij keystroke is the' <<<"$block"
    refute_output "0"
    run grep -cF 'standing `radio check` at the top of every turn' <<<"$block"
    refute_output "0"
  done
}

@test "no kiro doc tells the reader to relaunch a worker with task-work --auto" {
  # kiro's task-work parses no --auto flag, so AUTO_MODE is never set and
  # TASK_FORCE_AUTO_SUBMIT is never injected for a kiro worker. Advising it
  # would send a reader after a flag that does not exist.
  run grep -c 'AUTO_MODE=' "$REPO_ROOT_REAL/kiro-gh/bin/task-work"
  assert_output "0"
  for f in "${KIRO_TEMPLATES[@]}"; do
    run grep -cF 'task-work --auto' "$f"
    assert_output "0"
  done
}

@test "the claude runbook keeps the three backstops it is allowed to promise" {
  for f in "${CLAUDE_TEMPLATES[@]}"; do
    local block
    block=$(runbook_block "$f")
    assert [ -n "$block" ]
    run grep -cF '`Stop` hook' <<<"$block"
    refute_output "0"
    run grep -cF '`UserPromptSubmit` hook' <<<"$block"
    refute_output "0"
    run grep -cF '`SessionStart` register' <<<"$block"
    refute_output "0"
  done
}

@test "the runbook states that undelivered mail is never deleted" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_TEMPLATES[@]}" "${KIRO_TEMPLATES[@]}"; do
    run grep -cF 'dead-letter queue' "$f"
    assert_success
    refute_output "0"
  done
  # And bin/radio backs the claim: gc's whole-dir reclaim is gated on an
  # empty inbox, and only processed/ is swept by TTL.
  run grep -cF '_inbox_empty' "$REPO_ROOT_REAL/bin/radio"
  assert_success
  refute_output "0"
}
