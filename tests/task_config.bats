#!/usr/bin/env bats
# Tests for bin/task-config — show / set a repo's assistant × tracker (#219).
#
# The two properties worth stating up front, because they are what the suite is
# really about:
#
#   1. `show` never refuses. Zero loadouts and two-or-more loadouts both exit
#      non-zero, but they *describe* the state — `show` is the command you reach
#      for precisely when a repo is confusing, and `aw_detect_impl`'s bare
#      "multiple impls detected" is what you were trying to get past.
#
#   2. A switch takes out *only* task-init's own entries. A CLAUDE.md with the
#      user's instructions, a settings.json with the user's hook and their own
#      allow-list entry, and a tasks/ directory with a real backlog all survive
#      — while leaving nothing behind that would make the next dispatcher call
#      fail with a multi-match error.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# Install <loadout> for real, through its own task-init. Tests go through the
# installer rather than touching files so the artifact set under test is the one
# that actually ships.
_init() {
  local loadout="$1"; shift
  run "$REPO_ROOT_REAL/$loadout/bin/task-init" --force "$@"
  assert_success
}

# A checksum of every tracked-or-untracked path under the repo, .git excluded.
# Used to prove --dry-run is inert.
_tree_sum() {
  (
    cd "$MAIN_REPO" || exit 1
    find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -f "$p" ]]; then shasum "$p"; else printf 'dir %s\n' "$p"; fi
    done | shasum | cut -d' ' -f1
  )
}

# ---------------------------------------------------------------------------
# show — each of the seven loadouts
# ---------------------------------------------------------------------------

@test "show: claude-gh reports assistant, tracker with settings, and config path" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-gh"
  assert_output --partial "assistant : claude"
  assert_output --partial "tracker   : gh"
  assert_output --partial "owner=acme"
  assert_output --partial "repo=widgets"
  assert_output --partial "project=7"
  assert_output --partial "config    : .claude/gh-workflow.md"
  assert_output --partial ".claude/commands/worker.md"
  assert_output --partial "CLAUDE.md"
  assert_output --partial ".claude/settings.json"
}

@test "show: kiro-gh reports the kiro paths and the same tracker settings" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : kiro-gh"
  assert_output --partial "assistant : kiro"
  assert_output --partial "owner=acme repo=widgets project=7"
  assert_output --partial "config    : .kiro/steering/gh-workflow.md"
  assert_output --partial ".kiro/agents/worker.json"
  # kiro's task-init never touches either of these.
  refute_output --partial "CLAUDE.md"
  refute_output --partial "settings.json"
}

@test "show: claude-jira reports site / key / board" {
  _init claude-jira --site https://acme.atlassian.net --key PROJ --board "My Board"
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-jira"
  assert_output --partial "tracker   : jira"
  assert_output --partial "site=https://acme.atlassian.net"
  assert_output --partial "key=PROJ"
  assert_output --partial "board=My Board"
  assert_output --partial "config    : .claude/jira-workflow.md"
}

@test "show: claude-notion reports the config path and an unset tracker" {
  _init claude-notion
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-notion"
  assert_output --partial "tracker   : notion"
  # The template's IDs cannot be flag-filled, so a fresh install has none.
  assert_output --partial "unset"
  assert_output --partial "config    : .claude/notion-workflow.md"
}

@test "show: claude-notion reports the IDs once they are filled in" {
  _init claude-notion
  # Stand in for what a Notion MCP session would paste in.
  sed -i.bak \
    -e 's|collection://<YOUR_TASKS_DATA_SOURCE_ID>|collection://abc123|' \
    -e 's|<YOUR_BOARD_PAGE_ID>|8a1b2c3d-e4f5|' \
    "$MAIN_REPO/.claude/notion-workflow.md"
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "tasks=collection://abc123"
  assert_output --partial "board=8a1b2c3d-e4f5"
  refute_output --partial "unset"
}

@test "show: kiro-notion reports the kiro steering path" {
  _init kiro-notion
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : kiro-notion"
  assert_output --partial "assistant : kiro"
  assert_output --partial "config    : .kiro/steering/notion-workflow.md"
}

@test "show: claude-local says the backlog is tasks/ and lists the scaffolding" {
  _init claude-local
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-local"
  assert_output --partial "tracker   : local"
  assert_output --partial "no settings"
  assert_output --partial "config    : .claude/local-workflow.md"
  assert_output --partial "tasks/README.md"
  assert_output --partial "tasks/_board.md"
  assert_output --partial ".gitignore"
}

@test "show: kiro-local reports the kiro side of the same" {
  _init kiro-local
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : kiro-local"
  assert_output --partial "assistant : kiro"
  assert_output --partial "tracker   : local"
  assert_output --partial "config    : .kiro/steering/local-workflow.md"
  assert_output --partial "tasks/_board.md"
}

# ---------------------------------------------------------------------------
# show — the two states aw_detect_impl refuses
# ---------------------------------------------------------------------------

@test "show: zero loadouts describes the state and points at task-init" {
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "loadout   : none"
  assert_output --partial "No loadout configured"
  assert_output --partial "task-init"
  # It has to read as a description, not as a crash.
  refute_output --partial "Error:"
}

@test "show: two loadouts names both matches instead of just refusing" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "Ambiguous: 2 loadouts"
  assert_output --partial "loadout   : claude-gh"
  assert_output --partial "loadout   : kiro-gh"
  assert_output --partial ".claude/gh-workflow.md"
  assert_output --partial ".kiro/steering/gh-workflow.md"
  assert_output --partial "--impl"
}

@test "show is the default subcommand" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG"
  assert_success
  assert_output --partial "loadout   : claude-gh"
}

@test "fails when not in a git repo" {
  cd /tmp
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "rejects an unknown subcommand" {
  run "$TASK_CONFIG" frobnicate
  assert_failure
  assert_output --partial "unknown subcommand"
}

@test "--help prints the five switch steps and the carry-over asymmetry" {
  run "$TASK_CONFIG" --help
  assert_success
  assert_output --partial "task-config set assistant"
  assert_output --partial "task-init --force"
  assert_output --partial "nothing to carry"
}

# ---------------------------------------------------------------------------
# set — round trip
# ---------------------------------------------------------------------------

# Everything the *other* loadout would leave behind. A single one of these is
# enough to make every dispatcher refuse with a multi-match error, which is the
# failure #219 exists to prevent.
_refute_claude_artifacts() {
  assert [ ! -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ ! -d "$MAIN_REPO/.claude/commands" ]
  assert [ ! -f "$MAIN_REPO/CLAUDE.md" ]
  assert [ ! -f "$MAIN_REPO/.claude/settings.json" ]
}

_refute_kiro_artifacts() {
  assert [ ! -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  assert [ ! -d "$MAIN_REPO/.kiro/agents" ]
}

@test "set assistant: claude-gh → kiro-gh → claude-gh carries settings and strands nothing" {
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "claude-gh → kiro-gh"
  _refute_claude_artifacts
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  run grep -F "acme" "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  assert_success

  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : kiro-gh"
  assert_output --partial "owner=acme repo=widgets project=7"

  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  assert_output --partial "kiro-gh → claude-gh"
  _refute_kiro_artifacts
  assert [ ! -d "$MAIN_REPO/.kiro" ]

  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-gh"
  assert_output --partial "owner=acme repo=widgets project=7"
}

@test "set assistant: the round trip leaves no orphan radio hook or dangling import" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  # Nothing radio-shaped can be left in a settings.json that no longer exists,
  # so assert the absence directly rather than through jq.
  assert [ ! -e "$MAIN_REPO/.claude" ]

  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  # One radio hook per event, and exactly one CLAUDE.md import line.
  run jq -r '[.hooks.Stop[] | .hooks[] | select(.command | startswith("radio "))] | length' \
    "$MAIN_REPO/.claude/settings.json"
  assert_success
  assert_output "1"
  run grep -cxF "@.claude/gh-workflow.md" "$MAIN_REPO/CLAUDE.md"
  assert_success
  assert_output "1"
}

@test "set loadout: swaps both axes at once" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set loadout kiro-local --yes
  assert_success
  assert_output --partial "claude-gh → kiro-local"
  _refute_claude_artifacts
  assert [ -f "$MAIN_REPO/.kiro/steering/local-workflow.md" ]
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
}

# ---------------------------------------------------------------------------
# set — the user's own content survives
# ---------------------------------------------------------------------------

@test "set: a pre-existing CLAUDE.md and a user-authored hook survive the switch" {
  printf '# House rules\n\nAlways run the linter.\n' > "$MAIN_REPO/CLAUDE.md"
  mkdir -p "$MAIN_REPO/.claude"
  cat > "$MAIN_REPO/.claude/settings.json" <<'JSON'
{
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "./scripts/my-lint.sh" } ] } ] },
  "permissions": { "allow": ["Bash(make *)"], "deny": ["Bash(rm -rf *)"] },
  "model": "opus"
}
JSON
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "your own content stays"
  assert_output --partial "your own entries stay"

  # CLAUDE.md: import gone, house rules intact.
  assert [ -f "$MAIN_REPO/CLAUDE.md" ]
  run grep -qxF "@.claude/gh-workflow.md" "$MAIN_REPO/CLAUDE.md"
  assert_failure
  run grep -F "Always run the linter." "$MAIN_REPO/CLAUDE.md"
  assert_success

  # settings.json: radio hooks and the seeded allow-list gone, everything the
  # user put there still present.
  assert [ -f "$MAIN_REPO/.claude/settings.json" ]
  run jq -r '[.. | objects | select(has("command")) | .command | select(startswith("radio "))] | length' \
    "$MAIN_REPO/.claude/settings.json"
  assert_output "0"
  run jq -r '.hooks.Stop[0].hooks[0].command' "$MAIN_REPO/.claude/settings.json"
  assert_output "./scripts/my-lint.sh"
  run jq -r '.permissions.allow | join(",")' "$MAIN_REPO/.claude/settings.json"
  assert_output "Bash(make *)"
  run jq -r '.permissions.deny | join(",")' "$MAIN_REPO/.claude/settings.json"
  assert_output "Bash(rm -rf *)"
  run jq -r '.model' "$MAIN_REPO/.claude/settings.json"
  assert_output "opus"
}

@test "set: a command of the user's own keeps .claude/commands alive" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf 'my own slash command\n' > "$MAIN_REPO/.claude/commands/deploy.md"

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert [ ! -f "$MAIN_REPO/.claude/commands/worker.md" ]
  assert [ -f "$MAIN_REPO/.claude/commands/deploy.md" ]
}

@test "set: a real backlog in tasks/ is not deleted with the scaffolding" {
  _init claude-local
  printf -- '---\nid: 001\ntitle: keep me\n---\n' > "$MAIN_REPO/tasks/001-keep-me.md"

  run "$TASK_CONFIG" set tracker gh --yes
  assert_success
  assert_output --partial "kept tasks/"
  assert_output --partial "1 backlog file(s)"
  assert [ ! -f "$MAIN_REPO/tasks/README.md" ]
  assert [ ! -f "$MAIN_REPO/tasks/_board.md" ]
  assert [ -f "$MAIN_REPO/tasks/001-keep-me.md" ]
}

@test "set: .gitignore keeps the user's entries and loses only .git/task-force/" {
  printf 'node_modules/\n' > "$MAIN_REPO/.gitignore"
  _init claude-local
  run grep -qxF ".git/task-force/" "$MAIN_REPO/.gitignore"
  assert_success

  run "$TASK_CONFIG" set tracker gh --yes
  assert_success
  run grep -qxF ".git/task-force/" "$MAIN_REPO/.gitignore"
  assert_failure
  run grep -qxF "node_modules/" "$MAIN_REPO/.gitignore"
  assert_success
}

# ---------------------------------------------------------------------------
# set — the role files task-init may have kept as the user's (#219 review)
# ---------------------------------------------------------------------------

# This is the likeliest place in a switch to destroy work, so it gets the most
# tests. task-init installs role files through install_file, whose keep / prompt
# policies let an existing file survive a re-run — and on kiro it then merges the
# radio hooks *into* whatever survived (#218/#222). So an agent config can be the
# user's own work carrying our entries, and deleting it wholesale is data loss.

@test "set: a customized kiro agent config survives with only the radio hooks stripped" {
  _init kiro-gh --owner acme --repo widgets --project 7
  # A worker.json the user has edited and task-init then merged hooks into.
  run jq '.prompt = "MY OWN PROMPT" | .welcomeMessage = "mine"' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_success
  printf '%s\n' "$output" > "$MAIN_REPO/.kiro/agents/worker.json"
  run jq -r '[.hooks | keys[]] | join(",")' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output "agentSpawn,stop,userPromptSubmit"

  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  assert_output --partial "kept .kiro/agents/worker.json, radio hooks stripped"

  # The file is still there, with the user's edits, and no radio hook left.
  assert [ -f "$MAIN_REPO/.kiro/agents/worker.json" ]
  run jq -r '.prompt' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output "MY OWN PROMPT"
  run jq -r '.welcomeMessage' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output "mine"
  run jq -r '[.. | objects | select(has("command")) | .command | select(startswith("radio "))] | length' \
    "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output "0"
  # The pristine ones still go, and so does the detection key.
  assert [ ! -f "$MAIN_REPO/.kiro/agents/pm.json" ]
  assert [ ! -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "set: a non-radio hook of the user's own on the same trigger survives too" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run jq '.hooks.stop += [{"command": "./scripts/mine.sh"}] | .prompt = "edited"' \
    "$MAIN_REPO/.kiro/agents/worker.json"
  assert_success
  printf '%s\n' "$output" > "$MAIN_REPO/.kiro/agents/worker.json"

  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  run jq -r '.hooks.stop | map(.command) | join(",")' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_output "./scripts/mine.sh"
}

@test "set: a pristine kiro agent config is deleted, hooks and all" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  refute_output --partial "kept .kiro/agents"
  assert [ ! -d "$MAIN_REPO/.kiro" ]
}

@test "set: a customized .claude/commands file is kept rather than deleted" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf 'my own edits to the worker prompt\n' >> "$MAIN_REPO/.claude/commands/worker.md"

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "kept .claude/commands/worker.md"
  assert_output --partial "may be yours"
  assert [ -f "$MAIN_REPO/.claude/commands/worker.md" ]
  run grep -F "my own edits" "$MAIN_REPO/.claude/commands/worker.md"
  assert_success
  # The untouched ones still go.
  assert [ ! -f "$MAIN_REPO/.claude/commands/pm.md" ]
}

@test "set: the workflow doc's repo-specific tail is backed up before the doc goes" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf '\nGreen here means ./run_tests.sh and check-drift.\n' >> "$MAIN_REPO/.claude/gh-workflow.md"

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "kept a copy at .claude/gh-workflow.md.bak"
  assert [ ! -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md.bak" ]
  run grep -F "Green here means" "$MAIN_REPO/.claude/gh-workflow.md.bak"
  assert_success
}

@test "set: a workflow doc with only task-init's stub tail is not backed up" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  refute_output --partial ".bak"
  assert [ ! -e "$MAIN_REPO/.claude/gh-workflow.md.bak" ]
}

@test "--dry-run: the plan agrees with the real run when a backup is created" {
  _init kiro-gh --owner acme --repo widgets --project 7
  printf '\nRepo-specific: green means ./run_tests.sh.\n' >> "$MAIN_REPO/.kiro/steering/gh-workflow.md"

  run "$TASK_CONFIG" set assistant claude --dry-run
  assert_success
  local planned
  planned=$(printf '%s\n' "$output" | sed -n 's/^  would remove /X /p' | LC_ALL=C sort)
  # The .bak the real run creates has to keep the plan from promising the rmdir.
  refute_output --partial "would remove .kiro/steering/ (now empty)"

  run "$TASK_CONFIG" set assistant claude --yes
  assert_success
  local done_
  done_=$(printf '%s\n' "$output" | sed -n 's/^  removed /X /p' | LC_ALL=C sort)
  assert_equal "$planned" "$done_"
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md.bak" ]
}

# ---------------------------------------------------------------------------
# set — the no-carry-over path
# ---------------------------------------------------------------------------

@test "set tracker: says there is nothing to carry and leaves the new doc unfilled" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set tracker jira --yes
  assert_success
  assert_output --partial "claude-gh → claude-jira"
  assert_output --partial "share no settings"
  assert [ -f "$MAIN_REPO/.claude/jira-workflow.md" ]
  assert [ ! -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  # Nothing was invented for the new tracker's fields.
  run grep -F "{SITE}" "$MAIN_REPO/.claude/jira-workflow.md"
  assert_success
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "tracker   : jira"
  assert_output --partial "unset"
}

@test "set tracker: local needs no settings, so no fill-these-in hint" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set tracker local --yes
  assert_success
  refute_output --partial "Fill in the new tracker settings"
}

# ---------------------------------------------------------------------------
# set — refusals
# ---------------------------------------------------------------------------

@test "set loadout kiro-jira: refuses, naming the hole in the grid" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set loadout kiro-jira --yes
  assert_failure
  assert_output --partial "no 'kiro-jira' loadout"
  assert_output --partial "one hole"
  assert_output --partial "jira is not"
  assert_output --partial "kiro"
  # Nothing was taken out on the way to the refusal.
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/agents/worker.json" ]
}

@test "set tracker jira on kiro: the same refusal, reached via the tracker axis" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set tracker jira --yes
  assert_failure
  assert_output --partial "no 'kiro-jira' loadout"
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "set: unknown loadout name is refused with the list of real ones" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set loadout claude-trello --yes
  assert_failure
  assert_output --partial "no 'claude-trello' loadout"
  assert_output --partial "claude-gh"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "set: unknown assistant / tracker values are refused" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant emacs --yes
  assert_failure
  assert_output --partial "unknown assistant"
  run "$TASK_CONFIG" set tracker trello --yes
  assert_failure
  assert_output --partial "unknown tracker"
}

@test "set: unknown axis is refused" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set colour blue --yes
  assert_failure
  assert_output --partial "unknown axis"
}

@test "set: switching to the loadout already installed is a no-op" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set loadout claude-gh --yes
  assert_success
  assert_output --partial "Already on claude-gh"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "set: with no loadout configured there is nothing to switch from" {
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_failure
  assert_output --partial "no loadout configured"
  assert_output --partial "task-init"
}

@test "set: an ambiguous repo asks for --impl rather than guessing" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_failure
  assert_output --partial "2 loadouts"
  assert_output --partial "--impl"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "set: --impl picks which loadout to replace in an ambiguous repo" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" --impl claude-gh set loadout claude-notion --yes
  assert_success
  assert_output --partial "claude-gh → claude-notion"
  assert [ ! -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.claude/notion-workflow.md" ]
  # The loadout that was not named is untouched.
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "set: an unknown --impl value is refused" {
  run "$TASK_CONFIG" --impl claude-trello show
  assert_failure
  assert_output --partial "unknown loadout"
}

# ---------------------------------------------------------------------------
# --dry-run
# ---------------------------------------------------------------------------

@test "--dry-run: prints the plan and changes nothing on disk" {
  _init claude-gh --owner acme --repo widgets --project 7
  local before after
  before=$(_tree_sum)

  run "$TASK_CONFIG" set assistant kiro --dry-run
  assert_success
  assert_output --partial "would remove .claude/gh-workflow.md"
  assert_output --partial "would remove .claude/commands/worker.md"
  assert_output --partial "would remove CLAUDE.md"
  assert_output --partial "would remove .claude/settings.json"
  assert_output --partial "would remove .claude/ (now empty)"
  assert_output --partial "kiro-gh/bin/task-init --force --owner acme --repo widgets --project 7"
  assert_output --partial "nothing was changed"

  after=$(_tree_sum)
  assert_equal "$before" "$after"
}

@test "--dry-run: on a repo with user content, changes nothing either" {
  printf '# House rules\n' > "$MAIN_REPO/CLAUDE.md"
  _init claude-local
  printf -- '---\nid: 001\n---\n' > "$MAIN_REPO/tasks/001-x.md"
  local before after
  before=$(_tree_sum)

  run "$TASK_CONFIG" set tracker gh --dry-run
  assert_success
  assert_output --partial "would strip the @.claude/local-workflow.md import from CLAUDE.md"
  assert_output --partial "kept tasks/"

  after=$(_tree_sum)
  assert_equal "$before" "$after"
}

@test "--dry-run: the plan predicts the same removals the real run performs" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" set assistant kiro --dry-run
  assert_success
  local planned
  planned=$(printf '%s\n' "$output" | sed -n 's/^  would remove /X /p' | LC_ALL=C sort)

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  local done_
  done_=$(printf '%s\n' "$output" | sed -n 's/^  removed /X /p' | LC_ALL=C sort)

  assert_equal "$planned" "$done_"
}

# ---------------------------------------------------------------------------
# the TTY confirmation
# ---------------------------------------------------------------------------

# Without --yes and with a terminal, `set` previews the plan and asks. Only a
# real pty exercises that branch — `[[ -t 0 ]]` is false under plain `run`,
# which is why the non-TTY path proceeds unprompted (there is nobody to ask).
@test "set: a TTY run previews the plan and aborts on anything but yes" {
  require_pty
  _init claude-gh --owner acme --repo widgets --project 7
  local before after
  before=$(_tree_sum)

  run pty_run "cd '$MAIN_REPO' && '$TASK_CONFIG' set assistant kiro" $'n\n'
  assert_failure
  assert_output --partial "removing claude-gh:"
  assert_output --partial "would remove .claude/gh-workflow.md"
  assert_output --partial "Proceed?"
  assert_output --partial "Aborted"

  after=$(_tree_sum)
  assert_equal "$before" "$after"
}

@test "set: EOF at the prompt aborts cleanly rather than failing opaquely" {
  require_pty
  _init claude-gh --owner acme --repo widgets --project 7
  local before after
  before=$(_tree_sum)

  # No input argument: the pty's input is closed at once, so `read` sees EOF.
  # Under set -e that would otherwise exit with read's own status and no
  # explanation of what happened to the switch.
  run pty_run "cd '$MAIN_REPO' && '$TASK_CONFIG' set assistant kiro"
  assert_failure
  assert_output --partial "Aborted; nothing was changed."

  after=$(_tree_sum)
  assert_equal "$before" "$after"
}

@test "set: a TTY run proceeds on y" {
  require_pty
  _init claude-gh --owner acme --repo widgets --project 7

  run pty_run "cd '$MAIN_REPO' && '$TASK_CONFIG' set assistant kiro" $'y\n'
  assert_success
  assert_output --partial "claude-gh → kiro-gh done."
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  _refute_claude_artifacts
}

# ---------------------------------------------------------------------------
# the allow-list strip — the nastiest bug in this change, so it gets its own test
# ---------------------------------------------------------------------------

# The first version of the jq that strips the seeded literals wrote
# `$seeded | index(.)`. Inside index(f), jq evaluates f with the *piped* input as
# `.`, so that asks whether $seeded contains itself — true for every entry, which
# silently deleted the user's ENTIRE allow-list along with ours. Same failure
# shape as the #182 filter that never ran and failed open: correct-looking code
# whose predicate is trivially true. So assert the property directly rather than
# only as a clause of a larger test.
@test "set: every user-authored allow-list entry survives the strip" {
  mkdir -p "$MAIN_REPO/.claude"
  cat > "$MAIN_REPO/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(make *)",
      "Bash(gh workflow run *)",
      "Bash(ghost *)",
      "mcp__atlassian__editJiraIssue",
      "WebFetch"
    ]
  }
}
JSON
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success

  # All five survive. Two are deliberately adversarial: "Bash(gh workflow run *)"
  # and "Bash(ghost *)" share a prefix with seeded gh literals without being any
  # of them, and mcp__atlassian__editJiraIssue is a *mutation* the jira loadout
  # never seeds — a substring or prefix match would eat all three.
  run jq -r '.permissions.allow | sort | join("|")' "$MAIN_REPO/.claude/settings.json"
  assert_output "Bash(gh workflow run *)|Bash(ghost *)|Bash(make *)|WebFetch|mcp__atlassian__editJiraIssue"

  # And nothing seeded is left behind.
  run jq -r '[.permissions.allow[] | select(. == "Bash(gh issue view *)" or . == "Read" or . == "Bash(radio *)")] | length' \
    "$MAIN_REPO/.claude/settings.json"
  assert_output "0"
}

@test "set: an entry the user wanted AND task-init seeds goes — the documented imprecision" {
  mkdir -p "$MAIN_REPO/.claude"
  printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(ls *)"]}}' \
    > "$MAIN_REPO/.claude/settings.json"
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  # Removal matches a literal set, so these two are indistinguishable from ours
  # and go with the switch. Asserted rather than merely documented, so the day
  # someone adds provenance tracking this test is what tells them it changed.
  assert [ ! -f "$MAIN_REPO/.claude/settings.json" ]
}

# ---------------------------------------------------------------------------
# the seeded allow-list has to stay in lockstep with what task-init writes
# ---------------------------------------------------------------------------

# lib/loadout-artifacts.sh removes the allow-list by matching a literal set.
# That set is a second copy of the one in <loadout>/bin/task-init's jq merge, and
# the copy is deliberate (#219 rejected a provenance manifest) — so the thing to
# guard is that the two agree. If they drift, a switch starts leaving seeded
# entries behind and nothing else notices.
@test "la_seeded_allow matches the literals each claude task-init seeds" {
  local loadout seeded_lib seeded_init
  # shellcheck source=lib/loadout-artifacts.sh
  source "$REPO_ROOT_REAL/lib/loadout-artifacts.sh"
  for loadout in claude-gh claude-jira claude-notion claude-local; do
    seeded_lib=$(la_seeded_allow "$loadout" | LC_ALL=C sort)
    # The jq merge's literal list: every quoted string between the
    # `.permissions.allow + [` line and the closing `] | unique`.
    seeded_init=$(awk '
      /\.permissions\.allow \+ \[/ { grab=1; next }
      grab && /\] \| unique/       { exit }
      grab && /^ *"/               { gsub(/^ *"|",?$/, ""); print }
    ' "$REPO_ROOT_REAL/$loadout/bin/task-init" | LC_ALL=C sort)
    assert_equal "$seeded_lib" "$seeded_init"
  done
}
