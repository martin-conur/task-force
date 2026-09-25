#!/usr/bin/env bash
# Shared setup/teardown helpers for all test suites.
# Source this from the setup() / teardown() functions in each .bats file.
# shellcheck disable=SC2034  # path vars are used by the .bats files that load this helper

REPO_ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Radio-home isolation guard (#203). Every suite loads this helper, so this is
# the chokepoint that catches a file (or a bats invocation that never picked up
# tests/setup_suite.bash) about to drive the developer's live ~/.task-force.
# shellcheck source=tests/helpers/radio_home.bash
source "$REPO_ROOT_REAL/tests/helpers/radio_home.bash"
# bats sources every file once with BATS_TEST_NAME=source to gather test names,
# and that pass runs *before* setup_suite — so an unset $TASK_FORCE_HOME proves
# nothing there. A home that is set but points at the real one is wrong on any
# pass.
if [[ -n "${TASK_FORCE_HOME:-}" || "${BATS_TEST_NAME:-}" != source ]]; then
  require_isolated_task_force_home || exit 1
fi

KIRO_TASK_WORK="$REPO_ROOT_REAL/kiro-notion/bin/task-work"
JIRA_TASK_WORK="$REPO_ROOT_REAL/claude-jira/bin/task-work"
KIRO_TASK_DONE="$REPO_ROOT_REAL/kiro-notion/bin/task-done"
JIRA_TASK_DONE="$REPO_ROOT_REAL/claude-jira/bin/task-done"
JIRA_TASK_INIT="$REPO_ROOT_REAL/claude-jira/bin/task-init"
TASK_INIT_DISPATCHER="$REPO_ROOT_REAL/task-init"
TASK_WORK_DISPATCHER="$REPO_ROOT_REAL/bin/task-work"
TASK_DONE_DISPATCHER="$REPO_ROOT_REAL/bin/task-done"
TASK_BOARD_DISPATCHER="$REPO_ROOT_REAL/bin/task-board"
JIRA_TEMPLATE="$REPO_ROOT_REAL/claude-jira/steering/jira-workflow.example.md"
CLAUDE_NOTION_TASK_WORK="$REPO_ROOT_REAL/claude-notion/bin/task-work"
CLAUDE_NOTION_TASK_DONE="$REPO_ROOT_REAL/claude-notion/bin/task-done"
CLAUDE_NOTION_TASK_INIT="$REPO_ROOT_REAL/claude-notion/bin/task-init"
CLAUDE_NOTION_TEMPLATE="$REPO_ROOT_REAL/claude-notion/steering/notion-workflow.example.md"
KIRO_TASK_INIT="$REPO_ROOT_REAL/kiro-notion/bin/task-init"
KIRO_TEMPLATE="$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
CLAUDE_GH_TASK_WORK="$REPO_ROOT_REAL/claude-gh/bin/task-work"
CLAUDE_GH_TASK_DONE="$REPO_ROOT_REAL/claude-gh/bin/task-done"
CLAUDE_GH_TASK_INIT="$REPO_ROOT_REAL/claude-gh/bin/task-init"
CLAUDE_GH_TEMPLATE="$REPO_ROOT_REAL/claude-gh/steering/gh-workflow.example.md"
KIRO_GH_TASK_WORK="$REPO_ROOT_REAL/kiro-gh/bin/task-work"
KIRO_GH_TASK_DONE="$REPO_ROOT_REAL/kiro-gh/bin/task-done"
KIRO_GH_TASK_INIT="$REPO_ROOT_REAL/kiro-gh/bin/task-init"
KIRO_GH_TEMPLATE="$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
CLAUDE_LOCAL_TASK_WORK="$REPO_ROOT_REAL/claude-local/bin/task-work"
CLAUDE_LOCAL_TASK_DONE="$REPO_ROOT_REAL/claude-local/bin/task-done"
CLAUDE_LOCAL_TASK_INIT="$REPO_ROOT_REAL/claude-local/bin/task-init"
CLAUDE_LOCAL_TASK_BOARD="$REPO_ROOT_REAL/claude-local/bin/task-board"
CLAUDE_LOCAL_TEMPLATE="$REPO_ROOT_REAL/claude-local/steering/local-workflow.example.md"
KIRO_LOCAL_TASK_WORK="$REPO_ROOT_REAL/kiro-local/bin/task-work"
KIRO_LOCAL_TASK_DONE="$REPO_ROOT_REAL/kiro-local/bin/task-done"
KIRO_LOCAL_TASK_INIT="$REPO_ROOT_REAL/kiro-local/bin/task-init"
KIRO_LOCAL_TASK_BOARD="$REPO_ROOT_REAL/kiro-local/bin/task-board"
KIRO_LOCAL_TEMPLATE="$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
# radio / task-pm / task-reviewer are canonical root binaries (#170). Tests
# pin a loadout by prefixing `AW_IMPL=<impl>` on the `run` invocation; the
# kiro-gh task-reviewer is still a per-loadout file (kiro parity is #146).
RADIO="$REPO_ROOT_REAL/bin/radio"
# Captured Claude Code SessionEnd hook payloads (#187). Tests feed these to
# `radio unregister` on stdin instead of hand-building JSON — see
# tests/fixtures/hook-payloads/README.md for provenance and counts.
HOOK_PAYLOADS="$REPO_ROOT_REAL/tests/fixtures/hook-payloads"

# Build a PATH directory holding everything radio needs *except* jq, so the
# jq-less fail-safe branches can be exercised (#172 for stop-hook, #192 for
# unregister). Prints the dir; the caller is responsible for removing it.
make_nojq_bin() {
  local d cmd
  d=$(mktemp -d)
  for cmd in bash cat mkdir mv rm awk grep cut head tr date dirname basename ls sed env; do
    ln -s "$(command -v "$cmd")" "$d/$cmd"
  done
  printf '%s' "$d"
}
# The fd `script` should inherit on stdin (#207).
#
# `script` allocates the pty for its *child*, but it first calls tcgetattr() on
# its own fd 0 to copy the invoking terminal's attributes onto it. What that fd
# is decides whether it survives the call:
#
#   tty              tcgetattr succeeds                     -> fine
#   pipe, /dev/null  ENOTTY, which `script` tolerates       -> fine
#   socket           ENOTSOCK/EOPNOTSUPP, which it does not -> aborts with
#                    "script: tcgetattr/ioctl: Operation not supported on socket"
#
# An agent harness (and anything else that wires a runner's stdin to a socket)
# hands the suite the third row, so the pty tests fail for a reason that has
# nothing to do with what they assert — and because the same harness hands out
# a character device on other invocations, they fail only sometimes, which is
# the worst version of it: it teaches whoever runs the suite to discount red.
# So don't inherit fd 0 at all. Prefer a real terminal where the host has one;
# fall back to /dev/null, which `script` tolerates and which still yields a
# genuine pty for the child — `[[ -t 0 ]]` inside the command is TRUE either
# way, so coverage of the #198 branch is not what is being traded here.
pty_stdin() {
  # stderr is silenced *before* the open is attempted: redirections apply
  # left to right, so `: < /dev/tty 2>/dev/null` still prints the failure.
  if : 2>/dev/null < /dev/tty; then printf '/dev/tty'; else printf '/dev/null'; fi
}

# Run `bash -c "$1"` with a real pty on stdin, so `[[ -t 0 ]]` inside the
# command under test is TRUE (#198: the unregister guard now uses that test to
# decide whether a skip is announced on stderr, and #187's tty bypass can only
# be regression-tested from a terminal). `script` is the portable-enough pty
# allocator, but its two flavors disagree on argument order, and CI runs both:
#   util-linux (ubuntu): script -qec "<cmd>" /dev/null
#   BSD       (macOS):   script -q /dev/null <cmd> <args...>
# Both propagate the child's exit status with these flags, so `run pty_run …`
# keeps working with assert_success / assert_failure. stdout and stderr are
# merged by the pty; redirect stderr inside "$1" when a test needs to prove
# which channel a line came out on. Prints the child's output verbatim except
# for the CR that a pty appends to every line, which is stripped so
# assert_output --partial matches behave as they do off-pty.
#
# Guard the pty-dependent tests with `require_pty` rather than calling this
# blind: on a host where no pty can be allocated at all, `script`'s own error
# is what `run` captures, and it reads as the command under test failing.
pty_run() {
  local cmd="$1" out rc=0 stdin
  stdin=$(pty_stdin)
  if script --version 2>/dev/null | grep -qi util-linux; then
    out=$(script -qec "$cmd" /dev/null <"$stdin") || rc=$?
  else
    out=$(script -q /dev/null bash -c "$cmd" <"$stdin") || rc=$?
  fi
  # On the /dev/null arm `script` closes the pty's input immediately, and the
  # pty echoes that EOF back as a literal "^D" followed by the two backspaces
  # that would erase it on a screen. It is the terminal talking, not the child,
  # so drop it rather than let it prefix assert_output matches.
  out=${out#$'^D\b\b'}
  printf '%s' "$out" | tr -d '\r'
  return "$rc"
}

# `skip` with a stated reason when this host cannot give `script` a pty at all.
# Call it at the top of a test, before `run pty_run …` — bats' `skip` has no
# effect from inside `run`.
#
# The probe is the real thing, not a version check: it asks `script` for a pty
# and requires the child to confirm it saw one on stdin. Anything short of that
# skips, and the reason is printed — a silent skip would be worse than the
# flake it replaces, since "not run" and "passed" then look identical (#207).
# Both CI runners can allocate a pty, so the #198 tty branch stays genuinely
# exercised where it counts; if you see this skip in CI, that is the bug.
require_pty() {
  local out rc=0
  command -v script >/dev/null 2>&1 \
    || skip "no \`script\` on PATH: cannot allocate a pty for the #198 tty branch"
  out=$(pty_run '[ -t 0 ] && printf pty-ok' 2>&1) || rc=$?
  case "$out" in
    *pty-ok*) return 0 ;;
  esac
  skip "no pty available here (stdin=$(pty_stdin), script rc=$rc, said: ${out:-<nothing>}) -- the #198 tty branch is still exercised wherever one can be allocated, including both CI runners"
}

TASK_PM="$REPO_ROOT_REAL/bin/task-pm"
TASK_REVIEWER="$REPO_ROOT_REAL/bin/task-reviewer"
TASK_REVIEWER_KIRO="$REPO_ROOT_REAL/kiro-gh/bin/task-reviewer"

# Creates a temp directory with a git repo, sets up $MAIN_REPO,
# $REPO_NAME, and $WORKTREE_BASE.
setup_repo() {
  MAIN_REPO=$(mktemp -d)
  REPO_NAME=$(basename "$MAIN_REPO")
  WORKTREE_BASE="${MAIN_REPO}/../${REPO_NAME}-worktrees"

  git -C "$MAIN_REPO" init -q -b main
  git -C "$MAIN_REPO" config user.email "test@test.local"
  git -C "$MAIN_REPO" config user.name "Test"
  touch "$MAIN_REPO/README.md"
  git -C "$MAIN_REPO" add README.md
  git -C "$MAIN_REPO" commit -q -m "init"
}

# Seeds .kiro/agents/*.json, modelling a repo that has been task-init'd for a
# kiro loadout. The kiro launchers refuse to spawn when the agent they name does
# not resolve (#218): kiro-cli does not fail on an unresolvable --agent, it falls
# back to a hookless built-in, which is precisely how radio came to be dead on
# kiro. Call this from any test that runs a kiro task-work / task-reviewer.
#
# Opt-in rather than folded into setup_repo on purpose: several task-init tests
# assert that .kiro/agents does NOT exist for a given scope, and a shared fixture
# that pre-creates it makes those assertions vacuous.
# Usage: setup_kiro_agents [repo_dir]   (defaults to $MAIN_REPO)
setup_kiro_agents() {
  local dir="${1:-$MAIN_REPO}" a
  mkdir -p "$dir/.kiro/agents"
  for a in worker pm planner reviewer; do
    printf '{"name":"%s","description":"test fixture","prompt":"","tools":[],"allowedTools":[]}\n' \
      "$a" > "$dir/.kiro/agents/$a.json"
  done
}

# Creates a git worktree + .info file, simulating what task-work would do.
# Usage: setup_worktree <slug> [base_branch]
setup_worktree() {
  local slug="$1"
  local base="${2:-main}"
  local branch="task/$slug"

  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "$branch"

  printf 'BASE_BRANCH=%s\nSLUG=%s\nNOTION_URL=\n' "$base" "$slug" \
    > "$WORKTREE_BASE/.$slug.info"
}

# Drop the radio identity env a task-force agent tab exports into every child.
# The suite is routinely run from inside such a tab (`./run_tests.sh` from a
# worker or PM), so without this these leak in as ambient defaults and make
# assertions depend on who launched the run. Concretely: from a PM/worker tab
# whose $TASK_FORCE_PM_ROLE is set, the `--to pm` shim (#165) resolved to that
# repo's pm-<reponame> instead of the literal `pm` the radio / radio_lifecycle
# tests address, and from a `task-work --auto` worker the radio_auto_submit
# "omits AUTO_SUBMIT when the env var is unset" tests failed because the var
# was not, in fact, unset. Every test that needs one of these sets it
# explicitly per-invocation, after setup.
reset_radio_env() {
  unset TASK_FORCE_AUTO_SUBMIT TASK_FORCE_PM_ROLE TASK_FORCE_LOADOUT
}

# Creates a tempdir for $TASK_FORCE_HOME (radio mailbox root) and exports it.
# Pair with teardown_all() which cleans it up.
setup_task_force_home() {
  TASK_FORCE_HOME=$(mktemp -d)
  export TASK_FORCE_HOME
  # Flag ownership so teardown_all removes only a home this test created, and
  # never the run-scoped one tests/setup_suite.bash hands down (#203).
  TASK_FORCE_HOME_OWNED=1
  reset_radio_env
}

# Puts stub scripts first on PATH and sets STUB_CALLS_DIR for recording.
setup_stubs() {
  STUB_BIN=$(mktemp -d)
  STUB_CALLS_DIR=$(mktemp -d)
  export STUB_BIN STUB_CALLS_DIR

  for stub in zellij gh kiro-cli claude fzf gum; do
    cp "$REPO_ROOT_REAL/tests/helpers/stubs/$stub" "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
  done

  export PATH="$STUB_BIN:$PATH"

  reset_radio_env
}

teardown_all() {
  # Remove temp repos; git prune first to avoid "not a git worktree" errors
  if [[ -n "${MAIN_REPO:-}" && -d "$MAIN_REPO" ]]; then
    git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
    rm -rf "$MAIN_REPO"
  fi
  [[ -z "${WORKTREE_BASE:-}"   ]] || rm -rf "$WORKTREE_BASE"
  [[ -z "${STUB_BIN:-}"        ]] || rm -rf "$STUB_BIN"
  [[ -z "${STUB_CALLS_DIR:-}"  ]] || rm -rf "$STUB_CALLS_DIR"
  if [[ -n "${TASK_FORCE_HOME_OWNED:-}" && -n "${TASK_FORCE_HOME:-}" ]]; then
    rm -rf "$TASK_FORCE_HOME"
  fi
}

# Seed the zellij stub with a JSON snapshot of tabs / panes for the radio
# helpers (`_zellij_tab_id_by_name`, `_zellij_pane_in_tab`) to consume.
# Usage: seed_zellij_tabs role1 [role2 ...]
# Each role gets tab_id 7,8,9,… and pane_id = tab_id*100, with three name
# entries per role (bare slug + ⏸️ / ▶️ prefixed) so any lookup against
# whatever's currently persisted in TAB= resolves to the same tab id.
seed_zellij_tabs() {
  local entries='' panes='' id=7
  for role in "$@"; do
    [[ -z "$entries" ]] || entries+=','
    entries+="
    {\"name\": \"$role\", \"tab_id\": $id},
    {\"name\": \"⏸️ $role\", \"tab_id\": $id},
    {\"name\": \"▶️ $role\", \"tab_id\": $id}"
    [[ -z "$panes" ]] || panes+=','
    panes+="
    {\"id\": $(( id * 100 )), \"is_plugin\": false, \"is_focused\": true, \"tab_id\": $id}"
    id=$(( id + 1 ))
  done
  export STUB_ZELLIJ_TABS_JSON="[${entries}
  ]"
  export STUB_ZELLIJ_PANES_JSON="[${panes}
  ]"
}

# Read the recorded calls for a stub command.
# Usage: stub_calls zellij
stub_calls() {
  local cmd="$1"
  cat "$STUB_CALLS_DIR/$cmd.calls" 2>/dev/null || true
}

# Assert a stub was called with args matching a substring.
# Usage: assert_stub_called zellij "new-tab"
assert_stub_called() {
  local cmd="$1"
  local pattern="$2"
  local calls
  calls=$(stub_calls "$cmd")
  if ! echo "$calls" | grep -qF -- "$pattern"; then
    echo "Expected $cmd to be called with '$pattern', but got:"
    echo "$calls"
    return 1
  fi
}
