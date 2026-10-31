#!/usr/bin/env bats
# Local-only installs (#327): task-init --local-only writes the same artifacts
# untracked — hooks in .claude/settings.local.json, the import in CLAUDE.local.md,
# every path in .git/info/exclude — so nothing task-force reaches a branch.
#
# Asserts:
#   - install leaves `git status` clean, writes no tracked file, records the mode
#   - the mode is sticky across re-runs, and a tracked target is refused
#   - kiro refuses it, both asked for and on a repo already local-only
#   - task-work / task-reviewer / task-recreate-worker copy the set into the
#     worktree, and a worker's `git add -A` stages none of it
#   - #304: a copied worktree carries the hooks; one whose copy is missing, with
#     nothing in the main checkout to copy, is refused
#   - task-remove returns the repo to its pre-install state
#   - task-config show / add / set know the mode

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
  WT_PHYS="$(cd "$MAIN_REPO/.." && pwd -P)/${REPO_NAME}-worktrees"
}

teardown() {
  teardown_all
}

_install() {
  "$JIRA_TASK_INIT" --local-only --site https://acme.atlassian.net --key P --board B </dev/null
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

@test "install: git status stays clean and every artifact is written untracked" {
  run _install
  assert_success
  run git status --porcelain --untracked-files=all
  assert_output ""
  assert [ -f .claude/jira-workflow.md ]
  assert [ -f .claude/commands/worker.md ]
  assert [ -f .claude/commands/reviewer.md ]
  run git ls-files
  assert_output "README.md"
}

@test "install: hooks go to settings.local.json, the import to CLAUDE.local.md" {
  printf 'own instructions\n' > CLAUDE.md
  git add CLAUDE.md && git commit -qm claude
  _install
  assert [ ! -e .claude/settings.json ]
  run grep -c 'radio register' .claude/settings.local.json
  assert_output "1"
  run cat CLAUDE.local.md
  assert_output "@.claude/jira-workflow.md"
  run cat CLAUDE.md
  assert_output "own instructions"
}

@test "install: the exclude block and the git config record the mode" {
  _install
  run git config --get task-force.install
  assert_output "local-only"
  run cat .git/info/exclude
  assert_output --partial "# task-force:local-only:start"
  assert_output --partial "/CLAUDE.local.md"
  assert_output --partial "/.claude/settings.local.json"
  assert_output --partial "/.claude/jira-workflow.md"
  assert_output --partial "/.claude/commands/worker.md"
}

@test "install: sticky — a re-run without the flag stays local-only" {
  _install
  run "$JIRA_TASK_INIT" --force </dev/null
  assert_success
  assert [ ! -e .claude/settings.json ]
  assert [ ! -e CLAUDE.md ]
  run git status --porcelain --untracked-files=all
  assert_output ""
}

@test "install: a re-run replaces the block rather than appending a second one" {
  _install
  _install
  run grep -c 'task-force:local-only:start' .git/info/exclude
  assert_output "1"
}

@test "install: refuses when git already tracks a target, and writes nothing" {
  mkdir -p .claude/commands
  printf 'theirs\n' > .claude/commands/worker.md
  git add .claude && git commit -qm theirs
  run _install
  assert_failure
  assert_output --partial "git already tracks them"
  assert_output --partial ".claude/commands/worker.md"
  run git config --get task-force.install
  assert_failure
  assert [ ! -e .claude/settings.local.json ]
}

@test "install: claude-local excludes tasks/ and leaves .gitignore alone" {
  run "$CLAUDE_LOCAL_TASK_INIT" --local-only </dev/null
  assert_success
  assert [ -f tasks/README.md ]
  assert [ ! -e .gitignore ]
  run grep -xF '/tasks/' .git/info/exclude
  assert_success
  run git status --porcelain --untracked-files=all
  assert_output ""
}

@test "install: every claude loadout takes the flag" {
  local init
  for init in "$CLAUDE_GH_TASK_INIT" "$CLAUDE_NOTION_TASK_INIT"; do
    run "$init" --local-only </dev/null
    assert_success
    run git status --porcelain --untracked-files=all
    assert_output ""
    rm -rf .claude CLAUDE.local.md
  done
}

@test "kiro: --local-only is refused, and nothing is written" {
  run "$KIRO_GH_TASK_INIT" --local-only </dev/null
  assert_failure
  assert_output --partial "kiro cannot be installed local-only"
  assert [ ! -e .kiro ]
}

@test "kiro: refused on a repo that is already local-only, flag or not" {
  _install
  local init
  for init in "$KIRO_GH_TASK_INIT" "$KIRO_LOCAL_TASK_INIT" "$KIRO_TASK_INIT"; do
    run "$init" </dev/null
    assert_failure
    assert_output --partial "this repo is a local-only install"
  done
  assert [ ! -e .kiro ]
}

@test "the task-init dispatcher passes --local-only through" {
  run "$TASK_INIT_DISPATCHER" claude-jira --local-only </dev/null
  assert_success
  run git config --get task-force.install
  assert_output "local-only"
}

# ---------------------------------------------------------------------------
# worktrees
# ---------------------------------------------------------------------------

@test "task-work copies the set into the worktree before the agent starts" {
  _install
  AW_IMPL=claude-jira run "$TASK_WORK" PROJ-1
  assert_success
  assert_output --partial "copied 7 untracked task-force file(s)"
  local wt="$WORKTREE_BASE/proj-1"
  assert [ -f "$wt/.claude/settings.local.json" ]
  assert [ -f "$wt/.claude/commands/worker.md" ]
  assert [ -f "$wt/CLAUDE.local.md" ]
  assert_stub_called zellij "new-tab --name proj-1"
}

@test "a worker's git add -A stages none of the artifacts: its PR carries none" {
  _install
  AW_IMPL=claude-jira "$TASK_WORK" PROJ-1 >/dev/null
  local wt="$WORKTREE_BASE/proj-1"
  printf 'work\n' > "$wt/feature.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -qm work
  run git -C "$wt" diff --name-only main HEAD
  assert_output "feature.txt"
}

@test "a normal install copies nothing" {
  "$JIRA_TASK_INIT" </dev/null >/dev/null
  git add -A && git commit -qm install
  AW_IMPL=claude-jira run "$TASK_WORK" PROJ-1
  assert_success
  refute_output --partial "untracked task-force file"
}

@test "task-reviewer copies the set into the review worktree" {
  _install
  AW_IMPL=claude-jira run "$TASK_REVIEWER" 42
  assert_success
  assert [ -f "$WORKTREE_BASE/review-pr42/.claude/commands/reviewer.md" ]
  assert [ -f "$WORKTREE_BASE/review-pr42/.claude/settings.local.json" ]
}

# A worker whose tab died, in a worktree that never got the copy.
_dead_worker() {
  mkdir -p "$WORKTREE_BASE"
  git worktree add -q "$WORKTREE_BASE/proj-1" -b task/proj-1
  printf 'BASE_BRANCH=main\nSLUG=proj-1\nJIRA_REF=PROJ-1\nTAB_ID=999\n' > "$WORKTREE_BASE/.proj-1.info"
}

@test "task-recreate-worker fills in a missing copy, and the #304 check passes" {
  _install
  _dead_worker
  AW_IMPL=claude-jira run "$TASK_RECREATE_WORKER" proj-1
  assert_success
  refute_output --partial "has no claude radio hooks"
  assert [ -f "$WORKTREE_BASE/proj-1/.claude/settings.local.json" ]
  assert_stub_called zellij "new-tab --name proj-1"
}

@test "task-recreate-worker keeps a worktree's own settings.local.json" {
  _install
  _dead_worker
  mkdir -p "$WORKTREE_BASE/proj-1/.claude"
  printf '{"permissions":{"allow":["Bash(make *)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"radio register --role r"}]}]}}\n' \
    > "$WORKTREE_BASE/proj-1/.claude/settings.local.json"
  AW_IMPL=claude-jira run "$TASK_RECREATE_WORKER" proj-1
  assert_success
  run grep -c 'make' "$WORKTREE_BASE/proj-1/.claude/settings.local.json"
  assert_output "1"
}

@test "#304: a missing copy with nothing to copy from is still refused, naming the local-only fix" {
  _install
  rm .claude/settings.local.json
  _dead_worker
  AW_IMPL=claude-jira run "$TASK_RECREATE_WORKER" proj-1
  assert_failure
  assert_output --partial "has no claude radio hooks"
  assert_output --partial "This is a local-only install"
  assert_output --partial "task-init <loadout> --local-only"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

# ---------------------------------------------------------------------------
# removal and task-config
# ---------------------------------------------------------------------------

@test "task-remove returns the repo to its pre-install state" {
  printf 'own instructions\n' > CLAUDE.local.md
  mkdir -p .claude
  printf '{"permissions":{"allow":["Bash(make *)"]}}\n' > .claude/settings.local.json
  printf 'mine\n' >> .git/info/exclude
  local before_exclude before_files before_claude
  before_exclude=$(cat .git/info/exclude)
  before_files=$(find . -path ./.git -prune -o -type f -print | sort)
  before_claude=$(cat CLAUDE.local.md)
  _install
  run "$TASK_REMOVE" --yes </dev/null
  assert_success
  assert_output --partial "removed the task-force block from .git/info/exclude"
  assert_output --partial "removed git config task-force.install"
  run cat .git/info/exclude
  assert_output "$before_exclude"
  run bash -c "find . -path ./.git -prune -o -type f -print | sort"
  assert_output "$before_files"
  run cat CLAUDE.local.md
  assert_output "$before_claude"
  run jq -c . .claude/settings.local.json
  assert_output '{"permissions":{"allow":["Bash(make *)"]}}'
  run git config --get task-force.install
  assert_failure
}

@test "task-remove --dry-run names the record and changes nothing" {
  _install
  run "$TASK_REMOVE" --dry-run </dev/null
  assert_success
  assert_output --partial "would remove the task-force block from .git/info/exclude"
  assert_output --partial "would remove .claude/settings.local.json"
  run git config --get task-force.install
  assert_output "local-only"
}

@test "task-config show reports the mode and the local files" {
  _install
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "install   : local-only"
  assert_output --partial "CLAUDE.local.md  (the @.claude/jira-workflow.md import line)"
  assert_output --partial ".claude/settings.local.json  (radio hooks + seeded allow-list)"
}

@test "task-config add assistant kiro is refused on a local-only repo" {
  _install
  run "$TASK_CONFIG" add assistant kiro --yes </dev/null
  assert_failure
  assert_output --partial "kiro cannot be installed local-only"
  assert [ ! -e .kiro ]
}

@test "task-config set assistant kiro is refused before the old loadout is removed" {
  "$CLAUDE_GH_TASK_INIT" --local-only </dev/null >/dev/null
  run "$TASK_CONFIG" set assistant kiro --yes </dev/null
  assert_failure
  assert_output --partial "kiro cannot be installed local-only"
  assert [ -f .claude/gh-workflow.md ]
}

@test "task-config set tracker stays local-only, and the block names the new loadout" {
  _install
  run "$TASK_CONFIG" set tracker gh --yes </dev/null
  assert_success
  run git status --porcelain --untracked-files=all
  assert_output ""
  run grep -xF '/.claude/gh-workflow.md' .git/info/exclude
  assert_success
  run grep -xF '/.claude/jira-workflow.md' .git/info/exclude
  assert_failure
}
