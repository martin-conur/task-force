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

# --- PR body opens with ## Summary -------------------------------------------
#
# The PR body's `## Summary` is what a human reads once a ticket number no
# longer means anything, and the monitor's Done section parses it. Every
# shipped worker prompt must ask for it first, on stdin, with the tracker's own
# `Closes` line after it; every reviewer must flag its absence as a nit.

# The tracker each worker prompt closes against, keyed by file.
closes_line_for() {
  case "$1" in
    *claude-jira/*)                      echo 'Closes <ISSUE-KEY>' ;;
    *claude-notion/*|*kiro-notion/*)     echo 'Closes <Notion page URL>' ;;
    *claude-local/*|*kiro-local/*)       echo 'Closes tasks/<NNN-slug>.md' ;;
    *)                                   echo 'Closes #<N>' ;;
  esac
}

@test "all 8 worker prompts open the PR body with ## Summary, then Closes" {
  for f in "${ALL_WORKER_PROMPTS[@]}"; do
    run worker_prompt "$f"
    assert_success
    [[ "$output" == *"--fill --body-file - <<'BODY'"* ]] || { echo "no stdin body in $f"; return 1; }
    [[ "$output" == *"must open with \`## Summary\`"* ]] || { echo "no Summary rule in $f"; return 1; }
    [[ "$output" == *"written for the user rather than a reviewer"* ]] || { echo "no audience in $f"; return 1; }
    # The example body: ## Summary is its first line, the Closes line follows.
    body=$(awk "/<<'BODY'\$/ && /gh pr create/{p=1; next} p && /^ *BODY\$/{exit} p{sub(/^ +/, \"\"); print}" <<<"$output")
    [ "$(head -1 <<<"$body")" = '## Summary' ] || { echo "body does not open with ## Summary in $f: $body"; return 1; }
    closes=$(closes_line_for "$f")
    grep -qxF "$closes" <<<"$body" || { echo "no '$closes' in $f: $body"; return 1; }
  done
}

@test "no worker prompt still relies on --fill alone for the PR body" {
  # A bare --fill takes the body from commit messages, which never carry a
  # ## Summary written for the user.
  for f in "${ALL_WORKER_PROMPTS[@]}"; do
    run worker_prompt "$f"
    assert_success
    [[ "$output" != *"HEAD) --fill\`"* && "$output" != *"HEAD) --fill"$'\n'* ]] || { echo "bare --fill in $f"; return 1; }
  done
}

@test "the ## Summary rule is byte-identical across the claude worker prompts" {
  ref=$(grep -F 'must open with `## Summary`' "$REPO_ROOT_REAL/claude-gh/commands/worker.md")
  [ -n "$ref" ]
  for lo in claude-jira claude-notion claude-local; do
    other=$(grep -F 'must open with `## Summary`' "$REPO_ROOT_REAL/$lo/commands/worker.md")
    [ "$ref" = "$other" ] || { echo "$lo diverges"; return 1; }
  done
}

@test "all reviewer prompts treat a missing ## Summary as a nit" {
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
    line=$(grep -F 'does not open with `## Summary`' <<<"$output")
    [ -n "$line" ] || { echo "no Summary check in $f"; return 1; }
    [[ "$line" == *"nit"* && "$line" == *"never blocks"* ]] || { echo "not a nit in $f: $line"; return 1; }
  done
}

@test "every workflow doc and the README describe the ## Summary convention" {
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
  for f in "${docs[@]}"; do
    run grep -q '^### PR Body$' "$f"
    assert_success
    run grep -qF 'The worker opens every PR body with `## Summary`' "$f"
    assert_success
  done
  run grep -qF 'The body always opens with `## Summary`, on every loadout.' "$REPO_ROOT_REAL/README.md"
  assert_success
}
