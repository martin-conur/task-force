#!/usr/bin/env bats
# The workflow docs' radio and reviewer sections are cut to the core (#399,
# epic #395). Every role loads the workflow doc on every turn, so it keeps only
# what every role needs: the intents each role sends, the `radio send` form and
# the stdin rule. The PM's side of radio moved into the PM prompts, the
# reviewer's contract was already in the reviewer prompts, and how radio keeps,
# recovers and cleans up sessions moved into the radio-troubleshooting skill.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

KIRO_DOCS=(
  "$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
)

PM_PROMPTS=(
  "$REPO_ROOT_REAL/.claude/commands/pm.md"
  "$REPO_ROOT_REAL/claude-gh/commands/pm.md"
  "$REPO_ROOT_REAL/claude-jira/commands/pm.md"
  "$REPO_ROOT_REAL/claude-local/commands/pm.md"
  "$REPO_ROOT_REAL/claude-notion/commands/pm.md"
  "$REPO_ROOT_REAL/kiro-gh/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-local/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/pm.json"
)

SKILLS=(
  "$REPO_ROOT_REAL/skills/claude/radio-troubleshooting/SKILL.md"
  "$REPO_ROOT_REAL/skills/kiro/radio-troubleshooting/SKILL.md"
  "$REPO_ROOT_REAL/.claude/skills/radio-troubleshooting/SKILL.md"
)

# Every intent some role sends on every loadout.
INTENTS=(
  spec-ready review-requested re-review-requested changes-requested
  approved-and-merged review-complete-clean review-complete-with-findings
)

# A sample from each part of the text that left the workflow doc, so a partial
# paste-back fails too.
MOVED=(
  '### Reviewer role'
  'derives the role from disk'
  'soft cache, not the source of truth'
  'auto-submit on|off|status'
  'task-pm --also <other-repo>'
  'Pass `task-pm --auto-submit`'
  'radio gc --dry-run'
  'radio register --role <role> --tab <tabname>'
  'mailbox and log self-prune'
  'is not a cleanup command'
)

radio_section() {
  awk '/^### PM ↔ worker messaging \(radio\)$/{p=1; print; next} p&&/^##+ /{exit} p{print}' "$1"
}

prompt_text() {
  case "$1" in
    *.json) jq -r '.prompt' "$1" ;;
    *)      cat "$1" ;;
  esac
}

@test "the radio section is under 6 KB in every workflow doc" {
  local doc bytes
  for doc in "${WORKFLOW_DOCS[@]}"; do
    bytes=$(radio_section "$doc" | wc -c | tr -d ' ')
    [ "$bytes" -gt 0 ] || { echo "no radio section in $doc"; return 1; }
    [ "$bytes" -lt 6144 ] || { echo "$doc: radio section is $bytes bytes"; return 1; }
  done
}

@test "no workflow doc carries the reviewer section or the PM and session internals" {
  local doc s
  for doc in "${WORKFLOW_DOCS[@]}"; do
    for s in "${MOVED[@]}"; do
      run grep -cF -- "$s" "$doc"
      assert_output "0"
    done
  done
}

@test "every workflow doc keeps the core: each intent, the send form and the stdin rule" {
  local doc i section
  for doc in "${WORKFLOW_DOCS[@]}"; do
    section=$(radio_section "$doc")
    for i in "${INTENTS[@]}"; do
      grep -qF -- "--intent $i " <<<"$section" || grep -qF -- "--intent $i\`" <<<"$section" \
        || { echo "no $i row in $doc"; return 1; }
    done
    grep -qF 'radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]' <<<"$section" \
      || { echo "no send form in $doc"; return 1; }
    grep -qF 'never through a double-quoted shell' <<<"$section" \
      || { echo "no stdin rule in $doc"; return 1; }
    grep -qF 'radio-troubleshooting' <<<"$section" \
      || { echo "no pointer to the skill in $doc"; return 1; }
  done
}

@test "claude workflow docs keep the prompt-hook line as the radio channel" {
  local doc
  for doc in "${WORKFLOW_DOCS[@]}"; do
    case "$doc" in */kiro-*) continue ;; esac
    radio_section "$doc" | grep -qF '[radio] 2 unread message(s)' \
      || { echo "no prompt-hook line in $doc"; return 1; }
  done
}

@test "the Tight-PR norm keeps its norm and loses the radio cleanup paragraphs" {
  local doc
  for doc in "${WORKFLOW_DOCS[@]}"; do
    case "$doc" in */kiro-*) continue ;; esac
    grep -qF 'Default to landing each PR **complete**' "$doc" \
      || { echo "Tight-PR norm gone from $doc"; return 1; }
    run grep -cF 'LAST_HEARTBEAT' "$doc"
    assert_output "0"
  done
}

@test "every PM prompt carries the PM's side of radio" {
  local f text
  for f in "${PM_PROMPTS[@]}"; do
    text=$(prompt_text "$f")
    for s in '<!-- region:pm-radio-protocol -->' 'task-pm --also <other-repo>' \
             'task-pm --auto-submit' 'reviewed <sha>' 'never clean' 'radio-troubleshooting'; do
      grep -qF -- "$s" <<<"$text" || { echo "no '$s' in $f"; return 1; }
    done
  done
}

@test "every PM prompt dispatches reviewers and expects them to self-destruct" {
  local f text
  for f in "${PM_PROMPTS[@]}"; do
    text=$(prompt_text "$f")
    grep -qF 'task-reviewer <pr-url-or-number>' <<<"$text" \
      || { echo "no reviewer dispatch in $f"; return 1; }
    grep -qF 'task-done --remove-worktree' <<<"$text" \
      || { echo "no self-destruct in $f"; return 1; }
    # kiro-gh's said this until #399, long after #320 made the kiro reviewer self-destruct.
    run grep -cF 'The reviewer tab stays open' <<<"$text"
    assert_output "0"
  done
}

@test "the skill carries the session internals that left the workflow doc" {
  local f s
  for f in "${SKILLS[@]}"; do
    for s in '<!-- region:radio-internals -->' 'derives the role from disk' \
             'The session file is a soft cache' 'radio register --role <role> --tab <tabname>' \
             '--agent <claude|kiro>' 'task-recreate-worker' 'Literal-`pm` adoption' \
             'radio orphans' 'radio gc --dry-run' 'is not' '$TASK_FORCE_HOME' \
             'AUTO_SUBMIT_UNTIL='; do
      grep -qF -- "$s" "$f" || { echo "no '$s' in $f"; return 1; }
    done
  done
}

@test "the kiro skill keeps kiro's hook location and routine orphan cleanup" {
  local f="$REPO_ROOT_REAL/skills/kiro/radio-troubleshooting/SKILL.md"
  for s in '.kiro/hooks/' 'no session-end trigger' 'routine housekeeping' 'postToolUse'; do
    grep -qF -- "$s" "$f" || { echo "no '$s' in $f"; return 1; }
  done
  run grep -cF 'Kiro discards hook' "$f"
  assert_output "0"
}

@test "every kiro workflow doc lists the reviewer intents" {
  local doc
  for doc in "${KIRO_DOCS[@]}"; do
    radio_section "$doc" | grep -qE '^\| Reviewer +\|' \
      || { echo "no Reviewer row in $doc"; return 1; }
  done
}
