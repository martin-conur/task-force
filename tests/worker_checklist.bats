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

# Extract the checklist block (from the "Pre-PR checklist" line through the
# "Green" bullet) from a worker.md file.
checklist_block() {
  awk '/^\*\*Pre-PR checklist\*\*/{p=1} p{print} /^- \*\*Green\*\*/{if(p)exit}' "$1"
}

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
