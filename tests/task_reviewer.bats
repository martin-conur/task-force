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

@test "claude task-reviewer: refuses when stale branch exists without the worktree dir (#139 round-4)" {
  # Concurrent guard must catch the case where the worktree dir got deleted
  # manually but the task/review-prN branch survived. Otherwise
  # aw_create_worktree silently reuses the stale branch and the reviewer
  # opens on old code with only a stderr warning that --auto dispatch can't
  # see. We model it by creating the branch directly with no worktree.
  git -C "$MAIN_REPO" branch task/review-pr42
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_failure
  assert_output --partial "already exists"
  assert_output --partial "task/review-pr42"
  assert_output --partial "git branch -D"
}

@test "claude task-reviewer: ERR trap cleans up partial worktree/branch/info on aw_launch_tab failure (#139 round-4)" {
  # When zellij new-tab fails (e.g. zellij isn't running, or the cmd errored
  # out), `set -e` aborts the script. Without the trap, the worktree dir,
  # the task/review-prN branch, and the .info file would all be left behind
  # — the concurrent guard would then permanently block re-invocation.
  export STUB_ZELLIJ_NEW_TAB_FAIL=1
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_failure

  # All three artifacts should be gone.
  assert [ ! -d "$WORKTREE_BASE/review-pr42" ]
  assert [ ! -f "$WORKTREE_BASE/.review-pr42.info" ]
  run git -C "$MAIN_REPO" branch --list "task/review-pr42"
  assert_output ""

  # The next invocation (with new-tab fixed) must succeed — proves the
  # concurrent guard isn't tripped by leftover state.
  unset STUB_ZELLIJ_NEW_TAB_FAIL
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert [ -d "$WORKTREE_BASE/review-pr42" ]
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

# #144: jira loadout must accept a Jira issue key as opaque 2nd-arg and pass
# it through to /reviewer verbatim (no GitHub URL synthesis).
@test "claude-jira task-reviewer: passes Jira issue key through to /reviewer (#144)" {
  run "$TASK_REVIEWER_JIRA" 42 PROJ-123
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 PROJ-123"
}

# #144 round-2 + round-3: SPEC_IDENTIFIER containing `!` must land in the
# assembled command unmangled, and the assembled command must include
# `set +H` to disable bash history expansion in the spawned interactive
# subshell. Without the defense, a Jira / Notion / local id like
# `auth-login!v2` would be silently history-substituted before /reviewer
# ever saw it.
#
# Round-3 follow-up: `set +H;` must appear BEFORE the RADIO_ENV_PREFIX
# assignments (TASK_FORCE_ROLE=, ANTHROPIC_MODEL=, etc.), not after.
# `VAR=val cmd1; cmd2` in bash scopes the assignments to `cmd1` only — if
# `set +H` sits between the env prefix and `claude`, the env vars attach
# to the `set` builtin and never reach `claude` (radio routing /
# model selection / AUTO_SUBMIT all dead).
@test "claude-jira task-reviewer: SPEC_IDENTIFIER with '!' lands unmangled; cmd disables histexpand (#144 round-2)" {
  run "$TASK_REVIEWER_JIRA" 42 'PROJ-123!v2'
  assert_success
  assert_stub_called zellij "PROJ-123!v2"
  assert_stub_called zellij "set +H;"
}

@test "claude-gh task-reviewer: assembled command disables histexpand (#144 round-2)" {
  # Same defense applies on the claude-gh path even though SPEC_IDENTIFIER
  # there is a GitHub issues URL (no `!`) — the 4 dispatcher bodies stay
  # byte-identical, and `set +H` is cheap and harmless on gh.
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_stub_called zellij "set +H;"
}

# #144 round-3: `set +H;` must precede the RADIO_ENV_PREFIX assignments.
# Regression check: the round-2 placement put `set +H;` BETWEEN the env
# prefix and `claude`, which silently neutered env passthrough because
# bash scoped `VAR=val set +H;` to the builtin only. This test pins the
# correct ordering — `set +H` first, then env, then claude.
@test "claude task-reviewer: 'set +H' precedes RADIO_ENV_PREFIX so env vars reach claude (#144 round-3)" {
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  # Extract the assembled command string from the most recent zellij
  # new-tab call. It's the last token after `--` on the line.
  local cmd_line
  cmd_line=$(grep -m1 -F "new-tab --name review-pr42" "$STUB_CALLS_DIR/zellij.calls")
  # `set +H;` must appear before `TASK_FORCE_ROLE=` in the same line.
  local set_pos="${cmd_line%%set +H;*}"
  local role_pos="${cmd_line%%TASK_FORCE_ROLE=*}"
  # If `set +H;` comes first, the prefix-substring-stripped result is
  # shorter than for `TASK_FORCE_ROLE=`. Compare lengths.
  [[ ${#set_pos} -lt ${#role_pos} ]] || {
    echo "ordering wrong: 'set +H;' must come before 'TASK_FORCE_ROLE='" >&2
    echo "cmd: $cmd_line" >&2
    return 1
  }
}

# #144: jira loadout must NOT scan PR body for `Closes #N` — that's a
# GitHub-only convention. With no 2nd arg, behavior is diff-only regardless
# of what's in the body.
@test "claude-jira task-reviewer: ignores GitHub Closes/Fixes in PR body — diff-only without 2nd arg (#144)" {
  export GH_STUB_PR_BODY="Closes #38"
  run "$TASK_REVIEWER_JIRA" 42
  assert_success
  # /reviewer must receive only the PR URL, not a synthesized GitHub issues URL.
  run grep -F "/reviewer https://github.com/owner/repo/pull/42 https" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude-jira task-reviewer: emits 'GitHub-only' advisory when no 2nd arg (#144)" {
  run "$TASK_REVIEWER_JIRA" 42
  assert_success
  assert_output --partial "No spec identifier passed"
  assert_output --partial "auto-detect is GitHub-only"
  assert_output --partial "diff-only review"
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

# #144: notion loadout must accept a Notion page URL as opaque 2nd-arg.
@test "claude-notion task-reviewer: passes Notion page URL through to /reviewer (#144)" {
  local notion_url="https://www.notion.so/myws/Spec-Page-1234abcd"
  run "$TASK_REVIEWER_NOTION" 42 "$notion_url"
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 $notion_url"
}

@test "claude-notion task-reviewer: ignores GitHub Closes/Fixes in PR body — diff-only without 2nd arg (#144)" {
  export GH_STUB_PR_BODY="Fixes #38"
  run "$TASK_REVIEWER_NOTION" 42
  assert_success
  run grep -F "/reviewer https://github.com/owner/repo/pull/42 https" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude-notion task-reviewer: emits 'GitHub-only' advisory when no 2nd arg (#144)" {
  run "$TASK_REVIEWER_NOTION" 42
  assert_success
  assert_output --partial "No spec identifier passed"
  assert_output --partial "auto-detect is GitHub-only"
  # Mirror claude-jira / claude-local: pin the "diff-only review" trailer so
  # a future regression that accidentally drops it for notion-only would be
  # visible to CI (#144 round-2 review).
  assert_output --partial "diff-only review"
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

# #144: local loadout must accept a local task slug as opaque 2nd-arg.
@test "claude-local task-reviewer: passes local task slug through to /reviewer (#144)" {
  run "$TASK_REVIEWER_LOCAL" 42 042-add-login
  assert_success
  assert_stub_called zellij "/reviewer https://github.com/owner/repo/pull/42 042-add-login"
}

@test "claude-local task-reviewer: ignores GitHub Closes/Fixes in PR body — diff-only without 2nd arg (#144)" {
  export GH_STUB_PR_BODY="Resolves #38"
  run "$TASK_REVIEWER_LOCAL" 42
  assert_success
  run grep -F "/reviewer https://github.com/owner/repo/pull/42 https" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude-local task-reviewer: emits 'GitHub-only' advisory when no 2nd arg (#144)" {
  run "$TASK_REVIEWER_LOCAL" 42
  assert_success
  assert_output --partial "No spec identifier passed"
  assert_output --partial "auto-detect is GitHub-only"
  # Mirror claude-jira / claude-notion: pin the "diff-only review" trailer
  # so a future regression that drops it for local-only would be visible
  # to CI (#144 round-3 review — missed in round-1 when the assertion was
  # added to claude-jira / claude-notion).
  assert_output --partial "diff-only review"
}

# #144: claude-gh path stays green — the advisory copy is GitHub-flavored, not
# the non-gh "auto-detect is GitHub-only" one (regression for the gh branch).
@test "claude-gh task-reviewer: 'no spec issue' advisory keeps the original GitHub-flavored copy (#144 regression)" {
  export GH_STUB_PR_BODY="Just some prose, no spec link."
  run "$TASK_REVIEWER_CLAUDE" 42
  assert_success
  assert_output --partial "No spec issue associated"
  assert_output --partial "no Closes/Fixes in body"
  # Must not regress to the non-gh advisory.
  refute_output --partial "auto-detect is GitHub-only"
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

@test "kiro task-reviewer: --trust-all default propagates TASK_FORCE_AUTO_SUBMIT=1 to radio env (#139 round-4)" {
  # Parity with the claude variants: when the dispatcher runs with
  # trust-all (the default), the radio session inherits AUTO_SUBMIT=1 so
  # that PM pings into the reviewer's pane auto-submit instead of sitting
  # in the input buffer waiting for a manual Enter.
  run "$TASK_REVIEWER_KIRO" 42
  assert_success
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

@test "kiro task-reviewer: --no-trust-all omits TASK_FORCE_AUTO_SUBMIT (#139 round-4)" {
  run "$TASK_REVIEWER_KIRO" 42 --no-trust-all
  assert_success
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
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
