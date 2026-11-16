#!/usr/bin/env bats
# The "When radio misbehaves" runbook (#191), an on-demand skill since #398.
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

# Only the #206 test builds a repo; teardown_all skips whatever was never set.
teardown() {
  teardown_all
}

# Since #398 the runbook is the radio-troubleshooting skill, not a section of
# the workflow doc: one shipped copy per assistant, plus this repo's installed
# (dogfood) copy of the claude one.
CLAUDE_SKILLS=(
  "$REPO_ROOT_REAL/skills/claude/radio-troubleshooting/SKILL.md"
  "$REPO_ROOT_REAL/.claude/skills/radio-troubleshooting/SKILL.md"
)

KIRO_SKILLS=(
  "$REPO_ROOT_REAL/skills/kiro/radio-troubleshooting/SKILL.md"
)

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
  'gc: dead-lettered'
  'BLOCKED_IDS'
  'AUTO_SUBMIT=1'
  'refusing to wipe'
  'recover-role:'
  'register: no-op'
  'waking anyway'
  'hook-noop:'
  'zellij-timeout:'
)

# Print the runbook block of a skill: everything below its frontmatter.
runbook_block() {
  awk 'n >= 2 { print } /^---$/ { n++ }' "$1"
}

# The strings an agent sees that the skill's description is keyed to (#398),
# so the skill loads on the output itself rather than on a paraphrase of it.
DESCRIPTION_KEYS=(
  'WARNING — no session for'
  'wake failed'
  'looks dead'
  'no tab id captured'
  'timed out after 30s'
)

@test "the README carries the runbook with all seven symptoms" {
  run cat "$REPO_ROOT_REAL/README.md"
  assert_success
  assert_output --partial "### When radio misbehaves"
  assert_output --partial "I pinged the worker and nothing happened."
  assert_output --partial "sitting unsubmitted in its prompt box."
  assert_output --partial "A role keeps disappearing from"
  assert_output --partial "I ran \`radio unregister\` and nothing happened."
  assert_output --partial "never cleaned up its worktree."
  assert_output --partial "idling for a message that's in its own inbox."
  # #229: a roleless session — the silent-`check` / `from: unknown` pair.
  assert_output --partial "says nothing, but mail is in the inbox"
  # The four sub-sections the ticket asks for.
  assert_output --partial "#### Symptom → cause → check"
  assert_output --partial "#### Reading the log"
  assert_output --partial "#### What \`radio unregister\` does, and doesn't"
  assert_output --partial "#### Undelivered mail is never deleted"
}

@test "no workflow doc carries the runbook any more (#398)" {
  # The point of the move: ~15 KB nobody needs until radio breaks, out of the
  # doc every role loads on every turn.
  for f in "${CLAUDE_TEMPLATES[@]}" "${KIRO_TEMPLATES[@]}" "$REPO_ROOT_REAL/.claude/gh-workflow.md"; do
    assert [ -f "$f" ]
    run grep -cF 'When radio misbehaves' "$f"
    assert_output "0"
    # A sample from each part of the old section, so a partial paste-back fails too.
    for s in '| Symptom | Cause and check |' 'grep -c '"'"'send id='"'"' "$L"' 'archive, not a delete'; do
      run grep -cF -- "$s" "$f"
      assert_output "0"
    done
  done
}

@test "every workflow doc keeps the rule that says when to load the skill (#398)" {
  local f
  for f in "${CLAUDE_TEMPLATES[@]}" "${KIRO_TEMPLATES[@]}" "$REPO_ROOT_REAL/.claude/gh-workflow.md"; do
    run grep -qFx '### Radio troubleshooting' "$f"
    assert_success
    for s in "Read \`radio send\`'s stdout every time" '`delivered`' 'is awaiting' \
             'radio-troubleshooting' "${DESCRIPTION_KEYS[@]}"; do
      # Joined to one line: the rule is wrapped prose, and a key can straddle a break.
      run grep -cF -- "$s" <<<"$(sed -n '/^### Radio troubleshooting$/,/^#\{1,3\} /p' "$f" \
                                  | sed '/<!-- task-init:managed:end -->/,$d' | tr '\n' ' ')"
      refute_output "0"
    done
  done
  # Each points at its own assistant's install path.
  for f in "${CLAUDE_TEMPLATES[@]}" "$REPO_ROOT_REAL/.claude/gh-workflow.md"; do
    run grep -cF '.claude/skills/radio-troubleshooting/SKILL.md' "$f"
    refute_output "0"
  done
  for f in "${KIRO_TEMPLATES[@]}"; do
    run grep -cF '.kiro/skills/radio-troubleshooting/SKILL.md' "$f"
    refute_output "0"
  done
}

@test "the skill's frontmatter names it and keys its description to radio's output (#398)" {
  local f desc
  for f in "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    run sed -n '1p' "$f"
    assert_output "---"
    run grep -cFx 'name: radio-troubleshooting' "$f"
    assert_output "1"
    desc=$(grep '^description: ' "$f")
    assert [ -n "$desc" ]
    for s in "${DESCRIPTION_KEYS[@]}"; do
      run grep -cF -- "$s" <<<"$desc"
      assert_output "1"
    done
  done
}

@test "the description keys are strings radio, task-done or Claude Code actually print (#398)" {
  run grep -cF 'radio: WARNING — no session for' "$REPO_ROOT_REAL/bin/radio"
  refute_output "0"
  run grep -cF 'is idle but wake failed' "$REPO_ROOT_REAL/bin/radio"
  refute_output "0"
  run grep -cF 'radio: WARNING — %s looks dead' "$REPO_ROOT_REAL/bin/radio"
  refute_output "0"
  run grep -cF '(no tab id captured;' "$REPO_ROOT_REAL/bin/task-done"
  refute_output "0"
  # `timed out after 30s` is Claude Code's hook-timeout message, quoted in the
  # runbook's own zellij-stall row.
  run grep -cF 'timed out after 30s — output discarded' "${CLAUDE_SKILLS[0]}"
  refute_output "0"
}

@test "the claude skill is byte-identical in its shipped and dogfood copies" {
  run cmp "${CLAUDE_SKILLS[0]}" "${CLAUDE_SKILLS[1]}"
  assert_success
}

@test "the runbook body is shared by the claude and kiro skills (#398)" {
  # Only the closing paragraphs differ; everything inside the drift region is
  # one text, so a row fixed for one assistant is fixed for both.
  run "$REPO_ROOT_REAL/tools/check-drift.sh"
  assert_success
  local region='/^<!-- region:radio-troubleshooting-body -->$/,/^<!-- endregion:radio-troubleshooting-body -->$/p'
  local ref
  ref=$(sed -n "$region" "${CLAUDE_SKILLS[0]}")
  assert [ -n "$ref" ]
  run sed -n "$region" "${KIRO_SKILLS[0]}"
  assert_output "$ref"
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
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    for s in 'unregister role=' 'unregister: proceeding' 'unregister: skipping' \
             'tab_id_src=' 'no tab binding for' 'arrived during the drain turn' \
             'BLOCKED_IDS' 'AUTO_SUBMIT=1' 'gc: dead-lettered'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
}

@test "the roleless-session row is in the README and every workflow doc (#229)" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    run grep -cF -- 'recover-role:' "$f"
    assert_success
    refute_output "0"
    run grep -cF -- 'register: no-op' "$f"
    assert_success
    refute_output "0"
  done
}

@test "the frozen-heartbeat kiro row is in the README and every workflow doc (#370)" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    for s in 'waking anyway' 'hook-noop:' 'ContextualHookInvoked' 'kiro-cli agent upgrade .kiro/agents'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
}

@test "the stuck-busy kiro row is in the README and every workflow doc (#322)" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    for s in 'TASK_FORCE_KIRO_BUSY_STALE_SECS' 'radio heartbeat' 'but its tab is still open — kiro, waking anyway' '▶? busy?'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
  # The log line the row quotes is the one radio writes.
  run grep -cF 'no hook for ${age}s) but its tab is still open — kiro, waking anyway' "$REPO_ROOT_REAL/bin/radio"
  refute_output "0"
}

@test "the tab-close reap row is in the README and every workflow doc (#388)" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    for s in "grep 'reap:' ~/.task-force/radio/log" 'bin/agent-supervise' 'reap: nothing left' 'reap: failed' 'reap: skipped'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
  # The outcomes the row names are the ones the supervisor logs.
  for s in 'reap: nothing left in' 'reap: $status ' 'status=failed' 'reap: skipped, '; do
    run grep -cF -- "$s" "$REPO_ROOT_REAL/bin/agent-supervise"
    refute_output "0"
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

@test "the flapping row names --manual as a cause, not just an old binary" {
  # `--manual` short-circuits the block that emits BOTH the skipping and
  # proceeding lines, so it writes only `unregister role=`. A runbook that
  # attributes a role=/proceeding gap solely to a stale binary misdiagnoses
  # the case that actually occurs (#205: an unisolated test suite looping
  # `radio unregister --manual` against the developer's live role).
  run grep -cE 'if \[\[ "\$manual" != true \]\]' "$REPO_ROOT_REAL/bin/radio"
  assert_success
  refute_output "0"
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    local block
    block=$(runbook_block "$f")
    [[ "$f" == *README.md ]] && block=$(sed -n '/^### When radio misbehaves$/,/^## /p' "$f")
    run grep -cF 'it writes only `role=`' <<<"$block"
    refute_output "0"
    run grep -cF 'old `radio` binary' <<<"$block"
    refute_output "0"
  done
}

@test "the runbook stays loadout-generic (#177)" {
  # It ships verbatim into gh / jira / notion / local repos, so it must not
  # name one tracker's tooling.
  for f in "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    local block
    block=$(runbook_block "$f")
    run grep -icE 'github|notion|jira|gh cli|task-board' <<<"$block"
    assert_output "0"
  done
}

@test "the kiro runbook promises no claude backstop and names the poll instead" {
  for f in "${KIRO_SKILLS[@]}"; do
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

@test "the kiro runbook advises plain task-work, which auto-submits (#206, #254)" {
  # #206 added --auto to kiro's task-work so the runbook could advise it; #254
  # made auto-submit every launch's default, so the advice is now the plain
  # command. This pins both halves together so a doc recommending a plain
  # launch can never outlive the default that makes it work: a plain launch on
  # every kiro loadout must inject the auto-submit opt-in, and --no-auto-submit
  # must turn it off.
  setup_repo
  setup_kiro_agents
  setup_stubs
  mkdir -p "$MAIN_REPO/tasks"
  local impl SUPERVISE
  # The kiro command runs under the tab-close reaper (#388).
  SUPERVISE="$(cd "$REPO_ROOT_REAL" && pwd -P)/bin/agent-supervise"
  for impl in $(bash -c "source '$REPO_ROOT_REAL/lib/detect-impl.sh'; aw_all_impls" | grep '^kiro-'); do
    : > "$STUB_CALLS_DIR/zellij.calls"
    run bash -c "cd '$MAIN_REPO' && AW_IMPL=$impl '$REPO_ROOT_REAL/bin/task-work' 'plain-$impl' --no-task"
    assert_success
    assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1 $SUPERVISE kiro-cli"
    : > "$STUB_CALLS_DIR/zellij.calls"
    run bash -c "cd '$MAIN_REPO' && AW_IMPL=$impl '$REPO_ROOT_REAL/bin/task-work' 'off-$impl' --no-auto-submit --no-task"
    assert_success
    assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=0 $SUPERVISE kiro-cli"
  done
  for f in "${KIRO_SKILLS[@]}"; do
    run grep -cF 'Relaunch it with plain `task-work`' "$f"
    refute_output "0"
  done
}

@test "the kiro runbook keeps auto-submit apart from permissions (#206)" {
  # kiro's permission model is -a/--trust-all and is deliberately separate;
  # a reader must not take auto-submit for a trust-all synonym.
  for f in "${KIRO_SKILLS[@]}"; do
    local block
    block=$(runbook_block "$f")
    run grep -cF 'independent of the permission model' <<<"$block"
    refute_output "0"
    run grep -cF '`-a/--trust-all`' <<<"$block"
    refute_output "0"
  done
}

@test "the claude runbook keeps the three backstops it is allowed to promise" {
  for f in "${CLAUDE_SKILLS[@]}"; do
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

@test "the runbook states that undelivered mail is never deleted, and names dead-letter/" {
  # #201 replaced the "there is no dead-letter queue" claim with one: the
  # promise that survives is that nothing unread is ever deleted, only moved.
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    run grep -cF 'Undelivered mail is never deleted' "$f"
    assert_success
    refute_output "0"
    run grep -cF '~/.task-force/radio/dead-letter/' "$f"
    assert_success
    refute_output "0"
    run grep -cF 'archive, not a delete' "$f"
    assert_success
    refute_output "0"
    # The stale claim must be gone everywhere, or the docs contradict the code.
    run grep -cF 'no dead-letter queue' "$f"
    assert_output "0"
  done
  # And bin/radio backs both halves: a live role's inbox is still gated by
  # _inbox_empty, and the dead-role path archives rather than removes.
  for s in '_inbox_empty' '_dead_letter_inbox' 'DEAD_LETTER_DIR'; do
    run grep -cF -- "$s" "$REPO_ROOT_REAL/bin/radio"
    assert_success
    refute_output "0"
  done
}

@test "the missed-tab-id row greps a string lib/zellij-tab.sh actually logs (#242)" {
  # `tab-id:` is written by aw_record_tab_id, not bin/radio, so it sits outside
  # DOCUMENTED_GREPS — pinned here against the file that emits it. Since #260 it
  # goes through aw_radio_log, which supplies the timestamp and the space, so
  # the literal is the opening of the message string.
  run grep -cF -- "\"\$(printf 'tab-id: " "$REPO_ROOT_REAL/lib/zellij-tab.sh"
  assert_success
  refute_output "0"
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    run grep -cF -- "grep 'tab-id:'" "$f"
    assert_success
    refute_output "0"
  done
}

@test "the zellij-stall row is in the README and every workflow doc (#384)" {
  for f in "$REPO_ROOT_REAL/README.md" "${CLAUDE_SKILLS[@]}" "${KIRO_SKILLS[@]}"; do
    for s in 'zellij-timeout:' 'TASK_FORCE_ZELLIJ_TIMEOUT' 'list-tabs unusable after' 'late_steal=1'; do
      run grep -cF -- "$s" "$f"
      assert_success
      refute_output "0"
    done
  done
  # The snap-back's own log strings live in lib/zellij-tab.sh, not bin/radio.
  for s in 'list-tabs unusable after' 'late_steal=1' 'zellij-timeout:'; do
    run grep -cF -- "$s" "$REPO_ROOT_REAL/lib/zellij-tab.sh"
    assert_success
    refute_output "0"
  done
}
