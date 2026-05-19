#!/usr/bin/env bats
# Tests for claude-gh/bin/task-work

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# Slug derivation
# ---------------------------------------------------------------------------

@test "free-form slug: lowercase and sanitize" {
  run "$CLAUDE_GH_TASK_WORK" "My Feature Task"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature-task" ]
}

@test "free-form slug: truncated to 50 chars" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..20})  # "abcde" x20 = 100 chars
  run "$CLAUDE_GH_TASK_WORK" "$long_slug"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert [ "${#output}" -le 50 ]
}

@test "github issue URL: derives slug as issue-N" {
  run "$CLAUDE_GH_TASK_WORK" "https://github.com/owner/repo/issues/42"
  assert_success
  assert [ -d "$WORKTREE_BASE/issue-42" ]
}

@test "github issue URL with trailing params: still derives issue number" {
  run "$CLAUDE_GH_TASK_WORK" "https://github.com/owner/repo/issues/99?foo=bar"
  assert_success
  assert [ -d "$WORKTREE_BASE/issue-99" ]
}

@test "explicit slug + URL: slug takes precedence over derived" {
  run "$CLAUDE_GH_TASK_WORK" "my-explicit-slug" "https://github.com/owner/repo/issues/42"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-explicit-slug" ]
}

# ---------------------------------------------------------------------------
# Worktree + branch creation
# ---------------------------------------------------------------------------

@test "creates git worktree on branch task/<slug>" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  local branches
  branches=$(git -C "$MAIN_REPO" branch --list "task/my-feature")
  assert [ -n "$branches" ]
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "parallel session: appends 5-char hash when worktree already exists" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  assert_output --partial "parallel session"
  run bash -c "ls '$WORKTREE_BASE' | grep -c '^my-feature'"
  assert_output "2"
}

@test "branch collision: warns and reuses when task branch already exists" {
  git -C "$MAIN_REPO" branch task/stale-feature
  echo "newer" > "$MAIN_REPO/newfile.txt"
  git -C "$MAIN_REPO" add newfile.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"

  run "$CLAUDE_GH_TASK_WORK" stale-feature
  assert_success
  assert_output --partial "Branch task/stale-feature already exists. Reusing it."
  assert_output --partial "Current HEAD on main"
  assert_output --partial "Divergence:"
  assert_output --partial "0 ahead, 1 behind main"

  local wt_head main_head
  wt_head=$(git -C "$WORKTREE_BASE/stale-feature" rev-parse HEAD)
  main_head=$(git -C "$MAIN_REPO" rev-parse main)
  [[ "$wt_head" != "$main_head" ]]
}

# ---------------------------------------------------------------------------
# --from: fork point override
# ---------------------------------------------------------------------------

@test "no --from: regression — forks from current HEAD (default behavior)" {
  # Advance main by one commit, then ensure the new worktree's HEAD matches main's HEAD.
  echo "advance" > "$MAIN_REPO/advance.txt"
  git -C "$MAIN_REPO" add advance.txt
  git -C "$MAIN_REPO" commit -q -m "advance main"
  local main_head
  main_head=$(git -C "$MAIN_REPO" rev-parse HEAD)

  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/my-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$main_head"
}

@test "--from <local-branch>: forks new branch from that branch's tip" {
  # Create a feature branch one commit ahead of main, then check out main again.
  git -C "$MAIN_REPO" checkout -q -b feature-x
  echo "feature work" > "$MAIN_REPO/feature.txt"
  git -C "$MAIN_REPO" add feature.txt
  git -C "$MAIN_REPO" commit -q -m "feature commit"
  local feature_head
  feature_head=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C "$MAIN_REPO" checkout -q main

  run "$CLAUDE_GH_TASK_WORK" --from feature-x stacked-feature
  assert_success
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/stacked-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$feature_head"
}

@test "--from <local-branch>: --base is independent from --from" {
  git -C "$MAIN_REPO" checkout -q -b feature-y
  echo "feature y" > "$MAIN_REPO/y.txt"
  git -C "$MAIN_REPO" add y.txt
  git -C "$MAIN_REPO" commit -q -m "y"
  git -C "$MAIN_REPO" checkout -q main

  run "$CLAUDE_GH_TASK_WORK" --from feature-y --base main stacked
  assert_success
  source "$WORKTREE_BASE/.stacked.info"
  assert_equal "$BASE_BRANCH" "main"
  # And the worktree HEAD is feature-y's tip, not main's
  local wt_head feat_head
  wt_head=$(git -C "$WORKTREE_BASE/stacked" rev-parse HEAD)
  feat_head=$(git -C "$MAIN_REPO" rev-parse feature-y)
  assert_equal "$wt_head" "$feat_head"
}

@test "--from <remote-ref>: forks from a remote-only branch" {
  # Set up a second repo to act as a remote with a branch not present locally.
  local upstream
  upstream=$(mktemp -d)
  git -C "$upstream" init -q -b main
  git -C "$upstream" config user.email "u@u.local"
  git -C "$upstream" config user.name "U"
  cp "$MAIN_REPO/README.md" "$upstream/README.md"
  git -C "$upstream" add README.md
  git -C "$upstream" commit -q -m "init upstream"
  git -C "$upstream" checkout -q -b upstream-feature
  echo "upstream feature" > "$upstream/u.txt"
  git -C "$upstream" add u.txt
  git -C "$upstream" commit -q -m "upstream feature"
  local upstream_feat_head
  upstream_feat_head=$(git -C "$upstream" rev-parse HEAD)

  git -C "$MAIN_REPO" remote add origin "$upstream"
  git -C "$MAIN_REPO" fetch -q origin

  run "$CLAUDE_GH_TASK_WORK" --from origin/upstream-feature spike
  assert_success
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/spike" rev-parse HEAD)
  assert_equal "$wt_head" "$upstream_feat_head"

  rm -rf "$upstream"
}

@test "--from <unknown-ref>: errors out" {
  run "$CLAUDE_GH_TASK_WORK" --from no-such-ref my-feature
  assert_failure
  assert_output --partial "does not resolve to a commit"
  # No worktree should have been created.
  assert [ ! -d "$WORKTREE_BASE/my-feature" ]
}

@test "--from missing value: errors out" {
  run "$CLAUDE_GH_TASK_WORK" --from
  assert_failure
  assert_output --partial "--from requires a value"
}

@test "-f alias works the same as --from" {
  git -C "$MAIN_REPO" checkout -q -b feature-z
  echo "z" > "$MAIN_REPO/z.txt"
  git -C "$MAIN_REPO" add z.txt
  git -C "$MAIN_REPO" commit -q -m "z"
  local feat_head
  feat_head=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C "$MAIN_REPO" checkout -q main

  run "$CLAUDE_GH_TASK_WORK" -f feature-z forked
  assert_success
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/forked" rev-parse HEAD)
  assert_equal "$wt_head" "$feat_head"
}

# ---------------------------------------------------------------------------
# Auto-refresh: detect a stale local base and fork from origin/<base>
# ---------------------------------------------------------------------------

# Wire up $MAIN_REPO to a bare upstream and advance the upstream's main by
# one commit, leaving local main behind. Prints the upstream's main SHA on
# stdout so callers can assert against it.
_setup_stale_local_base() {
  local upstream
  upstream=$(mktemp -d)
  UPSTREAM_DIR="$upstream"  # export so the test can rm -rf it later
  git -C "$upstream" init -q --bare -b main
  git -C "$MAIN_REPO" remote add origin "$upstream"
  git -C "$MAIN_REPO" push -q origin main
  # Advance upstream main via a sibling clone (no `git pull` in $MAIN_REPO).
  local sibling
  sibling=$(mktemp -d)
  git -C "$sibling" clone -q "$upstream" .
  git -C "$sibling" config user.email "s@s.local"
  git -C "$sibling" config user.name "S"
  echo "remote advance" > "$sibling/remote.txt"
  git -C "$sibling" add remote.txt
  git -C "$sibling" commit -q -m "advance remote main"
  git -C "$sibling" push -q origin main
  local remote_head
  remote_head=$(git -C "$sibling" rev-parse HEAD)
  rm -rf "$sibling"
  echo "$remote_head"
}

@test "stale local base: warns and forks from origin/<base>" {
  local remote_head
  remote_head=$(_setup_stale_local_base)
  local local_head
  local_head=$(git -C "$MAIN_REPO" rev-parse main)
  [[ "$remote_head" != "$local_head" ]]

  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  assert_output --partial "Local 'main' is behind 'origin/main'"
  assert_output --partial "Forking from origin/main"
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/my-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$remote_head"

  rm -rf "$UPSTREAM_DIR"
}

@test "local base ahead of remote: behavior unchanged (no warning, forks from HEAD)" {
  local upstream
  upstream=$(mktemp -d)
  git -C "$upstream" init -q --bare -b main
  git -C "$MAIN_REPO" remote add origin "$upstream"
  git -C "$MAIN_REPO" push -q origin main
  # Local main moves ahead; remote stays put.
  echo "local ahead" > "$MAIN_REPO/local.txt"
  git -C "$MAIN_REPO" add local.txt
  git -C "$MAIN_REPO" commit -q -m "local-only commit"
  local local_head
  local_head=$(git -C "$MAIN_REPO" rev-parse main)

  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  refute_output --partial "is behind"
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/my-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$local_head"

  rm -rf "$upstream"
}

@test "local base matches remote: behavior unchanged (no warning)" {
  local upstream
  upstream=$(mktemp -d)
  git -C "$upstream" init -q --bare -b main
  git -C "$MAIN_REPO" remote add origin "$upstream"
  git -C "$MAIN_REPO" push -q origin main
  local local_head
  local_head=$(git -C "$MAIN_REPO" rev-parse main)

  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  refute_output --partial "is behind"
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/my-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$local_head"

  rm -rf "$upstream"
}

@test "stale local base + --from override: --from wins, no auto-refresh" {
  local remote_head
  remote_head=$(_setup_stale_local_base)
  # Create a local feature branch to fork from.
  git -C "$MAIN_REPO" checkout -q -b feature-w
  echo "w" > "$MAIN_REPO/w.txt"
  git -C "$MAIN_REPO" add w.txt
  git -C "$MAIN_REPO" commit -q -m "w"
  local feat_head
  feat_head=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C "$MAIN_REPO" checkout -q main

  run "$CLAUDE_GH_TASK_WORK" --from feature-w stacked
  assert_success
  refute_output --partial "is behind"
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/stacked" rev-parse HEAD)
  assert_equal "$wt_head" "$feat_head"

  rm -rf "$UPSTREAM_DIR"
}

@test "no remote configured: auto-refresh is a silent no-op" {
  # No origin set on $MAIN_REPO at all — task-work should just work as before.
  local local_head
  local_head=$(git -C "$MAIN_REPO" rev-parse main)

  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  refute_output --partial "is behind"
  local wt_head
  wt_head=$(git -C "$WORKTREE_BASE/my-feature" rev-parse HEAD)
  assert_equal "$wt_head" "$local_head"
}

# ---------------------------------------------------------------------------
# .info file
# ---------------------------------------------------------------------------

@test "writes .info file with BASE_BRANCH=current branch" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  local info="$WORKTREE_BASE/.my-feature.info"
  assert [ -f "$info" ]
  source "$info"
  assert_equal "$BASE_BRANCH" "main"
}

@test "--base flag overrides BASE_BRANCH in .info" {
  run "$CLAUDE_GH_TASK_WORK" --base develop my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$BASE_BRANCH" "develop"
}

@test ".info records GH_URL when URL is provided" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$GH_URL" "$url"
}

@test ".info GH_URL is empty for free-form slugs" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${GH_URL:-}" ""
}

# ---------------------------------------------------------------------------
# Zellij interactions
# ---------------------------------------------------------------------------

@test "opens a new zellij tab named after the slug" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "new-tab --name my-feature"
}

@test "--no-launch: opens tab but does not inject claude command" {
  run "$CLAUDE_GH_TASK_WORK" --no-launch my-feature
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "claude command includes task URL when provided" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "Implement task: $url"
}

@test "claude command uses /worker for free-form slugs" {
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_success
  # Bare `claude "/worker"` (no URL suffix)
  assert_stub_called zellij 'claude "/worker"'
}

# ---------------------------------------------------------------------------
# Permission-mode flags: --plan / --auto (and their mutex)
# ---------------------------------------------------------------------------

@test "--plan: launches claude in plan mode running /planner" {
  run "$CLAUDE_GH_TASK_WORK" --plan my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--plan with URL: passes URL to /planner" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" --plan my-feature "$url"
  assert_success
  assert_stub_called zellij "claude --permission-mode plan \"/planner $url\""
}

@test "-p alias works the same as --plan" {
  run "$CLAUDE_GH_TASK_WORK" -p my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner"'
}

@test "--auto: launches claude in auto mode running /worker" {
  run "$CLAUDE_GH_TASK_WORK" --auto my-feature
  assert_success
  assert_stub_called zellij 'claude --permission-mode auto "/worker"'
}

@test "--auto with URL: keeps /worker Implement task prefix" {
  local url="https://github.com/owner/repo/issues/42"
  run "$CLAUDE_GH_TASK_WORK" --auto my-feature "$url"
  assert_success
  assert_stub_called zellij "claude --permission-mode auto \"/worker Implement task: $url\""
}

@test "--auto --plan: errors out (mutually exclusive)" {
  run "$CLAUDE_GH_TASK_WORK" --auto --plan my-feature
  assert_failure
  assert_output --partial "--auto and --plan are mutually exclusive"
}

@test "--no-launch with --plan: opens tab without invoking claude (mode flag is a no-op)" {
  run "$CLAUDE_GH_TASK_WORK" --no-launch --plan my-feature
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$CLAUDE_GH_TASK_WORK" my-feature
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "fails when --base missing its value" {
  run "$CLAUDE_GH_TASK_WORK" --base
  assert_failure
  assert_output --partial "--base requires a value"
}

@test "fails on unknown flag" {
  run "$CLAUDE_GH_TASK_WORK" --unknown-flag
  assert_failure
}
