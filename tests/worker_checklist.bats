#!/usr/bin/env bats
# Tests for the /worker pre-PR checklist (#176).
#
# The checklist ships downstream verbatim via `task-init` (it is copied into an
# arbitrary user repo's .claude/commands/), so it must stay repo-generic: no
# file paths that only exist in this repo, and no bare issue-number citations
# (which would resolve to the *downstream* repo's own PRs). The task-force
# specifics live in .claude/gh-workflow.md instead. These tests guard both the
# generic invariant and the dogfood copy.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# Shipped claude worker prompts (installed downstream by task-init).
SHIPPED_WORKERS=(
  "$REPO_ROOT_REAL/claude-gh/commands/worker.md"
  "$REPO_ROOT_REAL/claude-jira/commands/worker.md"
  "$REPO_ROOT_REAL/claude-notion/commands/worker.md"
  "$REPO_ROOT_REAL/claude-local/commands/worker.md"
)

# Extract the checklist block (from the "Pre-PR checklist" line up to the
# numbered step that follows it) from a worker.md file. The window deliberately
# runs past the "Green" bullet so its fenced proof-of-run command is compared
# across loadouts too (#194) rather than drifting unwatched.
checklist_block() {
  awk '/^\*\*Pre-PR checklist\*\*/{p=1} p&&/^[0-9]+\. /{exit} p{print}' "$1"
}

# All 8 shipped worker prompts: the 5 claude markdown copies (incl. the
# dogfood one) plus the 3 kiro agent definitions, whose prompt lives in a JSON
# field. Printing them through one accessor keeps the #194 assertions below
# loadout-shaped rather than format-shaped.
worker_prompt() {
  case "$1" in
    *.json) python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prompt"])' "$1" ;;
    *)      cat "$1" ;;
  esac
}

ALL_WORKER_PROMPTS=(
  "$REPO_ROOT_REAL/.claude/commands/worker.md"
  "$REPO_ROOT_REAL/claude-gh/commands/worker.md"
  "$REPO_ROOT_REAL/claude-jira/commands/worker.md"
  "$REPO_ROOT_REAL/claude-notion/commands/worker.md"
  "$REPO_ROOT_REAL/claude-local/commands/worker.md"
  "$REPO_ROOT_REAL/kiro-gh/agents/worker.json"
  "$REPO_ROOT_REAL/kiro-local/agents/worker.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/worker.json"
)

@test "every shipped claude worker.md carries a pre-PR checklist" {
  for f in "${SHIPPED_WORKERS[@]}"; do
    run grep -q '^\*\*Pre-PR checklist\*\*' "$f"
    assert_success
  done
}

@test ".claude/commands/worker.md is byte-identical to claude-gh (dogfood parity)" {
  run cmp "$REPO_ROOT_REAL/.claude/commands/worker.md" "$REPO_ROOT_REAL/claude-gh/commands/worker.md"
  assert_success
}

@test "checklist block is byte-identical across gh / jira / notion loadouts" {
  ref=$(checklist_block "$REPO_ROOT_REAL/claude-gh/commands/worker.md")
  for lo in claude-jira claude-notion; do
    other=$(checklist_block "$REPO_ROOT_REAL/$lo/commands/worker.md")
    [ "$ref" = "$other" ]
  done
}

@test "shipped checklist stays repo-generic: no task-force-only file paths" {
  # tools/check-drift.sh and steering/*.example.md do not exist in a downstream
  # user repo — referencing them in the shipped prompt would strand workers.
  for f in "${SHIPPED_WORKERS[@]}"; do
    block=$(checklist_block "$f")
    run grep -qE 'check-drift|steering/\*|task-init' <<<"$block"
    assert_failure
  done
}

@test "shipped checklist stays repo-generic: no bare issue-number citations" {
  # A bare #NNN resolves to the downstream repo's own PRs — never cite them in
  # the shipped prompt. Repo-specific evidence lives in .claude/gh-workflow.md.
  for f in "${SHIPPED_WORKERS[@]}"; do
    block=$(checklist_block "$f")
    run grep -qE '#[0-9]+' <<<"$block"
    assert_failure
  done
}

@test "claude-local adapts the spec item to its file-based specs (no comments)" {
  # claude-local specs are plain tasks/NNN-slug.md files with no comment facility.
  run grep -q 'notes below the frontmatter' "$REPO_ROOT_REAL/claude-local/commands/worker.md"
  assert_success
}

@test "this repo's gh-workflow.md carries the task-force-specific gloss" {
  run grep -q 'Pre-PR checklist (this repo)' "$REPO_ROOT_REAL/.claude/gh-workflow.md"
  assert_success
}

# --- #194: CI-skip markers and the empty-check-list caveat -------------------

@test "all 8 worker prompts warn against a literal CI-skip marker" {
  # GitHub reads the whole commit message, so quoting a marker while
  # *describing* another commit suppresses your own run. Two workers hit this
  # in one hour; the second was explaining the first.
  for f in "${ALL_WORKER_PROMPTS[@]}"; do
    run worker_prompt "$f"
    assert_success
    [[ "$output" == *"CI-skip marker"* ]] || { echo "no marker warning in $f"; return 1; }
    [[ "$output" == *"skip-ci"* ]] || { echo "no escape hatch in $f"; return 1; }
  done
}

@test "all 8 worker prompts treat an empty check list as not-green" {
  # "Did CI pass" cannot catch a suppressed run — there is nothing to check.
  # Only "does a run exist for this exact SHA" can.
  for f in "${ALL_WORKER_PROMPTS[@]}"; do
    run worker_prompt "$f"
    assert_success
    [[ "$output" == *"empty check list is not a pass"* ]] || { echo "no empty-list caveat in $f"; return 1; }
    [[ "$output" == *"gh run list -c"* ]] || { echo "no proof-of-run command in $f"; return 1; }
  done
}

@test "all 5 reviewer prompts apply the same empty-vs-passing distinction" {
  # A reviewer that cross-checks "CI green" off an empty list repeats the bug
  # at one remove.
  local reviewers=(
    "$REPO_ROOT_REAL/.claude/commands/reviewer.md"
    "$REPO_ROOT_REAL/claude-gh/commands/reviewer.md"
    "$REPO_ROOT_REAL/claude-jira/commands/reviewer.md"
    "$REPO_ROOT_REAL/claude-notion/commands/reviewer.md"
    "$REPO_ROOT_REAL/claude-local/commands/reviewer.md"
    "$REPO_ROOT_REAL/kiro-gh/agents/reviewer.json"
  )
  for f in "${reviewers[@]}"; do
    run worker_prompt "$f"
    assert_success
    [[ "$output" == *"empty check list is not a pass"* ]] || { echo "no empty-list caveat in $f"; return 1; }
    [[ "$output" == *"headRefOid"* ]] || { echo "no head-SHA run check in $f"; return 1; }
  done
}

@test "the #194 checklist bullets stay byte-identical across gh / jira / notion" {
  # Covered by the block comparison above, but pinned explicitly: these two
  # bullets are the ones a future edit is most likely to fix in one copy only.
  for bullet in '- \*\*CI markers\*\*' '- \*\*Green\*\*'; do
    ref=$(grep -E "^$bullet" "$REPO_ROOT_REAL/claude-gh/commands/worker.md")
    for lo in claude-jira claude-notion claude-local; do
      other=$(grep -E "^$bullet" "$REPO_ROOT_REAL/$lo/commands/worker.md")
      [ "$ref" = "$other" ] || { echo "$lo diverges on $bullet"; return 1; }
    done
  done
}
