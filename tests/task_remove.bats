#!/usr/bin/env bats
# Tests for bin/task-remove — strip task-force's per-repo artifacts (#220).
#
# Three properties the suite is really about:
#
#   1. Nothing is left behind. The "zero artifacts" assertions read the path
#      inventory out of lib/loadout-artifacts.sh itself (`la_owned_paths`) rather
#      than restating it here, so a test and a wrong implementation cannot drift
#      into agreeing. A single stray file is the multi-match state every
#      dispatcher refuses on.
#
#   2. Nothing of the user's goes. Removal is the inverse of task-init's
#      idempotent merge: a CLAUDE.md that predates task-force, a settings.json
#      with the user's own hook, a tasks/ backlog and a customized role file all
#      survive by default. `--purge` is the only way past that, and only after the
#      list has been printed.
#
#   3. The *global* install is never touched. The ~/.local/bin symlinks and the
#      shell-rc PATH line are shared by every repo on the machine, so removing
#      them because one project ended would break every other project. That is
#      the dangerous direction, and it is asserted explicitly rather than left to
#      "no test exercises it".

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  cd "$MAIN_REPO"
  # The engine, for the inventory-driven assertions. Sourced rather than
  # re-listed: see property 1 above.
  # shellcheck source=lib/loadout-artifacts.sh
  . "$REPO_ROOT_REAL/lib/loadout-artifacts.sh"
}

teardown() {
  teardown_all
}

# Install <loadout> for real, through its own task-init, so the artifact set
# under test is the one that actually ships.
_init() {
  local loadout="$1"; shift
  run "$REPO_ROOT_REAL/$loadout/bin/task-init" --force "$@"
  assert_success
}

# Install the commit-msg guard the way task-work does (#194) — through the same
# lib, so the test cannot install a shape the real thing never writes.
_install_ci_guard() {
  run bash -c ". '$REPO_ROOT_REAL/lib/ci-guard.sh'; aw_install_ci_guard_hook '$MAIN_REPO'"
  assert_success
}

_hooks_dir() { printf '%s' "$MAIN_REPO/.git/hooks"; }

# A checksum of every tracked-or-untracked path under the repo, .git excluded.
# Used to prove --dry-run is inert, and that a --purge run puts the tree back
# exactly as task-init found it.
_tree_sum() {
  (
    cd "$MAIN_REPO" || exit 1
    find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -f "$p" ]]; then shasum "$p"; else printf 'dir %s\n' "$p"; fi
    done | shasum | cut -d' ' -f1
  )
}

# The inventory-driven "zero artifacts" assertion. Capture what the engine says
# the loadout owns *before* removal — afterwards the inventory is empty by
# construction, which would make the check vacuous — then assert every one of
# those paths is gone, and that detection no longer finds the loadout at all.
_assert_clean_removal() {
  local loadout="$1"; shift
  _init "$loadout" "$@"

  local owned=() p
  while IFS= read -r p; do
    [[ -n "$p" ]] && owned+=("$p")
  done < <(la_owned_paths "$MAIN_REPO" "$loadout")
  if (( ${#owned[@]} == 0 )); then
    echo "la_owned_paths reported nothing for $loadout — the assertion would be vacuous"
    return 1
  fi

  run "$TASK_REMOVE" --purge --yes
  assert_success

  for p in "${owned[@]}"; do
    if [[ -e "$MAIN_REPO/$p" ]]; then
      echo "$loadout: left behind $p"
      return 1
    fi
  done

  # And the detection key specifically, via the command that describes it.
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "loadout   : none"
}

# ---------------------------------------------------------------------------
# 1. zero artifacts left, on each of the seven loadouts
# ---------------------------------------------------------------------------

@test "claude-gh: removal leaves zero artifacts from the engine's own inventory" {
  _assert_clean_removal claude-gh --owner acme --repo widgets --project 7
  assert [ ! -e "$MAIN_REPO/.claude" ]
}

@test "claude-jira: removal leaves zero artifacts" {
  _assert_clean_removal claude-jira --site https://acme.atlassian.net --key PROJ --board "My Board"
  assert [ ! -e "$MAIN_REPO/.claude" ]
}

@test "claude-notion: removal leaves zero artifacts" {
  _assert_clean_removal claude-notion
  assert [ ! -e "$MAIN_REPO/.claude" ]
}

@test "claude-local: removal leaves zero artifacts, tasks/ included under --purge" {
  _assert_clean_removal claude-local
  assert [ ! -e "$MAIN_REPO/.claude" ]
  assert [ ! -e "$MAIN_REPO/tasks" ]
  assert [ ! -e "$MAIN_REPO/.gitignore" ]
}

@test "kiro-gh: removal leaves zero artifacts" {
  _assert_clean_removal kiro-gh --owner acme --repo widgets --project 7
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

@test "kiro-notion: removal leaves zero artifacts" {
  _assert_clean_removal kiro-notion
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

@test "kiro-local: removal leaves zero artifacts" {
  _assert_clean_removal kiro-local
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert [ ! -e "$MAIN_REPO/tasks" ]
}

@test "--purge on a virgin repo puts the tree back byte-for-byte" {
  # Use case 2: the PR against a repo that does not use task-force. The whole
  # point is that `git status` afterwards is clean, so a checksum is the honest
  # assertion — a per-path list would miss a file nobody thought to name.
  local before
  before=$(_tree_sum)
  _init claude-gh --owner acme --repo widgets --project 7
  refute [ "$(_tree_sum)" = "$before" ]

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert_equal "$(_tree_sum)" "$before"
}

# ---------------------------------------------------------------------------
# 2. the user's own content survives
# ---------------------------------------------------------------------------

@test "a pre-existing CLAUDE.md keeps everything but the import line" {
  printf '# House rules\n\nAlways run the linter.\n' > "$MAIN_REPO/CLAUDE.md"
  _init claude-gh --owner acme --repo widgets --project 7
  run grep -qxF "@.claude/gh-workflow.md" "$MAIN_REPO/CLAUDE.md"
  assert_success

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "your own content stays"

  assert [ -f "$MAIN_REPO/CLAUDE.md" ]
  run grep -qxF "@.claude/gh-workflow.md" "$MAIN_REPO/CLAUDE.md"
  assert_failure
  run grep -F "Always run the linter." "$MAIN_REPO/CLAUDE.md"
  assert_success
}

@test "a settings.json carrying a non-radio hook keeps that hook and the file" {
  mkdir -p "$MAIN_REPO/.claude"
  cat > "$MAIN_REPO/.claude/settings.json" <<'JSON'
{
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "./scripts/my-lint.sh" } ] } ] },
  "permissions": { "allow": ["Bash(make *)"], "deny": ["Bash(rm -rf *)"] },
  "model": "opus"
}
JSON
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "your own entries stay"

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

@test "a settings.json task-init created from scratch is deleted" {
  _init claude-gh --owner acme --repo widgets --project 7
  assert [ -f "$MAIN_REPO/.claude/settings.json" ]

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "it held only task-force entries"
  assert [ ! -e "$MAIN_REPO/.claude/settings.json" ]
}

@test "by default a customized role file and the tasks/ backlog are kept and reported" {
  _init claude-local
  printf 'my own edits to the worker prompt\n' >> "$MAIN_REPO/.claude/commands/worker.md"
  printf -- '---\nid: 001\ntitle: keep me\n---\n' > "$MAIN_REPO/tasks/001-keep-me.md"
  printf 'my own slash command\n' > "$MAIN_REPO/.claude/commands/deploy.md"

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "kept .claude/commands/worker.md"
  assert_output --partial "may be yours"
  assert_output --partial "1 backlog file(s)"

  assert [ -f "$MAIN_REPO/.claude/commands/worker.md" ]
  assert [ -f "$MAIN_REPO/tasks/001-keep-me.md" ]
  # A command of the user's own was never ours to touch, and keeps its directory.
  assert [ -f "$MAIN_REPO/.claude/commands/deploy.md" ]
  # The pristine ones still went.
  assert [ ! -e "$MAIN_REPO/.claude/commands/pm.md" ]
  assert [ ! -e "$MAIN_REPO/tasks/_board.md" ]
}

@test "a keep is followed by the --purge hint, so the override is offered after the list" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf 'my own edits\n' >> "$MAIN_REPO/.claude/commands/worker.md"
  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "re-run with --purge"
}

@test "with nothing kept there is no --purge hint to give" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --yes
  assert_success
  refute_output --partial "re-run with --purge"
}

# ---------------------------------------------------------------------------
# --purge — the override the keep-bias needs for use case 2
# ---------------------------------------------------------------------------

@test "--purge deletes a role file that differs from the shipped copy" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf 'my own edits\n' >> "$MAIN_REPO/.claude/commands/worker.md"

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert_output --partial "removed .claude/commands/worker.md — it differs from the copy claude-gh ships (--purge)"
  assert [ ! -e "$MAIN_REPO/.claude" ]
}

@test "--purge deletes a customized kiro agent config rather than stripping its hooks" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run jq '.prompt = "MY OWN PROMPT"' "$MAIN_REPO/.kiro/agents/worker.json"
  assert_success
  printf '%s\n' "$output" > "$MAIN_REPO/.kiro/agents/worker.json"

  run "$TASK_REMOVE" --purge --yes
  assert_success
  refute_output --partial "radio hooks stripped"
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

@test "--purge writes no <doc>.bak, and sweeps one an earlier run left behind" {
  _init claude-gh --owner acme --repo widgets --project 7
  printf '\nGreen here means ./run_tests.sh.\n' >> "$MAIN_REPO/.claude/gh-workflow.md"
  # A .bak from a previous (non-purge) removal, which is the usual way to meet one.
  printf 'an earlier backup\n' > "$MAIN_REPO/.claude/gh-workflow.md.bak"

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert_output --partial "sections of yours below the managed-region marker included (--purge)"
  assert_output --partial "removed .claude/gh-workflow.md.bak (--purge)"
  assert [ ! -e "$MAIN_REPO/.claude" ]
}

@test "--purge takes the tasks/ backlog, and says which files were backlog" {
  _init claude-local
  printf -- '---\nid: 001\n---\n' > "$MAIN_REPO/tasks/001-done-project.md"

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert_output --partial "removed tasks/001-done-project.md (--purge — backlog, not scaffolding)"
  assert [ ! -e "$MAIN_REPO/tasks" ]
}

@test "--purge still strips rather than deletes files that are only partly ours" {
  # The override widens what counts as *ours*; it does not make CLAUDE.md or a
  # settings.json full of the user's entries fair game.
  printf '# House rules\n' > "$MAIN_REPO/CLAUDE.md"
  mkdir -p "$MAIN_REPO/.claude"
  printf '{"model":"opus"}\n' > "$MAIN_REPO/.claude/settings.json"
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert [ -f "$MAIN_REPO/CLAUDE.md" ]
  run grep -F "House rules" "$MAIN_REPO/CLAUDE.md"
  assert_success
  run jq -r '.model' "$MAIN_REPO/.claude/settings.json"
  assert_output "opus"
}

@test "--purge names itself in the header, so the run says which rules it is under" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --purge --dry-run
  assert_success
  assert_output --partial "--purge: files the default would keep"
}

# ---------------------------------------------------------------------------
# 5. the ci-guard commit-msg hook
# ---------------------------------------------------------------------------

@test "the ci-guard commit-msg hook is removed" {
  _init claude-gh --owner acme --repo widgets --project 7
  _install_ci_guard
  assert [ -x "$(_hooks_dir)/commit-msg" ]

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "the ci-guard commit-msg hook"
  assert [ ! -e "$(_hooks_dir)/commit-msg" ]
}

@test "a pre-existing hook chained as commit-msg.local is restored to commit-msg" {
  printf '#!/bin/sh\necho house hook\n' > "$(_hooks_dir)/commit-msg"
  chmod +x "$(_hooks_dir)/commit-msg"
  _init claude-gh --owner acme --repo widgets --project 7
  _install_ci_guard
  assert [ -f "$(_hooks_dir)/commit-msg.local" ]

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "restored"
  assert [ ! -e "$(_hooks_dir)/commit-msg.local" ]
  assert [ -x "$(_hooks_dir)/commit-msg" ]
  run grep -F "echo house hook" "$(_hooks_dir)/commit-msg"
  assert_success
}

@test "a commit-msg hook that is not task-force's is named and left alone" {
  printf '#!/bin/sh\necho not ours\n' > "$(_hooks_dir)/commit-msg"
  chmod +x "$(_hooks_dir)/commit-msg"
  _init claude-gh --owner acme --repo widgets --project 7

  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "no task-force marker in it, so it is not ours"
  assert [ -x "$(_hooks_dir)/commit-msg" ]
  run grep -F "echo not ours" "$(_hooks_dir)/commit-msg"
  assert_success
}

@test "no hook at all is silent rather than an error" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --yes
  assert_success
  refute_output --partial "commit-msg"
}

# ---------------------------------------------------------------------------
# 6. the global install is NOT touched — the dangerous direction
# ---------------------------------------------------------------------------

@test "the ~/.local/bin symlinks and the shell rc are untouched" {
  _init claude-gh --owner acme --repo widgets --project 7
  _install_ci_guard

  local fake_home
  fake_home=$(mktemp -d)
  mkdir -p "$fake_home/.local/bin"
  local cmd
  for cmd in task-init task-work task-done task-board task-config task-remove task-pm radio ci-guard; do
    ln -sf "$REPO_ROOT_REAL/bin/$cmd" "$fake_home/.local/bin/$cmd"
  done
  printf '\n# added by claude-gh install.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$fake_home/.zshrc"
  local rc_sum
  rc_sum=$(shasum "$fake_home/.zshrc" | cut -d' ' -f1)

  HOME="$fake_home" run "$TASK_REMOVE" --purge --yes
  assert_success
  # Said out loud in the report, because "it didn't happen" is not something a
  # user can see.
  assert_output --partial "Untouched, by design"

  for cmd in task-init task-work task-done task-board task-config task-remove task-pm radio ci-guard; do
    if [[ ! -L "$fake_home/.local/bin/$cmd" ]]; then
      echo "task-remove removed the global symlink $cmd"
      rm -rf "$fake_home"
      return 1
    fi
  done
  assert_equal "$(shasum "$fake_home/.zshrc" | cut -d' ' -f1)" "$rc_sum"
  rm -rf "$fake_home"
}

# ---------------------------------------------------------------------------
# 7. --dry-run is inert
# ---------------------------------------------------------------------------

@test "--dry-run changes nothing" {
  _init claude-local
  printf 'my own edits\n' >> "$MAIN_REPO/.claude/commands/worker.md"
  printf -- '---\nid: 001\n---\n' > "$MAIN_REPO/tasks/001-keep-me.md"
  _install_ci_guard
  local before
  before=$(_tree_sum)

  run "$TASK_REMOVE" --dry-run
  assert_success
  assert_output --partial "--dry-run: nothing was changed."
  assert_equal "$(_tree_sum)" "$before"
  # .git is pruned from the checksum, so the hook gets its own assertion.
  assert [ -x "$(_hooks_dir)/commit-msg" ]
}

@test "--purge --dry-run changes nothing either" {
  _init claude-local
  printf -- '---\nid: 001\n---\n' > "$MAIN_REPO/tasks/001-keep-me.md"
  local before
  before=$(_tree_sum)

  run "$TASK_REMOVE" --purge --dry-run
  assert_success
  assert_equal "$(_tree_sum)" "$before"
}

@test "the plan predicts exactly the removals the real run performs" {
  # One code path serves both modes in lib/loadout-artifacts.sh so a dry run
  # cannot lie; this is the assertion that holds it to that.
  _init kiro-gh --owner acme --repo widgets --project 7
  printf '\nRepo-specific: green means ./run_tests.sh.\n' >> "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  _install_ci_guard

  run "$TASK_REMOVE" --dry-run
  assert_success
  local planned
  planned=$(printf '%s\n' "$output" | sed -n 's/^  would remove /X /p' | LC_ALL=C sort)

  run "$TASK_REMOVE" --yes
  assert_success
  local performed
  performed=$(printf '%s\n' "$output" | sed -n 's/^  removed /X /p' | LC_ALL=C sort)
  assert_equal "$planned" "$performed"
}

# ---------------------------------------------------------------------------
# 8. refusals and the ambiguous repo
# ---------------------------------------------------------------------------

@test "a repo with no loadout exits with a clear message, not a crash" {
  run "$TASK_REMOVE" --yes
  assert_failure
  assert_output --partial "no loadout configured"
  assert_output --partial "nothing to remove"
  assert_output --partial "task-config show"
}

@test "with no loadout but a live ci-guard hook, the hook's path is named" {
  # The one artifact that outlives a workflow doc someone deleted by hand — and
  # the only thing still acting on commits in a repo that looks clean.
  _init claude-gh --owner acme --repo widgets --project 7
  _install_ci_guard
  rm -f "$MAIN_REPO/.claude/gh-workflow.md"

  run "$TASK_REMOVE" --yes
  assert_failure
  assert_output --partial "ci-guard commit-msg hook is still installed"
  assert_output --partial ".git/hooks/commit-msg"
}

@test "two loadouts: both are removed, because half-removed is the state that breaks" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7

  run "$TASK_REMOVE" --purge --yes
  assert_success
  assert_output --partial "removing claude-gh:"
  assert_output --partial "removing kiro-gh:"
  assert [ ! -e "$MAIN_REPO/.claude" ]
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

@test "--impl narrows removal to one loadout in an ambiguous repo" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7

  run "$TASK_REMOVE" --impl kiro-gh --purge --yes
  assert_success
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "--impl with valid but uninstalled loadout is refused rather than silently doing nothing" {
  # The reviewer's test for the #227 blocker, verbatim. Before the guard,
  # aw_all_impls accepted the *name*, MATCHES became 1 so the zero-match branch
  # was skipped, the walk found nothing to remove, and the run still printed
  # "task-force removed from <root>". For #220's strip-before-a-PR case that
  # success line is the only thing a user checks, so they ship every artifact they
  # meant to take out — the #194 / #182 failure class: correct-looking output for
  # work that never happened.
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --impl kiro-gh
  assert_failure
  assert_output --partial "not configured in"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "AW_IMPL naming an uninstalled loadout is refused the same way as --impl" {
  # The pin is "${PINNED_IMPL:-${AW_IMPL:-}}", so the env var reaches the same
  # guard — and ambient env makes this worse than an explicit flag, not better:
  # nothing on the command line hints at why the run is about to lie.
  _init claude-gh --owner acme --repo widgets --project 7
  AW_IMPL=kiro-gh run "$TASK_REMOVE" --yes
  assert_failure
  assert_output --partial "not configured in"
  assert_output --partial "configured here: claude-gh"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "an unknown --impl value is refused with the list of real loadouts" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --impl claude-trello --yes
  assert_failure
  assert_output --partial "unknown loadout 'claude-trello'"
  assert_output --partial "claude-gh"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "fails when not in a git repo" {
  cd /tmp
  run "$TASK_REMOVE" --yes
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "rejects an unknown option and a stray positional argument" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_REMOVE" --frobnicate
  assert_failure
  assert_output --partial "unknown option"
  run "$TASK_REMOVE" claude-gh
  assert_failure
  assert_output --partial "takes no positional arguments"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "--help states the scope boundary rather than leaving it implied" {
  run "$TASK_REMOVE" --help
  assert_success
  assert_output --partial "NOT removed, by design"
  # Matched on fragments that do not straddle a line break in the wrapped help.
  assert_output --partial "shared by every repo on this machine"
  assert_output --partial "--purge"
  assert_output --partial "task-done --remove-worktree"
}

# ---------------------------------------------------------------------------
# the confirmation prompt (TTY path)
# ---------------------------------------------------------------------------

@test "a TTY run previews the plan and aborts on anything but yes" {
  require_pty
  _init claude-gh --owner acme --repo widgets --project 7

  run pty_run "cd '$MAIN_REPO' && '$TASK_REMOVE'" $'n\n'
  assert_failure
  assert_output --partial "would remove .claude/gh-workflow.md"
  assert_output --partial "Aborted; nothing was changed."
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
}

@test "a TTY run proceeds on yes, and does not print the list twice" {
  require_pty
  _init claude-gh --owner acme --repo widgets --project 7

  run pty_run "cd '$MAIN_REPO' && '$TASK_REMOVE'" $'y\n'
  assert_success
  assert_output --partial "would remove .claude/gh-workflow.md"
  assert_output --partial "removed .claude/gh-workflow.md"
  assert [ ! -e "$MAIN_REPO/.claude" ]
  # The untouched-by-design footer belongs to the preview on this path; printing
  # it again after the apply would be the same paragraph twice.
  assert_equal "$(printf '%s\n' "$output" | grep -c 'Untouched, by design')" "1"
}
