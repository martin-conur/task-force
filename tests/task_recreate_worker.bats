#!/usr/bin/env bats
# Tests for bin/task-recreate-worker — recover a worker whose tab died but whose
# worktree survived (#230).
#
# The scenario under test is a machine restart: the worktree, its branch and
# task-work's `.<slug>.info` sidecar are all still on disk, the zellij tab and the
# radio session file are not, and the sidecar's TAB_ID now points at nothing (or,
# worse, at an unrelated tab in the restarted zellij server).
#
# Asserts:
#   - a fresh tab on the EXISTING worktree, with task-work's role env injected
#   - the sidecar's stale TAB_ID is stripped, then rebound to the new tab
#   - refuses when the worktree is gone (and names task-work)
#   - refuses when a session still looks live, unless --force
#   - the worktree is never created, reused or removed
#
# The loadout is pinned per-test via AW_IMPL (lib/detect-impl.sh resolution
# order: --impl flag > AW_IMPL > workflow-doc auto-detect).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  export ZELLIJ=fake-session
  # The role is built from the SANITIZED main-repo name (lib/repo-name.sh), not
  # the raw basename — a mktemp -d name contains a dot, which is stripped.
  RADIO_REPO_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
  # $WORKTREE_BASE keeps the un-normalized "<repo>/../<repo>-worktrees" form the
  # launchers build; the command prints (and git reports) the physical path, so
  # assertions on printed paths compare against this one.
  WT_PHYS="$(cd "$MAIN_REPO/.." && pwd -P)/${REPO_NAME}-worktrees"
}

teardown() {
  teardown_all
}

# The post-reboot state: worktree + sidecar on disk, TAB_ID stale, no session.
# Deliberately NOT task-work — the point is that this command works on what
# survives a restart, not on state some other command just produced.
dead_worker() {
  local slug="${1:-issue-42}"
  local url="${2:-https://github.com/owner/repo/issues/42}"
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nGH_URL=%s\nTAB_ID=999\n' "$slug" "$url" \
    > "$WORKTREE_BASE/.$slug.info"
}

role_for() { printf 'worker-%s-%s' "$RADIO_REPO_NAME" "$1"; }

# The command string task-recreate-worker handed zellij for a given tab.
launch_cmd_for() {
  grep -m1 -F "new-tab --name $1" "$STUB_CALLS_DIR/zellij.calls"
}

# Register a live radio session for a role, the way a running agent's
# SessionStart hook would.
register_role() {
  "$RADIO" register --role "$1" --tab "$2" --repo "$MAIN_REPO" \
    --agent claude --loadout claude-gh >/dev/null 2>&1
}

queue_mail() {
  local role="$1" id="${2:-abc123}"
  mkdir -p "$TASK_FORCE_HOME/radio/mailbox/$role/inbox"
  printf -- '---\nfrom: pm\nintent: changes-requested\n---\n\nplease fix\n' \
    > "$TASK_FORCE_HOME/radio/mailbox/$role/inbox/$id.md"
}

# ---------------------------------------------------------------------------
# Happy path: rebind the surviving worktree
# ---------------------------------------------------------------------------

@test "opens a tab on the existing worktree and launches the worker agent" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
  run launch_cmd_for issue-42
  assert_output --partial "--cwd $WT_PHYS/issue-42"
  assert_output --partial "/worker Implement task: https://github.com/owner/repo/issues/42"
}

@test "injects the role env task-work injects, so the rebuilt session registers (#229)" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  run launch_cmd_for issue-42
  assert_output --partial "TASK_FORCE_ROLE=$(role_for issue-42)"
  assert_output --partial "ZELLIJ_TAB=issue-42"
  assert_output --partial "TASK_FORCE_PM_ROLE=pm-${RADIO_REPO_NAME}"
}

@test "set +H precedes the env prefix, so the assignments reach the agent" {
  # `VAR=val cmd1; cmd2` scopes the assignments to cmd1: if `set +H;` landed
  # between the prefix and `claude`, radio routing would be silently dead.
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  local cmd_line
  cmd_line=$(launch_cmd_for issue-42)
  [[ "$cmd_line" == *"set +H;"*"TASK_FORCE_ROLE="* ]] || {
    echo "ordering wrong: 'set +H;' must come before 'TASK_FORCE_ROLE=' in: $cmd_line" >&2
    return 1
  }
}

@test "never touches the worktree: branch, files and commits survive untouched" {
  dead_worker issue-42
  echo "in progress" > "$WORKTREE_BASE/issue-42/wip.txt"
  local before
  before=$(git -C "$WORKTREE_BASE/issue-42" rev-parse HEAD)

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert [ -f "$WORKTREE_BASE/issue-42/wip.txt" ]
  assert_equal "$(git -C "$WORKTREE_BASE/issue-42" rev-parse HEAD)" "$before"
  assert_equal "$(git -C "$WORKTREE_BASE/issue-42" rev-parse --abbrev-ref HEAD)" "task/issue-42"
}

@test "accepts the branch form 'task/<slug>' as well as the bare slug" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" task/issue-42
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
}

# ---------------------------------------------------------------------------
# The stale TAB_ID hazard (#188 / #218)
# ---------------------------------------------------------------------------

@test "strips the sidecar's stale TAB_ID rather than trusting it" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  # zellij is stubbed with no tabs, so no new id resolves — the stale one must
  # still be gone. `radio register` adopts TAB_ID from this file when its own
  # name lookup misses (#218), so leaving 999 here would bind the rebuilt role
  # to an unrelated tab in the restarted zellij server.
  run cat "$WORKTREE_BASE/.issue-42.info"
  refute_output --partial "TAB_ID=999"
}

@test "the stale TAB_ID is gone before the tab is spawned, not after" {
  # Ordering matters: the new session's SessionStart can fire before this
  # command gets to write the new id. Proven by a zellij stub that fails the
  # new-tab call — the sidecar must already be clean at that point.
  dead_worker issue-42
  STUB_ZELLIJ_NEW_TAB_FAIL=1 AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  run cat "$WORKTREE_BASE/.issue-42.info"
  refute_output --partial "TAB_ID=999"
}

@test "rebinds TAB_ID to the tab it just opened" {
  dead_worker issue-42
  # seed_zellij_tabs gives the first role tab_id 7. It also makes the liveness
  # guard see a tab named issue-42 (the stub's tab list is static, so "before"
  # and "after" the spawn look identical), hence --force.
  seed_zellij_tabs issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --force
  assert_success
  run cat "$WORKTREE_BASE/.issue-42.info"
  assert_output --partial "TAB_ID=7"
  refute_output --partial "TAB_ID=999"
}

@test "recreates a missing sidecar with SLUG=, so radio can recover the role (#229)" {
  dead_worker issue-42
  rm -f "$WORKTREE_BASE/.issue-42.info"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert [ -f "$WORKTREE_BASE/.issue-42.info" ]
  run cat "$WORKTREE_BASE/.issue-42.info"
  assert_output --partial "SLUG=issue-42"
  assert_output --partial "BASE_BRANCH=main"
}

@test "preserves sidecar keys it does not own" {
  dead_worker issue-42
  printf 'CUSTOM_KEY=keep-me\n' >> "$WORKTREE_BASE/.issue-42.info"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  run cat "$WORKTREE_BASE/.issue-42.info"
  assert_output --partial "CUSTOM_KEY=keep-me"
  assert_output --partial "GH_URL=https://github.com/owner/repo/issues/42"
}

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

@test "refuses when the worktree is gone, and names task-work" {
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" never-existed
  assert_failure
  assert_output --partial "no worktree for slug 'never-existed'"
  assert_output --partial "task-work never-existed"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "refuses a directory that is not a registered worktree of this repo" {
  mkdir -p "$WORKTREE_BASE/orphan-dir"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" orphan-dir
  assert_failure
  assert_output --partial "task-work orphan-dir"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "refuses a detached HEAD: there is no branch to recover onto" {
  dead_worker issue-42
  git -C "$WORKTREE_BASE/issue-42" checkout -q --detach HEAD
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "detached HEAD"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "refuses a reviewer worktree and points at task-reviewer" {
  dead_worker review-pr41
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" review-pr41
  assert_failure
  assert_output --partial "is a reviewer worktree"
  assert_output --partial "task-reviewer 41"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "a worker slug that merely starts with review-pr is still a worker" {
  dead_worker review-print-flow
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" review-print-flow
  assert_success
  assert_stub_called zellij "new-tab --name review-print-flow"
}

@test "refuses when a radio session for the role still looks live" {
  dead_worker issue-42
  register_role "$(role_for issue-42)" issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "still looks live"
  assert_output --partial "--force"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "refuses when a zellij tab of that name is already open" {
  dead_worker issue-42
  seed_zellij_tabs issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "tab named 'issue-42' is open"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "--force proceeds past a live-looking session" {
  dead_worker issue-42
  register_role "$(role_for issue-42)" issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --force
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
}

@test "a session whose heartbeat is >1h stale is not 'live' — that is the case this exists for" {
  dead_worker issue-42
  local role session
  role=$(role_for issue-42)
  register_role "$role" issue-42
  session="$TASK_FORCE_HOME/radio/sessions/$role.info"
  # Age the heartbeat past `radio orphans`' 1h threshold, which is what a
  # session file left behind by a killed tab looks like.
  sed -i.bak 's/^LAST_HEARTBEAT=.*/LAST_HEARTBEAT=2020-01-01T00:00:00Z/' "$session"
  rm -f "$session.bak"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
}

@test "requires exactly one slug" {
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER"
  assert_failure
  assert_output --partial "exactly one <slug> is required"
}

@test "rejects an unknown flag rather than swallowing it" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resmue
  assert_failure
  assert_output --partial "unknown flag '--resmue'"
}

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

@test "reports the role, task URL, base branch and worktree it found" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "role:      $(role_for issue-42)"
  assert_output --partial "https://github.com/owner/repo/issues/42"
  assert_output --partial "task/issue-42 (base: main)"
  assert_output --partial "$WT_PHYS/issue-42"
}

@test "reports unpushed commits when the branch has never been pushed" {
  dead_worker issue-42
  echo change > "$WORKTREE_BASE/issue-42/f.txt"
  git -C "$WORKTREE_BASE/issue-42" add f.txt
  git -C "$WORKTREE_BASE/issue-42" commit -q -m "work"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "1 ahead of main"
  assert_output --partial "branch never pushed"
}

@test "reports how much mail queued while the role was offline" {
  dead_worker issue-42
  queue_mail "$(role_for issue-42)"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "1 unread in inbox"
}

@test "reports dead-lettered mail separately — a register will not redeliver it (#201)" {
  dead_worker issue-42
  mkdir -p "$TASK_FORCE_HOME/radio/dead-letter/$(role_for issue-42)"
  printf -- '---\nfrom: pm\nintent: approved-and-merged\n---\n' \
    > "$TASK_FORCE_HOME/radio/dead-letter/$(role_for issue-42)/old.md"
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "dead-letter: 1 message(s) already archived"
}

@test "reports the existing PR when there is one" {
  dead_worker issue-42
  GH_STUB_PR_URL="https://github.com/owner/repo/pull/7" \
    AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "PR:        https://github.com/owner/repo/pull/7"
}

@test "reports 'none found' when no PR exists yet" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "PR:        none found"
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

@test "--no-launch opens the tab but starts no agent, and says the role stays unwakeable" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --no-launch
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
  assert_output --partial "unwakeable"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "--resume hands over to claude's own session picker, and says so" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_success
  run launch_cmd_for issue-42
  assert_output --partial "claude --resume"
  refute_output --partial "/worker"
  # The role env is still injected — that is what makes the resumed session
  # addressable, which a hand-rolled `claude --resume` in a fresh tab is not.
  assert_output --partial "TASK_FORCE_ROLE=$(role_for issue-42)"
}

# Write the SessionEnd payload line radio logs on an unregister, for <role> in
# <cwd>, naming <session-id> — the shape `--resume` mines for a session id.
log_session_end() {
  local role="$1" cwd="$2" sid="$3" transcript="$4"
  mkdir -p "$TASK_FORCE_HOME/radio"
  printf '%s unregister: proceeding (reason=other) role=%s payload={"session_id":"%s","transcript_path":"%s","cwd":"%s"}\n' \
    "2026-09-28T13:02:33Z" "$role" "$sid" "$transcript" "$cwd" \
    >> "$TASK_FORCE_HOME/radio/log"
}

@test "--resume passes the recovered session id when the log identifies one" {
  dead_worker issue-42
  local sid="70ba59e4-c3ef-4145-a3e1-35a058cc5ed5"
  local transcript="$BATS_TEST_TMPDIR/$sid.jsonl"
  : > "$transcript"
  log_session_end "$(role_for issue-42)" "$WT_PHYS/issue-42" "$sid" "$transcript"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_success
  assert_output --partial "resuming session $sid"
  run launch_cmd_for issue-42
  assert_output --partial "claude --resume $sid"
}

# Same fixture, but reached through a symlinked worktree base — the case where
# the logical and physical spellings of the worktree genuinely differ.
#
# The command builds WORKTREE_DIR as "<parent>/<repo>-worktrees/<slug>", appending
# that middle component as a string, so it is never resolved. git and Claude both
# report the physical target. Every earlier test builds both sides the same way
# and so agrees with any logical/physical bug instead of catching it; these two do
# not. Verified by hand that the two paths really do diverge here before writing
# the assertions, so this cannot quietly become a tautology.
dead_worker_symlinked_base() {
  local slug="${1:-issue-42}"
  local url="${2:-https://github.com/owner/repo/issues/42}"
  SYMLINK_STORE="$BATS_TEST_TMPDIR/worktree-store"
  mkdir -p "$SYMLINK_STORE"
  ln -s "$SYMLINK_STORE" "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nGH_URL=%s\nTAB_ID=999\n' "$slug" "$url" \
    > "$WORKTREE_BASE/.$slug.info"
}

@test "a symlinked worktree base is not mistaken for another repo's worktree" {
  # git reports the physical path; WORKTREE_DIR is the logical one. Comparing the
  # two unresolved refused a perfectly good worktree outright — a hard failure,
  # not a silent one, and the same root cause as the --resume miss below.
  dead_worker_symlinked_base issue-42
  local phys logical
  phys=$(cd "$SYMLINK_STORE/issue-42" && pwd -P)
  logical="$WT_PHYS/issue-42"
  [ "$phys" != "$logical" ] || skip "no logical/physical divergence on this host — nothing to pin"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_stub_called zellij "new-tab --name issue-42"
}

@test "--resume matches a payload whose cwd is the physical path of a symlinked worktree" {
  dead_worker_symlinked_base issue-42
  local phys logical sid transcript
  phys=$(cd "$SYMLINK_STORE/issue-42" && pwd -P)
  logical="$WT_PHYS/issue-42"
  [ "$phys" != "$logical" ] || skip "no logical/physical divergence on this host — nothing to pin"

  sid="70ba59e4-c3ef-4145-a3e1-35a058cc5ed5"
  transcript="$BATS_TEST_TMPDIR/$sid.jsonl"
  : > "$transcript"
  # Claude records the cwd it actually ran in: the PHYSICAL path.
  log_session_end "$(role_for issue-42)" "$phys" "$sid" "$transcript"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_success
  assert_output --partial "resuming session $sid"
  run launch_cmd_for issue-42
  assert_output --partial "claude --resume $sid"
}

@test "--resume ignores a session id logged for a different worktree" {
  # Same role name can exist in another checkout of the same repo; resuming the
  # wrong transcript silently is worse than handing over to the picker.
  dead_worker issue-42
  local sid="70ba59e4-c3ef-4145-a3e1-35a058cc5ed5"
  local transcript="$BATS_TEST_TMPDIR/$sid.jsonl"
  : > "$transcript"
  log_session_end "$(role_for issue-42)" "/somewhere/else/issue-42" "$sid" "$transcript"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_success
  assert_output --partial "No session id was recoverable"
  run launch_cmd_for issue-42
  refute_output --partial "$sid"
}

@test "--resume ignores a session id whose transcript no longer exists" {
  dead_worker issue-42
  local sid="70ba59e4-c3ef-4145-a3e1-35a058cc5ed5"
  log_session_end "$(role_for issue-42)" "$WT_PHYS/issue-42" "$sid" "$BATS_TEST_TMPDIR/gone.jsonl"

  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_success
  assert_output --partial "No session id was recoverable"
  run launch_cmd_for issue-42
  refute_output --partial "$sid"
}

@test "--auto launches in auto permission mode and opts into radio auto-submit" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --auto
  assert_success
  run launch_cmd_for issue-42
  assert_output --partial "--permission-mode auto"
  assert_output --partial "TASK_FORCE_AUTO_SUBMIT=1"
}

@test "without --auto, no auto-submit is injected" {
  dead_worker issue-42
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  run launch_cmd_for issue-42
  refute_output --partial "TASK_FORCE_AUTO_SUBMIT"
  refute_output --partial "--permission-mode auto"
}

@test "--auto keeps focus on the calling tab" {
  dead_worker issue-42
  # An active tab that is NOT this slug: the caller is standing somewhere else,
  # which is the whole reason the snap-back exists.
  export STUB_ZELLIJ_TABS_JSON='[{"name":"pm","tab_id":1,"position":0,"active":true}]'
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --auto
  assert_success
  assert_stub_called zellij "action go-to-tab"
}

@test "--help works outside a configured repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  run "$TASK_RECREATE_WORKER" --help
  assert_success
  assert_output --partial "task-recreate-worker <slug>"
  rm -rf "$outside"
}

# ---------------------------------------------------------------------------
# kiro loadouts
# ---------------------------------------------------------------------------

@test "kiro: launches kiro-cli's worker agent with the same role env" {
  dead_worker issue-42
  AW_IMPL=kiro-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  run launch_cmd_for issue-42
  assert_output --partial "kiro-cli chat --agent worker"
  assert_output --partial "TASK_FORCE_ROLE=$(role_for issue-42)"
}

@test "kiro: refuses --resume rather than pretending to have a picker" {
  dead_worker issue-42
  AW_IMPL=kiro-gh run "$TASK_RECREATE_WORKER" issue-42 --resume
  assert_failure
  assert_output --partial "--resume is claude-only"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

@test "kiro: refuses to launch when the worker agent does not resolve (#218)" {
  dead_worker issue-42
  rm -rf "$MAIN_REPO/.kiro/agents" "$WORKTREE_BASE/issue-42/.kiro/agents"
  HOME="$BATS_TEST_TMPDIR" AW_IMPL=kiro-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "does not resolve"
  run stub_calls zellij
  refute_output --partial "new-tab"
}

# ---------------------------------------------------------------------------
# Doc parity
# ---------------------------------------------------------------------------

# The task-recreate-worker block of a workflow doc: from its heading line up to
# the task-config block that follows it.
recreate_block() {
  awk '/^`task-recreate-worker <slug>/{p=1} p&&/^`task-config show`/{exit} p{print}' "$1"
}

@test "the task-recreate-worker section is byte-identical across all 8 workflow docs" {
  # A recovery command documented in six of seven loadouts is a recovery command
  # the seventh's users never learn exists — the "fix lands in 6 of 7" failure
  # mode tools/check-drift.sh guards for shell, applied to the prose.
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
  local ref other
  ref=$(recreate_block "${docs[0]}")
  [ -n "$ref" ] || { echo "no task-recreate-worker block in ${docs[0]}"; return 1; }
  for doc in "${docs[@]:1}"; do
    other=$(recreate_block "$doc")
    [ "$ref" = "$other" ] || { echo "task-recreate-worker block diverges in $doc"; return 1; }
  done
}

@test "the task-recreate-worker section lives inside task-init's managed region (#212)" {
  # Below the end marker it would be repo-specific content task-init never
  # refreshes, so it would go stale on every upgrade.
  local doc="$REPO_ROOT_REAL/.claude/gh-workflow.md" sec_line end_line
  sec_line=$(grep -n '^`task-recreate-worker <slug>' "$doc" | cut -d: -f1)
  end_line=$(grep -n '^<!-- task-init:managed:end -->$' "$doc" | cut -d: -f1)
  [ -n "$sec_line" ] && [ -n "$end_line" ] || { echo "marker or section missing"; return 1; }
  [ "$sec_line" -lt "$end_line" ] || { echo "section is below the end marker"; return 1; }
}
