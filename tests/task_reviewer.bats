#!/usr/bin/env bats
# Tests for bin/task-reviewer: dispatch-style PR reviewer (#138).
#
# task-reviewer was redesigned from a long-lived listener-tab (rename-tab
# in-place, no args) into a per-PR dispatch worker — fresh worktree on the
# PR's head ref, new zellij tab, claude (or kiro) launched with the PR (and
# optional spec issue) as args. Tests mirror tests/claude_gh_task_work.bats's
# patterns: arg parsing, worktree creation, tab spawn, mode flags, errors.
#
# `gh pr view` is stubbed via $GH_STUB_PR_URL (+ optional PR_BODY/HEAD/BASE
# overrides). With $GH_STUB_PR_URL unset, the stub exits 1 — modeling
# "PR not found".

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  # Default: PR exists; tests that need "no PR" unset this.
  export GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Arg parsing: PR by number / URL
# ---------------------------------------------------------------------------

@test "claude task-reviewer: PR by bare number" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert [ -d "$WORKTREE_BASE/review-pr42" ]
}

@test "claude task-reviewer: PR by URL" {
  run "$TASK_REVIEWER_CLAUDE" "https://github.com/owner/repo/pull/42"
  assert_success
  assert [ -d "$WORKTREE_BASE/review-pr42" ]
}

@test "claude task-reviewer: PR URL with trailing params" {
  run "$TASK_REVIEWER_CLAUDE" "https://github.com/owner/repo/pull/99?foo=bar"
  assert_success
  assert [ -d "$WORKTREE_BASE/review-pr99" ]
}

@test "claude task-reviewer: missing PR arg errors" {
  run "$TASK_REVIEWER_CLAUDE"
  assert_failure
  assert_output --partial "PR url or number is required"
}

@test "claude task-reviewer: invalid PR input errors" {
  run "$TASK_REVIEWER_CLAUDE" "not-a-pr"
  assert_failure
  assert_output --partial "could not parse PR number"
}

@test "claude task-reviewer: PR not found (gh pr view fails) errors" {
  unset GH_STUB_PR_URL
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_failure
  assert_output --partial "PR #42 not found"
}

# ---------------------------------------------------------------------------
# Issue arg + auto-detection
# ---------------------------------------------------------------------------

@test "claude task-reviewer: explicit issue number passed to /reviewer" {
  run "$TASK_REVIEWER_CLAUDE" 42 38
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/38"
}

@test "claude task-reviewer: explicit issue URL passed to /reviewer" {
  local issue="https://github.com/owner/repo/issues/38"
  run "$TASK_REVIEWER_CLAUDE" 42 "$issue"
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 $issue"
}

@test "claude task-reviewer: auto-detects issue from PR body 'Closes #N'" {
  export GH_STUB_PR_BODY="This PR adds X. Closes #38."
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/38"
}

@test "claude task-reviewer: auto-detects from 'Fixes #N'" {
  export GH_STUB_PR_BODY="Fixes #38"
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/38"
}

@test "claude task-reviewer: auto-detects from 'Resolves #N'" {
  export GH_STUB_PR_BODY="Resolves #99"
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/99"
}

@test "claude task-reviewer: picks first Closes/Fixes when PR body has many" {
  export GH_STUB_PR_BODY=$'Closes #11.\nAlso fixes #22.\nResolves #33.'
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/11"
}

@test "claude task-reviewer: warns + diff-only when no issue in body" {
  export GH_STUB_PR_BODY="Just some prose, no spec link."
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_output --partial "No spec issue associated"
  # /reviewer is invoked with only the PR URL (no second arg).
  run grep -F "/reviewer https://github.com/owner/repo/pull/42 https" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude task-reviewer: invalid issue input errors" {
  run "$TASK_REVIEWER_CLAUDE" 42 "not-an-issue"
  assert_failure
  assert_output --partial "could not parse issue number"
}

# ---------------------------------------------------------------------------
# Worktree creation
# ---------------------------------------------------------------------------

@test "claude task-reviewer: creates worktree at <repo-parent>/<repo>-worktrees/review-pr<N>" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert [ -d "$WORKTREE_BASE/review-pr42" ]
}

@test "claude task-reviewer: creates a task/review-pr<N> branch" {
  # Branch is namespaced under `task/` so `task-done --remove-worktree`'s
  # `${BRANCH#task/}` slug-strip yields `review-pr<N>` and finds the right
  # info file. Without the prefix, task-done leaks the worktree (#139).
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/review-pr42")
  assert [ -n "$branches" ]
}

@test "claude task-reviewer: branch + info file align so task-done --remove-worktree finds the info" {
  # Regression for #139: the branch must be `task/review-pr<N>` and the
  # info file at `.review-pr<N>.info` so task-done's
  # `INFO_FILE="${WORKTREE_BASE}/.${BRANCH#task/}.info"` resolves.
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  local branch_in_wt
  branch_in_wt=$(git -C "$WORKTREE_BASE/review-pr42" rev-parse --abbrev-ref HEAD)
  assert_equal "$branch_in_wt" "task/review-pr42"
  # Mirror task-done's slug derivation: ${BRANCH#task/} → review-pr42.
  local slug="${branch_in_wt#task/}"
  assert [ -f "$WORKTREE_BASE/.${slug}.info" ]
}

@test "claude task-reviewer: writes .info with PR_NUMBER and ISSUE_NUMBER" {
  export GH_STUB_PR_BODY="Closes #38"
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  local info="$WORKTREE_BASE/.review-pr42.info"
  assert [ -f "$info" ]
  run cat "$info"
  assert_output --partial "PR_NUMBER=42"
  assert_output --partial "ISSUE_NUMBER=38"
  assert_output --partial "SLUG=review-pr42"
}

@test "claude task-reviewer: refuses when review worktree already exists for this PR" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_failure
  assert_output --partial "already exists"
}

# ---------------------------------------------------------------------------
# Tab spawn
# ---------------------------------------------------------------------------

@test "claude task-reviewer: opens a new zellij tab named review-pr<N>" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "new-tab --name review-pr42"
}

@test "claude task-reviewer: does NOT rename the current tab in-place" {
  export ZELLIJ=fake-session
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  run stub_calls zellij
  refute_output --partial "rename-tab reviewer"
}

@test "claude task-reviewer: --no-launch opens tab but does not invoke claude" {
  run "$TASK_REVIEWER_CLAUDE" 42 --no-launch
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Mode flags
# ---------------------------------------------------------------------------

@test "claude task-reviewer: launches claude /reviewer with PR url (auto by default)" {
  # --auto is the default per PR #139 review — the reviewer prompt's authority
  # boundaries rule out anything destructive, so hands-off dispatch is safe.
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "claude --permission-mode auto \"/reviewer https://github.com/owner/repo/pull/42\""
}

@test "claude task-reviewer: --no-auto drops back to interactive permission mode" {
  run "$TASK_REVIEWER_CLAUDE" 42 --no-auto
  assert_success
  # No permission-mode flag at all — runs in interactive default.
  run grep -F "permission-mode" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude task-reviewer: explicit --auto stays auto (idempotent with new default)" {
  run "$TASK_REVIEWER_CLAUDE" 42 --auto
  assert_success
  assert_stub_called zellij "claude --permission-mode auto"
}

@test "claude task-reviewer: --auto propagates TASK_FORCE_AUTO_SUBMIT=1 by default" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

@test "claude task-reviewer: --no-auto omits TASK_FORCE_AUTO_SUBMIT" {
  run "$TASK_REVIEWER_CLAUDE" 42 --no-auto
  assert_success
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Env / model
# ---------------------------------------------------------------------------

@test "claude task-reviewer: defaults ANTHROPIC_MODEL to claude-sonnet-4-6" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "ANTHROPIC_MODEL=claude-sonnet-4-6"
}

@test "claude task-reviewer: honors pre-set ANTHROPIC_MODEL" {
  ANTHROPIC_MODEL=claude-opus-4-7 run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "ANTHROPIC_MODEL=claude-opus-4-7"
}

@test "claude task-reviewer: sets per-PR radio role reviewer-<repo>-pr<N>" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "TASK_FORCE_ROLE=reviewer-${REPO_NAME}-pr42"
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

@test "claude task-reviewer: fails outside a git repo" {
  cd /tmp
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "claude task-reviewer: --help prints usage and exits 0" {
  run "$TASK_REVIEWER_CLAUDE" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "task-reviewer <pr-url-or-number>"
}

@test "claude task-reviewer: -h prints usage" {
  run "$TASK_REVIEWER_CLAUDE" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "claude task-reviewer: unknown flag errors" {
  run "$TASK_REVIEWER_CLAUDE" 42 --bogus
  assert_failure
  assert_output --partial "unknown flag"
}

# ===========================================================================
# Per-loadout parity: jira / notion / local (claude variants byte-identical)
# ===========================================================================

@test "claude-jira task-reviewer: PR by number opens review tab" {
  run "$TASK_REVIEWER_JIRA" 42
  assert_success
  assert_stub_called zellij "new-tab --name review-pr42"
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "claude-jira task-reviewer: --help" {
  run "$TASK_REVIEWER_JIRA" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "claude-jira task-reviewer: defaults ANTHROPIC_MODEL to claude-sonnet-4-6" {
  run "$TASK_REVIEWER_JIRA" 42
  assert_success
  assert_stub_called zellij "ANTHROPIC_MODEL=claude-sonnet-4-6"
}

@test "claude-notion task-reviewer: PR by number opens review tab" {
  run "$TASK_REVIEWER_NOTION" 42
  assert_success
  assert_stub_called zellij "new-tab --name review-pr42"
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "claude-notion task-reviewer: --help" {
  run "$TASK_REVIEWER_NOTION" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "claude-notion task-reviewer: defaults ANTHROPIC_MODEL to claude-sonnet-4-6" {
  run "$TASK_REVIEWER_NOTION" 42
  assert_success
  assert_stub_called zellij "ANTHROPIC_MODEL=claude-sonnet-4-6"
}

@test "claude-local task-reviewer: PR by number opens review tab" {
  run "$TASK_REVIEWER_LOCAL" 42
  assert_success
  assert_stub_called zellij "new-tab --name review-pr42"
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "claude-local task-reviewer: --help" {
  run "$TASK_REVIEWER_LOCAL" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "claude-local task-reviewer: defaults ANTHROPIC_MODEL to claude-sonnet-4-6" {
  run "$TASK_REVIEWER_LOCAL" 42
  assert_success
  assert_stub_called zellij "ANTHROPIC_MODEL=claude-sonnet-4-6"
}

# ---------------------------------------------------------------------------
# kiro variant
# ---------------------------------------------------------------------------

@test "kiro task-reviewer: PR by number opens review tab + kiro chat" {
  run "$TASK_REVIEWER_KIRO" 42
  assert_success
  assert_stub_called zellij "new-tab --name review-pr42"
  assert_stub_called zellij "kiro-cli chat --agent reviewer"
  assert_stub_called zellij "Review PR https://github.com/owner/repo/pull/42"
}

@test "kiro task-reviewer: defaults to sonnet model" {
  run "$TASK_REVIEWER_KIRO" 42
  assert_success
  assert_stub_called zellij "--model claude-sonnet-4.6"
}

@test "kiro task-reviewer: --model overrides default" {
  run "$TASK_REVIEWER_KIRO" 42 --model claude-opus-4.6
  assert_success
  assert_stub_called zellij "--model claude-opus-4.6"
}

@test "kiro task-reviewer: --trust-all-tools is the default (idempotent with explicit --trust-all)" {
  # Like claude's --auto-by-default (#139), kiro defaults to trust-all-tools.
  # Reviewer's authority boundaries rule out anything destructive.
  run "$TASK_REVIEWER_KIRO" 42
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}

@test "kiro task-reviewer: explicit --trust-all stays trust-all" {
  run "$TASK_REVIEWER_KIRO" 42 --trust-all
  assert_success
  assert_stub_called zellij "--trust-all-tools"
}

@test "kiro task-reviewer: --no-trust-all drops back to interactive trust" {
  run "$TASK_REVIEWER_KIRO" 42 --no-trust-all
  assert_success
  run grep -F "trust-all-tools" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro task-reviewer: --no-launch opens tab without kiro-cli" {
  run "$TASK_REVIEWER_KIRO" 42 --no-launch
  assert_success
  assert_output --partial "kiro NOT launched"
  run grep -F "kiro-cli " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro task-reviewer: PR not found errors" {
  unset GH_STUB_PR_URL
  run "$TASK_REVIEWER_KIRO" 42
  assert_failure
  assert_output --partial "PR #42 not found"
}

@test "kiro task-reviewer: --help" {
  run "$TASK_REVIEWER_KIRO" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "kiro task-reviewer: explicit issue passes through to kiro prompt" {
  run "$TASK_REVIEWER_KIRO" 42 38
  assert_success
  assert_stub_called zellij "against spec issue https://github.com/owner/repo/issues/38"
}

# ===========================================================================
# Dispatcher routing (preserved from previous suite)
# ===========================================================================

@test "top-level task-reviewer: dispatches to claude-gh variant" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "top-level task-reviewer: dispatches to kiro-gh variant" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent reviewer"
}

@test "top-level task-reviewer: dispatches to claude-jira variant" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/jira-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "top-level task-reviewer: dispatches to claude-notion variant" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/notion-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "top-level task-reviewer: dispatches to claude-local variant" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/local-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42"
}

@test "top-level task-reviewer: errors cleanly without a workflow doc" {
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_failure
  assert_output --partial "no agentic-workflow impl configured"
}

@test "top-level task-reviewer: errors cleanly for impls without a reviewer variant" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42
  assert_failure
  assert_output --partial "task-reviewer is not available for impl"
}

@test "top-level task-reviewer: forwards positional + flags through to loadout" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"
  run "$TASK_REVIEWER_DISPATCHER" 42 38 --auto
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 https://github.com/owner/repo/issues/38"
  assert_stub_called zellij "claude --permission-mode auto"
}
