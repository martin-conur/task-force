#!/usr/bin/env bats
# A worktree forked from a ref without the task-force install (#393).
#
# Some repos commit the install on a local branch and never push it. A worktree
# forked from a ref that lacks those commits (task-work's auto-refresh onto
# `origin/<base>`, a reviewer's PR head) then booted with no role command, no
# radio hooks and no tracker MCP, and the launchers said "Started" all the same.
# So every launcher copies the missing files in from the main checkout, keeps
# them out of the worktree's commits, refuses to launch without the role file
# or the hooks, and waits for the register, saying which case it is on a miss.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  export ZELLIJ=fake-session
  export GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  ROLE_NAME=$(expected_radio_repo_name)
}

teardown() {
  teardown_all
}

REF="https://github.com/owner/repo/issues/1"

# A bare origin that has main as it was before the install.
_origin() {
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare -b main "$ORIGIN"
  git remote add origin "$ORIGIN"
  git push -q origin main
}

# The pre-#327 pattern: the install committed on a local branch, never pushed,
# beside the files task-init leaves untracked (the tracker MCP, the session's
# approved permissions).
_install_on_local_branch() {
  git checkout -q -b tf-local
  "$CLAUDE_GH_TASK_INIT" --owner o --repo r --project 1 </dev/null >/dev/null
  git add -A
  git commit -q -m "task-force files (remove before PR)"
  printf '{"mcpServers":{}}\n' > .mcp.json
  printf '{"permissions":{"allow":["Bash(make *)"]}}\n' > .claude/settings.local.json
  printf '.mcp.json\n.claude/settings.local.json\n' > .git/info/exclude
}

# Move origin/main ahead from another clone, so local main is behind it and
# task-work forks from origin/main.
_advance_origin() {
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$ORIGIN" "$other"
  git -C "$other" -c user.email=o@o -c user.name=O commit -q --allow-empty -m "upstream moved"
  git -C "$other" push -q origin main
}

_synced_files() {
  local wt="$1"
  assert [ -f "$wt/.claude/commands/worker.md" ]
  assert [ -f "$wt/.claude/commands/reviewer.md" ]
  assert [ -f "$wt/.claude/settings.json" ]
  assert [ -f "$wt/.claude/settings.local.json" ]
  assert [ -f "$wt/.claude/gh-workflow.md" ]
  assert [ -f "$wt/CLAUDE.md" ]
  assert [ -f "$wt/.mcp.json" ]
}

# ---------------------------------------------------------------------------
# the sync
# ---------------------------------------------------------------------------

@test "task-work onto origin/<base>: a local-branch install is copied in, and git add -A stages none of it" {
  _origin
  _install_on_local_branch
  _advance_origin
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF" --base main
  assert_success
  assert_output --partial "Forking from origin/main"
  assert_output --partial "kept out of its commits by a per-worktree exclude"
  local wt="$WORKTREE_BASE/issue-1"
  _synced_files "$wt"
  # The branch itself has none of them.
  run git -C "$wt" ls-files .claude CLAUDE.md .mcp.json
  assert_output ""

  printf 'work\n' > "$wt/feature.txt"
  git -C "$wt" add -A
  run git -C "$wt" diff --cached --name-only
  assert_output "feature.txt"
  git -C "$wt" commit -q -m work
  run git -C "$wt" diff --name-only origin/main HEAD
  assert_output "feature.txt"

  # Logged as well as said.
  run grep -c "worktree-sync: copied 9 file(s) into .*issue-1 from" "$TASK_FORCE_HOME/radio/log"
  assert_output "1"
}

@test "the exclude is the worktree's own: the main checkout and its info/exclude are untouched" {
  _origin
  _install_on_local_branch
  _advance_origin
  AW_IMPL=claude-gh "$TASK_WORK" issue-1 "$REF" --base main >/dev/null 2>&1
  # The common exclude file holds only what the user put there.
  run cat .git/info/exclude
  assert_output $'.mcp.json\n.claude/settings.local.json'
  # A new file of a synced name is still seen in the main checkout.
  git rm -q --cached CLAUDE.md
  run git status --porcelain CLAUDE.md
  assert_output --partial "CLAUDE.md"
  git reset -q
}

@test "the user's global excludes still apply in the synced worktree" {
  printf '*.secret\n' > "$BATS_TEST_TMPDIR/global-ignore"
  git config core.excludesFile "$BATS_TEST_TMPDIR/global-ignore"
  _origin
  _install_on_local_branch
  _advance_origin
  AW_IMPL=claude-gh "$TASK_WORK" issue-1 "$REF" --base main >/dev/null 2>&1
  local wt="$WORKTREE_BASE/issue-1"
  touch "$wt/key.secret" "$wt/kept.txt"
  run git -C "$wt" status --porcelain --untracked-files=all
  assert_output "?? kept.txt"
}

@test "a later merge that brings the files in tracked replaces the copies, no refusal" {
  _origin
  _install_on_local_branch
  _advance_origin
  AW_IMPL=claude-gh "$TASK_WORK" issue-1 "$REF" --base main >/dev/null 2>&1
  local wt="$WORKTREE_BASE/issue-1"
  printf 'copy\n' > "$wt/.claude/commands/worker.md"
  run git -C "$wt" merge -q --no-edit tf-local
  assert_success
  # The tracked file won.
  run git -C "$wt" diff --quiet tf-local -- .claude/commands/worker.md
  assert_success
}

@test "task-reviewer on a PR head without the install gets it copied in" {
  _origin
  # The PR head: a commit off pre-install main, never carrying the files.
  git checkout -q -b pr-branch
  printf 'change\n' > change.txt
  git add change.txt && git commit -q -m change
  git push -q origin pr-branch:refs/pull/42/head
  git checkout -q main
  _install_on_local_branch
  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42 1
  assert_success
  local wt="$WORKTREE_BASE/review-pr42"
  run git -C "$wt" log -1 --format=%s
  assert_output "change"
  _synced_files "$wt"
  printf 'scratch\n' > "$wt/notes.txt"
  git -C "$wt" add -A
  run git -C "$wt" diff --cached --name-only
  assert_output "notes.txt"
}

@test "a branch's own CLAUDE.md without the import gets it through CLAUDE.local.md" {
  printf '# the repo'"'"'s own\n' > CLAUDE.md
  git add CLAUDE.md && git commit -q -m "repo CLAUDE.md"
  _origin
  _install_on_local_branch
  _advance_origin
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF" --base main
  assert_success
  local wt="$WORKTREE_BASE/issue-1"
  run cat "$wt/CLAUDE.md"
  assert_output "# the repo's own"
  run cat "$wt/CLAUDE.local.md"
  assert_output "@.claude/gh-workflow.md"
  git -C "$wt" add -A
  run git -C "$wt" diff --cached --name-only
  assert_output ""
}

@test "nothing is overwritten: a file the worktree already has stays as it is" {
  seed_hook_carriers "$MAIN_REPO"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"command":"radio register --role r"}]}]},"x":"BASE"}\n' \
    > .claude/settings.json
  git add .claude && git commit -q -m install
  # The main checkout's copy has moved on since; the fork has the committed one.
  printf '{"hooks":{"SessionStart":[{"hooks":[{"command":"radio register --role r"}]}]},"x":"MAIN"}\n' \
    > .claude/settings.json
  printf '{}\n' > .mcp.json
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  local wt="$WORKTREE_BASE/issue-1"
  run grep -c BASE "$wt/.claude/settings.json"
  assert_output "1"
  # Only the file it lacked was copied, and it is kept out of commits.
  run git -C "$wt" status --porcelain --untracked-files=all
  assert_output ""
  assert [ -f "$wt/.mcp.json" ]
}

@test "a normal install that is committed on the base copies nothing" {
  "$CLAUDE_GH_TASK_INIT" --owner o --repo r --project 1 </dev/null >/dev/null
  git add -A && git commit -q -m install
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  refute_output --partial "Copied"
  run git -C "$WORKTREE_BASE/issue-1" config --get extensions.worktreeConfig
  assert_output ""
}

@test "the local-only path is unchanged: its own copy, its own exclude, no per-worktree config" {
  "$JIRA_TASK_INIT" --local-only --site https://acme.atlassian.net --key P --board B </dev/null >/dev/null
  AW_IMPL=claude-jira run "$TASK_WORK" PROJ-1
  assert_success
  assert_output --partial "Local-only install: copied 7 untracked task-force file(s)"
  refute_output --partial "per-worktree exclude"
  run git -C "$WORKTREE_BASE/proj-1" config --get extensions.worktreeConfig
  assert_output ""
  run git -C "$WORKTREE_BASE/proj-1" status --porcelain --untracked-files=all
  assert_output ""
}

# ---------------------------------------------------------------------------
# the pre-launch check
# ---------------------------------------------------------------------------

@test "task-work refuses before the agent starts when the role file is missing" {
  seed_hook_carriers "$MAIN_REPO"
  rm .claude/commands/worker.md
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_failure
  assert_output --partial "Error: worktree 'issue-1' has no .claude/commands/worker.md"
  assert_output --partial "task-init claude-gh"
  assert_output --partial "task-recreate-worker issue-1"
  refute_output --partial "radio hooks"
  run stub_calls zellij
  refute_output --partial "new-tab"
  # Left in place, with its sidecar, for task-recreate-worker.
  assert [ -d "$WORKTREE_BASE/issue-1" ]
  assert [ -f "$WORKTREE_BASE/.issue-1.info" ]
}

@test "task-work --plan checks the planner's role file" {
  seed_hook_carriers "$MAIN_REPO"
  rm .claude/commands/planner.md
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF" --plan
  assert_failure
  assert_output --partial "has no .claude/commands/planner.md"
}

@test "task-work refuses before the agent starts when the radio hook is missing" {
  seed_hook_carriers "$MAIN_REPO"
  printf '{"permissions":{"allow":[]}}\n' > .claude/settings.json
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_failure
  assert_output --partial "Error: worktree 'issue-1' has no claude radio hooks"
  refute_output --partial "has no .claude/commands/worker.md"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "kiro task-work: a hookless worker agent is refused" {
  setup_kiro_agents   # resolves, but carries no radio hook
  HOME="$BATS_TEST_TMPDIR" AW_IMPL=kiro-gh run "$TASK_WORK" issue-1 "$REF"
  assert_failure
  assert_output --partial "has no kiro radio hooks"
  assert_output --partial ".kiro/agents/worker.json is missing, or carries no 'radio register' hook"
}

@test "--no-launch starts nothing, so it checks nothing" {
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF" --no-launch
  assert_success
  refute_output --partial "Error:"
}

@test "task-reviewer refuses a missing role file and unwinds the review worktree" {
  seed_hook_carriers "$MAIN_REPO"
  rm .claude/commands/reviewer.md
  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_failure
  assert_output --partial "the review worktree for PR #42 has no .claude/commands/reviewer.md"
  assert [ ! -d "$WORKTREE_BASE/review-pr42" ]
  run git show-ref --verify --quiet refs/heads/task/review-pr42
  assert_failure
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "task-reviewer refuses a missing radio hook" {
  seed_hook_carriers "$MAIN_REPO"
  rm .claude/settings.json
  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_failure
  assert_output --partial "the review worktree for PR #42 has no claude radio hooks"
}

@test "kiro task-reviewer: the hook check reads the reviewer's own agent config" {
  seed_hook_carriers "$MAIN_REPO"
  printf '{"name":"reviewer"}\n' > .kiro/agents/reviewer.json
  HOME="$BATS_TEST_TMPDIR" AW_IMPL=kiro-gh run "$TASK_REVIEWER" 42
  assert_failure
  assert_output --partial ".kiro/agents/reviewer.json is missing, or carries no 'radio register' hook"
}

# ---------------------------------------------------------------------------
# the register wait
# ---------------------------------------------------------------------------

@test "task-work: a register that lands is confirmed" {
  seed_hook_carriers "$MAIN_REPO"
  seed_zellij_tabs issue-1
  STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RADIO="$RADIO" \
    AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  assert_output --partial "It registered with radio as worker-$ROLE_NAME-issue-1."
  refute_output --partial "has NOT registered"
}

@test "task-reviewer: a register that lands is confirmed" {
  seed_hook_carriers "$MAIN_REPO"
  seed_zellij_tabs review-pr42
  STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RADIO="$RADIO" \
    AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_success
  assert_output --partial "It registered with radio as reviewer-$ROLE_NAME-pr42."
}

@test "the wait polls: TASK_FORCE_REGISTER_WAIT bounds it" {
  seed_hook_carriers "$MAIN_REPO"
  seed_zellij_tabs issue-1
  STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RADIO="$RADIO" STUB_CLAUDE_REGISTER_DELAY=2 \
    TASK_FORCE_REGISTER_WAIT=10 AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  assert_output --partial "It registered with radio"
}

@test "no register, both files there: still starting, or a prompt waits in the tab (exit 0)" {
  seed_hook_carriers "$MAIN_REPO"
  AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  assert_output --partial "Warning: worker-$ROLE_NAME-issue-1 was launched in tab 'issue-1' but has NOT registered"
  assert_output --partial "no session file was written"
  assert_output --partial "The role file and the radio hooks are both there: it is still starting"

  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_success
  assert_output --partial "Warning: reviewer-$ROLE_NAME-pr42 was launched in tab 'review-pr42' but has NOT registered"
  assert_output --partial "it is still starting"
}

@test "no register, role file gone: the role never started, retry" {
  seed_hook_carriers "$MAIN_REPO"
  STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RM=.claude/commands/worker.md \
    AW_IMPL=claude-gh run "$TASK_WORK" issue-1 "$REF"
  assert_success
  assert_output --partial "has NOT registered"
  assert_output --partial ".claude/commands/worker.md is missing from the worktree: the worker never"
  assert_output --partial "retry the launch"
}

@test "no register, hooks gone: it runs but cannot be woken, do not retype" {
  seed_hook_carriers "$MAIN_REPO"
  STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RM=.claude/settings.json \
    AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_success
  assert_output --partial "has NOT registered"
  assert_output --partial ".claude/settings.json carries no 'radio register' hook: the reviewer"
  assert_output --partial "its own 'radio send' still works"
  assert_output --partial "Do not retype its prompt"
}

@test "aw_register_case reads kiro's carrier for kiro" {
  local dir="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$dir/.kiro/agents"
  printf '{"name":"reviewer"}\n' > "$dir/.kiro/agents/reviewer.json"
  run env HOME="$BATS_TEST_TMPDIR" bash -c ". '$REPO_ROOT_REAL/lib/register-wait.sh'; aw_register_case kiro reviewer '$dir'"
  assert_output --partial ".kiro/agents/reviewer.json carries no 'radio register' hook"
  rm "$dir/.kiro/agents/reviewer.json"
  run env HOME="$BATS_TEST_TMPDIR" bash -c ". '$REPO_ROOT_REAL/lib/register-wait.sh'; aw_register_case kiro reviewer '$dir'"
  assert_output --partial ".kiro/agents/reviewer.json is missing from the worktree"
}

@test "aw_register_wait_secs: a launcher's own value, then TASK_FORCE_REGISTER_WAIT, then 30" {
  local lib="$REPO_ROOT_REAL/lib/register-wait.sh"
  run env -u TASK_FORCE_REGISTER_WAIT bash -c ". '$lib'; aw_register_wait_secs"
  assert_output "30"
  run env TASK_FORCE_REGISTER_WAIT=7 bash -c ". '$lib'; aw_register_wait_secs"
  assert_output "7"
  run env TASK_FORCE_REGISTER_WAIT=7 bash -c ". '$lib'; aw_register_wait_secs 3"
  assert_output "3"
  run env TASK_FORCE_REGISTER_WAIT=junk bash -c ". '$lib'; aw_register_wait_secs"
  assert_output "30"
}

@test "task-recreate-worker honours TASK_FORCE_REGISTER_WAIT when its own variable is unset" {
  seed_hook_carriers "$MAIN_REPO"
  mkdir -p "$WORKTREE_BASE"
  git worktree add -q "$WORKTREE_BASE/issue-1" -b task/issue-1
  printf 'BASE_BRANCH=main\nSLUG=issue-1\nGH_URL=%s\nTAB_ID=999\n' "$REF" > "$WORKTREE_BASE/.issue-1.info"
  run env -u TASK_RECREATE_WORKER_REGISTER_WAIT TASK_FORCE_REGISTER_WAIT=1 AW_IMPL=claude-gh "$TASK_RECREATE_WORKER" issue-1
  assert_success
  assert_output --partial "after 1s"
  # The files were copied in from the main checkout first.
  assert [ -f "$WORKTREE_BASE/issue-1/.claude/commands/worker.md" ]
}
