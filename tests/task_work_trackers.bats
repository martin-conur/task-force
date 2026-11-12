#!/usr/bin/env bats
# bin/task-work's tracker axis (#237): what lib/trackers/<tracker>.sh decides.
#
# Ref parsing, the slug a ref derives, the .info key, the worker-prompt payload,
# and local's post-worktree bookkeeping. gh's parsing is asserted in
# tests/task_work.bats, which runs as claude-gh; every tracker's .info key is
# also a row in tests/task_work_impls.bats.
#
# Each section pins a loadout with AW_IMPL. The tracker decides everything
# asserted here, so the agent half of the pin is incidental — except where a
# test says otherwise.

bats_require_minimum_version 1.5.0
bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  seed_hook_carriers "$MAIN_REPO"   # role files + hooks the launch copies in (#393)
  setup_stubs
  cd "$MAIN_REPO"
  unset AW_IMPL
}

teardown() {
  teardown_all
}

NOTION_TITLED="https://www.notion.so/My-Feature-abc123def456abc123def456abc123de"

# ---------------------------------------------------------------------------
# notion
# ---------------------------------------------------------------------------

@test "notion: URL with title derives slug from the title segment" {
  run env AW_IMPL=claude-notion "$TASK_WORK" "$NOTION_TITLED"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "notion: bare-hex URL uses the first 8 chars" {
  run env AW_IMPL=claude-notion "$TASK_WORK" "https://www.notion.so/abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/abc123de" ]
}

@test "notion: explicit slug + URL — slug takes precedence over derived" {
  run env AW_IMPL=claude-notion "$TASK_WORK" "my-explicit-slug" "$NOTION_TITLED"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-explicit-slug" ]
}

@test "notion: app.notion.com single-arg derives slug from title segment (#158)" {
  run env AW_IMPL=claude-notion "$TASK_WORK" "https://app.notion.com/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "notion: app.notion.com <slug> <url> records NOTION_URL in .info (#158)" {
  local url="https://app.notion.com/My-Feature-abc123def456abc123def456abc123de"
  run env AW_IMPL=claude-notion "$TASK_WORK" my-feature "$url"
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "$NOTION_URL" "$url"
}

@test "notion: false-positive guard — a slug containing 'notion.com' is not a URL (#158)" {
  # A free-form slug that merely contains "notion.com" must NOT be treated as a
  # URL — the real app.notion.com arg must win and land in NOTION_URL.
  local url="https://app.notion.com/Real-Page-abc123def456abc123def456abc123de"
  run env AW_IMPL=claude-notion "$TASK_WORK" "my-notion.com-feature" "$url"
  assert_success
  source "$WORKTREE_BASE/.my-notioncom-feature.info"
  assert_equal "$NOTION_URL" "$url"
}

@test "notion: notion.site subdomain URL still recognized (#158)" {
  run env AW_IMPL=claude-notion "$TASK_WORK" "https://myworkspace.notion.site/My-Feature-abc123def456abc123def456abc123de"
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
}

@test "notion: .info NOTION_URL is empty for free-form slugs" {
  run env AW_IMPL=claude-notion "$TASK_WORK" my-feature --no-task
  assert_success
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${NOTION_URL-unset}" ""
}

@test "notion: worker prompt is 'Implement task: <url>'" {
  run env AW_IMPL=claude-notion "$TASK_WORK" my-feature "$NOTION_TITLED"
  assert_success
  assert_stub_called zellij "claude \"/worker Implement task: $NOTION_TITLED\""
}

# kiro-notion's usage example used to show a 12-hex suffix, which the 32-hex
# branch of the slug rule never matches (#237 declared change 5).
@test "notion: every --help example URL derives a slug from its page id" {
  local impl url
  for impl in claude-notion kiro-notion; do
    run env AW_IMPL="$impl" "$TASK_WORK" --help
    assert_success
    for url in $(printf '%s\n' "$output" | grep -oE 'https://www\.notion\.so/[^" ]+'); do
      [[ "$url" =~ (^|[/-])[a-f0-9]{32}$ ]] || {
        echo "$impl: help example '$url' has no 32-hex page id" >&2; return 1; }
    done
  done
}

# ---------------------------------------------------------------------------
# jira
# ---------------------------------------------------------------------------

@test "jira: bare key derives a lowercase slug and sets JIRA_REF" {
  run env AW_IMPL=claude-jira "$TASK_WORK" PROJ-123
  assert_success
  assert [ -d "$WORKTREE_BASE/proj-123" ]
  source "$WORKTREE_BASE/.proj-123.info"
  assert_equal "$JIRA_REF" "PROJ-123"
}

@test "jira: URL extracts the key and sets JIRA_REF to the full URL" {
  local url="https://acme.atlassian.net/browse/PROJ-456"
  run env AW_IMPL=claude-jira "$TASK_WORK" "$url"
  assert_success
  assert [ -d "$WORKTREE_BASE/proj-456" ]
  source "$WORKTREE_BASE/.proj-456.info"
  assert_equal "$JIRA_REF" "$url"
}

@test "jira: free-form slug has no JIRA_REF" {
  run env AW_IMPL=claude-jira "$TASK_WORK" add-store-filtering --no-task
  assert_success
  assert [ -d "$WORKTREE_BASE/add-store-filtering" ]
  source "$WORKTREE_BASE/.add-store-filtering.info"
  assert_equal "${JIRA_REF-unset}" ""
}

@test "jira: an over-long key's slug is truncated to 50 chars" {
  local long_input
  long_input="$(printf 'A%.0s' {1..60})-1"
  run env AW_IMPL=claude-jira "$TASK_WORK" "$long_input"
  assert_success
  run bash -c "ls '$WORKTREE_BASE' | head -1"
  assert_equal "${#output}" 50
}

@test "jira: worker prompt is 'Implement Jira issue: <ref>'" {
  run env AW_IMPL=claude-jira "$TASK_WORK" PROJ-10
  assert_success
  assert_stub_called zellij 'claude "/worker Implement Jira issue: PROJ-10"'
}

@test "jira: --plan passes the bare key to /planner" {
  run env AW_IMPL=claude-jira "$TASK_WORK" --plan PROJ-10
  assert_success
  assert_stub_called zellij 'claude --permission-mode plan "/planner PROJ-10"'
}

@test "jira: --auto keeps the 'Implement Jira issue' payload" {
  run env AW_IMPL=claude-jira "$TASK_WORK" --auto PROJ-10
  assert_success
  assert_stub_called zellij 'claude --permission-mode auto "/worker Implement Jira issue: PROJ-10"'
}

# What claude-jira gains by running the shared body (#237 declared change 1).
# Each of these failed against the deleted claude-jira/bin/task-work.

@test "jira: <slug> <ref> form, in either order" {
  run env AW_IMPL=claude-jira "$TASK_WORK" my-slug PROJ-7
  assert_success
  source "$WORKTREE_BASE/.my-slug.info"
  assert_equal "$JIRA_REF" "PROJ-7"

  run env AW_IMPL=claude-jira "$TASK_WORK" PROJ-8 other-slug
  assert_success
  source "$WORKTREE_BASE/.other-slug.info"
  assert_equal "$JIRA_REF" "PROJ-8"
}

@test "jira: --no-launch opens the tab without starting claude" {
  run env AW_IMPL=claude-jira "$TASK_WORK" --no-launch PROJ-9
  assert_success
  assert_output --partial "claude NOT launched"
  run grep -F "claude " "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "jira: --help exits 0" {
  run env AW_IMPL=claude-jira "$TASK_WORK" --help
  assert_success
  assert_output --partial "<jira-key-or-url>"
}

@test "jira: '--' passes a dash-leading positional through as the slug" {
  run env AW_IMPL=claude-jira "$TASK_WORK" --no-task -- -dash-slug
  assert_success
  assert [ -d "$WORKTREE_BASE/-dash-slug" ]
}

@test "jira: 'not in a git repo' goes to stderr" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr env AW_IMPL=claude-jira "$TASK_WORK" PROJ-1
  assert_failure
  assert_equal "$output" ""
  [[ "$stderr" == *"not in a git repo"* ]] || { echo "stderr: $stderr" >&2; return 1; }
}

@test "jira: an underivable slug is reported before a missing repo" {
  # Both errors apply; the shared body checks the slug first (#237 declared
  # change 2 — claude-jira used to do repo discovery first).
  cd "$BATS_TEST_TMPDIR"
  run env AW_IMPL=claude-jira "$TASK_WORK" '!!!'
  assert_failure
  assert_output --partial "could not derive a slug from input"
  refute_output --partial "not in a git repo"
}

@test "jira: completion message uses the shared 'Started worker in' wording" {
  run env AW_IMPL=claude-jira "$TASK_WORK" PROJ-11
  assert_success
  assert_output --partial "Started worker in "
  refute_output --partial "Worker started in"
}

# ---------------------------------------------------------------------------
# local
# ---------------------------------------------------------------------------

# Mark $MAIN_REPO as an <impl> repo: the sibling-fallback task-board is the root
# one (#238), which detects the loadout before rendering.
_seed_local() {
  local impl="$1"
  mkdir -p "$MAIN_REPO/tasks"
  seed_hook_carriers "$MAIN_REPO"   # role files + hooks the launch copies in (#393)
  case "$impl" in
    claude-local) mkdir -p "$MAIN_REPO/.claude"; touch "$MAIN_REPO/.claude/local-workflow.md" ;;
    kiro-local)   mkdir -p "$MAIN_REPO/.kiro/steering"; touch "$MAIN_REPO/.kiro/steering/local-workflow.md" ;;
  esac
}

# Helper: create a task file with frontmatter.
_make_task_file() {
  local path="$1" id="$2" title="$3" status="${4:-todo}"
  cat > "$path" <<EOF
---
id: $id
title: $title
status: $status
priority: P2
tags: []
created: 2026-05-15
branch: ""
pr: ""
---

## Problem

A test problem.
EOF
}

@test "local: task file path derives slug by stripping NNN- and .md" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "local: task file works with an absolute path" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/042-refactor-auth.md" 042 "Refactor auth"
  run env AW_IMPL=claude-local "$TASK_WORK" "$MAIN_REPO/tasks/042-refactor-auth.md"
  assert_success
  assert [ -d "$WORKTREE_BASE/refactor-auth" ]
}

@test "local: free-form slug still works without a task file" {
  _seed_local claude-local
  run env AW_IMPL=claude-local "$TASK_WORK" my-feature
  assert_success
  assert [ -d "$WORKTREE_BASE/my-feature" ]
  source "$WORKTREE_BASE/.my-feature.info"
  assert_equal "${TASK_FILE-unset}" ""
}

@test "local: .info records TASK_FILE as an absolute path" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  source "$WORKTREE_BASE/.add-login.info"
  assert_equal "$TASK_FILE" "$MAIN_REPO/tasks/001-add-login.md"
}

@test "local: writes an entry to .git/task-force/state.json" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/.git/task-force/state.json" ]
  run grep -F '"slug":"add-login"' "$MAIN_REPO/.git/task-force/state.json"
  assert_success
}

@test "local: state.json entry carries branch, worktree, started_at, task_file" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  local line
  line=$(cat "$MAIN_REPO/.git/task-force/state.json")
  # Each check returns explicitly: a bare `[[ ]]` that is not a test's last
  # line does not fail it, which is how this test once passed with every field
  # but the last one broken.
  [[ "$line" == *'"branch":"task/add-login"'* ]] || { echo "branch: $line" >&2; return 1; }
  # The worktree path is built from git's (physical) toplevel, so on macOS it
  # reads /private/var where $MAIN_REPO reads /var.
  local phys
  phys="$(cd "$MAIN_REPO" && pwd -P)/../$REPO_NAME-worktrees/add-login"
  [[ "$line" == *"\"worktree\":\"$phys\""* ]] || { echo "worktree: $line" >&2; return 1; }
  [[ "$line" =~ \"started_at\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\" ]] || { echo "started_at: $line" >&2; return 1; }
  [[ "$line" == *"\"task_file\":\"$MAIN_REPO/tasks/001-add-login.md\""* ]] || { echo "task_file: $line" >&2; return 1; }
}

@test "local: a second run on the same task adds a parallel-session entry" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  # Second run creates a parallel session with a -HASH suffix, so the two
  # state.json entries have distinct slugs.
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  local n
  n=$(grep -c '"slug"' "$MAIN_REPO/.git/task-force/state.json")
  assert_equal "$n" "2"
}

@test "local: regenerates tasks/_board.md after creating the worktree" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
  # Task should appear in the In Progress section because state.json overrides
  # the frontmatter "todo" status.
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output --partial "In Progress"
  assert_output --partial "Add login"
}

# The post-worktree hook is the tracker's, so it must fire whichever agent the
# loadout pairs it with — the two local copies used to carry it separately.
@test "local: state.json and the board are written under both local loadouts" {
  local impl n=0
  for impl in claude-local kiro-local; do
    n=$((n + 1))
    rm -rf "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering" "$MAIN_REPO/tasks/_board.md"
    _seed_local "$impl"
    _make_task_file "$MAIN_REPO/tasks/00$n-$impl.md" "00$n" "Task $impl"
    run env AW_IMPL="$impl" "$TASK_WORK" "tasks/00$n-$impl.md"
    assert_success
    run grep -F "\"slug\":\"$impl\"" "$MAIN_REPO/.git/task-force/state.json"
    assert_success
    run cat "$MAIN_REPO/tasks/_board.md"
    assert_output --partial "Task $impl"
  done
}

# task-work resolves task-board from $PATH first and only then from its own
# sibling copy. The suite runs with $PATH out of reach of ~/.local/bin (#223), so
# without this the $PATH branch would be exercised by nobody on any machine —
# which is the state the bug grew in. Test it on purpose instead.
@test "local: board regen prefers \$PATH's task-board over the sibling copy" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  local bin="$BATS_TEST_TMPDIR/path-bin"
  mkdir -p "$bin"
  cat > "$bin/task-board" <<'BOARD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS_DIR/task-board.calls"
mkdir -p "$2/tasks"
echo "rendered by the PATH copy" > "$2/tasks/_board.md"
BOARD
  chmod +x "$bin/task-board"

  PATH="$bin:$PATH" run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called task-board "--repo $(cd "$MAIN_REPO" && pwd -P)"
  run cat "$MAIN_REPO/tasks/_board.md"
  assert_output "rendered by the PATH copy"
}

# A task-board that fails must say so. $PATH takes precedence over the sibling
# copy, so ~/.local/bin's symlink into another checkout is what runs on an
# installed machine — and under the `|| true` this replaces, its failure produced
# no output at all, only a board that silently never appeared (#223).
@test "local: a failing task-board is loud, and does not sink task-work" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  local bin="$BATS_TEST_TMPDIR/foreign-bin"
  mkdir -p "$bin"
  cat > "$bin/task-board" <<'BOARD'
#!/usr/bin/env bash
echo "Error: no workflow doc found (foreign checkout)" >&2
exit 1
BOARD
  chmod +x "$bin/task-board"

  PATH="$bin:$PATH" run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  # The worktree and tab are what task-work is for; a board that did not render
  # is a warning, not a reason to abort after they exist.
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
  assert_output --partial "task-board failed"
  assert_output --partial "$bin/task-board"
  # The failing copy's own diagnostics reach the user rather than /dev/null.
  assert_output --partial "no workflow doc found"
  # And it names this checkout's own copy as the way to render it by hand.
  assert_output --partial "$TASK_BOARD --repo"
  assert [ ! -f "$MAIN_REPO/tasks/_board.md" ]
}

# claude-local used to send `/worker <file>` while kiro-local sent
# `Implement task: <file>` — same tracker, different text (#237 declared
# change 3). The payload is the tracker's now; only the wrapper is the agent's.
@test "local: the worker payload is the same on both agents, only the wrapper differs" {
  local file="$MAIN_REPO/tasks/001-add-login.md"
  _seed_local claude-local
  _make_task_file "$file" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "claude \"/worker Implement task: $file\""

  rm -rf "$MAIN_REPO/.claude"
  _seed_local kiro-local
  : > "$STUB_CALLS_DIR/zellij.calls"
  run env AW_IMPL=kiro-local "$TASK_WORK" "$file"
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker --model claude-opus-5.5 --tui \"Implement task: $file\""
}

@test "local: --plan passes the bare file path to /planner" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/001-add-login.md" 001 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" --plan tasks/001-add-login.md
  assert_success
  assert_stub_called zellij "claude --permission-mode plan \"/planner $MAIN_REPO/tasks/001-add-login.md\""
}

# ---------------------------------------------------------------------------
# Slug guard and the no-ref refusal (#371)
# ---------------------------------------------------------------------------
#
# A zsh loop passed `"<slug> <url>"` as ONE argument: sanitizing folded the URL
# into a 50-char slug, the sidecar got an empty ref, and the agent launched
# with no spec. Every refusal here must leave nothing behind.

NOTION_APP="https://app.notion.com/p/410d9a72260f81a89abc123def456abc"

# Nothing exists: no task/* branch, no worktree directory, no .info sidecar, no
# tab opened, no radio session or sidecar.
_assert_nothing_created() {
  run git -C "$MAIN_REPO" branch --list 'task/*'
  assert_output ""
  assert [ ! -e "$WORKTREE_BASE" ]
  run stub_calls zellij
  refute_output --partial "new-tab"
  run bash -c "ls -A '$TASK_FORCE_HOME/radio/sessions' 2>/dev/null"
  assert_output ""
}

@test "guard: '<slug> <url>' as one argument refuses with the split, on every URL tracker" {
  setup_task_force_home
  local impl ref
  for impl in claude-notion kiro-notion claude-jira claude-gh kiro-gh; do
    case "$impl" in
      *-notion) ref="$NOTION_APP" ;;
      *-jira)   ref="https://acme.atlassian.net/browse/PROJ-7" ;;
      *-gh)     ref="https://github.com/owner/repo/issues/42" ;;
    esac
    run env AW_IMPL="$impl" "$TASK_WORK" "legal-texts-v2 $ref" --base main
    assert_failure
    assert_output --partial "slug looks like \"legal-texts-v2 $ref\" passed as one argument — did you mean: task-work legal-texts-v2 $ref?"
    _assert_nothing_created
  done
}

@test "guard: a slug with whitespace and no ref in it refuses" {
  setup_task_force_home
  run env AW_IMPL=claude-notion "$TASK_WORK" "my feature" --no-task
  assert_failure
  assert_output --partial "contains whitespace"
  _assert_nothing_created
}

@test "guard: a URL this tracker does not read refuses rather than becoming a slug" {
  setup_task_force_home
  local impl url
  for impl in claude-notion claude-jira claude-gh; do
    for url in "https://example.com/some/page" "github.com/owner/repo/pull/3" \
               "www.notion.so/My-Page-abc123def456abc123def456abc123de" "acme.atlassian.net/jira/x"; do
      # Skip the one shape that IS a ref here.
      [[ "$impl" == claude-notion && "$url" == www.notion.so/* ]] && continue
      run env AW_IMPL="$impl" "$TASK_WORK" "$url" --no-task
      assert_failure
      assert_output --partial "looks like a URL"
      _assert_nothing_created
    done
  done
}

@test "guard: a local task file with a space in its name still launches" {
  _seed_local claude-local
  _make_task_file "$MAIN_REPO/tasks/003-add login.md" 003 "Add login"
  run env AW_IMPL=claude-local "$TASK_WORK" "tasks/003-add login.md"
  assert_success
  assert [ -d "$WORKTREE_BASE/add-login" ]
}

@test "no ref: notion, jira and gh refuse a bare slug without --no-task" {
  setup_task_force_home
  local impl
  for impl in claude-notion kiro-notion claude-jira claude-gh kiro-gh; do
    run env AW_IMPL="$impl" "$TASK_WORK" my-feature
    assert_failure
    assert_output --partial "no task ref for 'my-feature'"
    assert_output --partial "--no-task"
    _assert_nothing_created
  done
}

@test "no ref: --no-task proceeds and records an empty ref" {
  local impl key
  for impl in claude-notion claude-jira claude-gh; do
    case "$impl" in
      *-notion) key=NOTION_URL ;; *-jira) key=JIRA_REF ;; *-gh) key=GH_URL ;;
    esac
    run env AW_IMPL="$impl" "$TASK_WORK" "spike-${impl##*-}" --no-task
    assert_success
    assert [ -d "$WORKTREE_BASE/spike-${impl##*-}" ]
    run grep -x "${key}=" "$WORKTREE_BASE/.spike-${impl##*-}.info"
    assert_success
  done
}

@test "no ref: --no-task with a ref is refused as contradictory" {
  setup_task_force_home
  run env AW_IMPL=claude-notion "$TASK_WORK" my-feature "$NOTION_TITLED" --no-task
  assert_failure
  assert_output --partial "--no-task given with a task ref"
  _assert_nothing_created
}

@test "no ref: claude --plan needs no ref — the planner writes the spec" {
  local impl
  for impl in claude-notion claude-jira claude-gh; do
    run env AW_IMPL="$impl" "$TASK_WORK" "plan-${impl##*-}" --plan
    assert_success
    assert_stub_called zellij "claude --permission-mode plan \"/planner\""
  done
}

@test "no ref: --no-launch needs no ref — no agent starts" {
  local impl
  for impl in claude-notion kiro-notion claude-jira claude-gh kiro-gh; do
    run env AW_IMPL="$impl" "$TASK_WORK" "idle-${impl}" --no-launch
    assert_success
    assert [ -d "$WORKTREE_BASE/idle-${impl}" ]
  done
}

@test "no ref: local takes a free-form slug without --no-task" {
  local impl
  for impl in claude-local kiro-local; do
    rm -rf "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro"
    [[ "$impl" == kiro-* ]] && setup_kiro_agents
    _seed_local "$impl"
    run env AW_IMPL="$impl" "$TASK_WORK" "free-${impl}"
    assert_success
    assert [ -d "$WORKTREE_BASE/free-${impl}" ]
  done
}

@test "a slug over 50 characters warns that it was truncated" {
  local long_slug
  long_slug=$(printf 'abcde%.0s' {1..12})   # 60 chars
  run env AW_IMPL=claude-notion "$TASK_WORK" "$long_slug" --no-task
  assert_success
  assert_output --partial "slug truncated to 50 characters: ${long_slug:0:50} (was 60)"
  assert [ -d "$WORKTREE_BASE/${long_slug:0:50}" ]
}
