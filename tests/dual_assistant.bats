#!/usr/bin/env bats
# Both assistants installed, one active (#293).
#
# claude's artifacts live under .claude/ and kiro's under .kiro/, so the two
# loadouts on one tracker never collide on disk; what stopped them coexisting was
# detection, which read two workflow docs as an ambiguous repo. The contract this
# suite pins:
#
#   - `task-config add assistant` installs the second loadout beside the first on
#     the same tracker, settings carried, the first one's files untouched;
#   - `task-config use` picks the active assistant in local git config, so a
#     switch changes no tracked file;
#   - precedence: --impl > $AW_IMPL > a launcher's --agent > the active assistant
#     > a single match, and the active assistant never resolves two loadouts on
#     different trackers;
#   - the two docs' tracker settings are checked for drift, and `sync` fixes it;
#   - `set` and `task-remove` handle the dual state, keeping what the pair shares
#     until the last of them goes; `set assistant` (or `set loadout` on the same
#     tracker) is refused there, and `remove assistant` is the explicit way to
#     drop one (#303);
#   - kiro-jira does not exist (#92), so jira cannot be dual.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

DETECT="$REPO_ROOT_REAL/lib/detect-impl.sh"

setup() {
  setup_repo
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  unset AW_IMPL TASK_FORCE_ROLE
  export ZELLIJ=fake-session
}

teardown() {
  teardown_all
}

# Install <loadout> for real, through its own task-init, so the artifact set under
# test is the one that ships.
_init() {
  local loadout="$1"; shift
  run "$REPO_ROOT_REAL/$loadout/bin/task-init" --force "$@"
  assert_success
}

_commit_all() {
  git -C "$MAIN_REPO" add -A
  git -C "$MAIN_REPO" commit -q -m "${1:-fixture}"
}

# Detection as a dispatcher sees it, from <dir> (default: the main checkout).
# Extra args go to aw_detect_impl: <flag-impl> <agent>.
_detect() {
  local dir="$MAIN_REPO"
  if [[ "${1:-}" == --in ]]; then dir="$2"; shift 2; fi
  run bash -c 'cd "$1" && source "$2" && aw_detect_impl "${3:-}" "${4:-}"' _ "$dir" "$DETECT" "$@"
}

# The workflow docs alone: the detection key, without a full install. Enough for
# the launchers, which only resolve a loadout and spawn a stubbed agent.
_dual_docs() {
  local tracker="${1:-gh}"
  mkdir -p "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.claude/$tracker-workflow.md" "$MAIN_REPO/.kiro/steering/$tracker-workflow.md"
  setup_kiro_agents
  _commit_all docs
}

_active() { git -C "$MAIN_REPO" config --get task-force.assistant || true; }

# A checksum of every path under <subdirs...> of the repo.
_sum() {
  (
    cd "$MAIN_REPO" || exit 1
    find "$@" -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -f "$p" ]]; then shasum "$p"; else printf 'dir %s\n' "$p"; fi
    done | shasum | cut -d' ' -f1
  )
}

# ---------------------------------------------------------------------------
# add assistant — gh, notion, local, with the settings carried
# ---------------------------------------------------------------------------

@test "add assistant kiro on claude-gh: carries owner/repo/project and leaves claude's files alone" {
  _init claude-gh --owner acme --repo widgets --project 7
  _commit_all claude
  local before
  before=$(_sum .claude CLAUDE.md)

  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  assert_output --partial "carrying  : owner=acme repo=widgets project=7"
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/agents/worker.json" ]
  grep -qF '`acme`' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  grep -qF '`widgets`' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  grep -qF '`7`' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  assert_equal "$(_sum .claude CLAUDE.md)" "$before"
  # Only kiro's files are new: nothing tracked was modified.
  run git -C "$MAIN_REPO" status --porcelain
  refute_output --partial " M "
  # The assistant you were on stays active, so nothing changes until you say so.
  assert_equal "$(_active)" claude
  _detect
  assert_success
  assert_output claude-gh
}

@test "add assistant claude on kiro-gh: the other direction carries the same settings" {
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant claude --yes
  assert_success
  grep -qF '`widgets`' "$MAIN_REPO/.claude/gh-workflow.md"
  grep -qxF '@.claude/gh-workflow.md' "$MAIN_REPO/CLAUDE.md"
  assert_equal "$(_active)" kiro
  _detect
  assert_output kiro-gh
}

@test "add assistant kiro on claude-notion: carries all three IDs (#225)" {
  _init claude-notion --tasks collection://t1 --projects collection://p2 --board b3
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  assert_output --partial "tasks=collection://t1"
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "Dual: claude and kiro are installed on notion."
  # Both blocks carry the same ids, and there is no drift to report.
  assert_equal "$(grep -c 'tasks=collection://t1 projects=collection://p2 board=b3' <<<"$output")" 2
  refute_output --partial "Drift"
}

@test "add assistant kiro on claude-local: the tasks/ backlog and scaffolding are untouched" {
  _init claude-local
  echo "# a real task" > "$MAIN_REPO/tasks/001-thing.md"
  local before
  before=$(_sum tasks .gitignore)
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  assert_output --partial "carrying  : nothing to carry"
  assert [ -f "$MAIN_REPO/.kiro/steering/local-workflow.md" ]
  assert_equal "$(_sum tasks .gitignore)" "$before"
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "loadout   : claude-local  (active)"
  assert_output --partial "loadout   : kiro-local"
}

@test "add assistant kiro on claude-jira: refused, naming #92, and nothing is written" {
  _init claude-jira --site https://acme.atlassian.net --key PROJ --board "My Board"
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_failure
  assert_output --partial "no 'kiro-jira' loadout"
  assert_output --partial "#92"
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert_equal "$(_active)" ""
}

@test "add: the assistant already installed, or both already installed, is a no-op" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant claude --yes
  assert_success
  assert_output --partial "nothing to add"
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  assert_output --partial "already installed"
}

@test "add --dry-run prints the install line and changes nothing" {
  _init claude-gh --owner acme --repo widgets --project 7
  _commit_all claude
  run "$TASK_CONFIG" add assistant kiro --dry-run
  assert_success
  assert_output --partial "kiro-gh/bin/task-init --force --owner acme --repo widgets --project 7"
  assert_output --partial "--dry-run: nothing was changed."
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert_equal "$(_active)" ""
}

@test "add: refuses a usage that is not 'add assistant <name>'" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add tracker local --yes
  assert_failure
  assert_output --partial "add assistant"
  run "$TASK_CONFIG" add assistant emacs --yes
  assert_failure
  assert_output --partial "unknown assistant"
}

# ---------------------------------------------------------------------------
# use — flips detection without touching a tracked file
# ---------------------------------------------------------------------------

@test "use flips detection and leaves git status exactly as it was" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  _commit_all dual
  local before
  before=$(git -C "$MAIN_REPO" status --porcelain --ignored)

  run "$TASK_CONFIG" use kiro
  assert_success
  assert_output --partial "active assistant: kiro"
  _detect
  assert_output kiro-gh
  assert_equal "$(git -C "$MAIN_REPO" status --porcelain --ignored)" "$before"

  run "$TASK_CONFIG" use claude
  assert_success
  _detect
  assert_output claude-gh
  assert_equal "$(git -C "$MAIN_REPO" status --porcelain --ignored)" "$before"
}

@test "use refuses an assistant that is not installed, pointing at add" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" use kiro
  assert_failure
  assert_output --partial "kiro-gh is not installed"
  assert_output --partial "task-config add assistant kiro"
  assert_equal "$(_active)" ""
}

@test "use refuses a repo whose loadouts are on different trackers" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-local
  run "$TASK_CONFIG" use kiro
  assert_failure
  assert_output --partial "different trackers"
  assert_equal "$(_active)" ""
}

@test "use --dry-run sets nothing" {
  _dual_docs
  run "$TASK_CONFIG" use kiro --dry-run
  assert_success
  assert_output --partial "--dry-run"
  assert_equal "$(_active)" ""
}

# ---------------------------------------------------------------------------
# precedence: --impl > AW_IMPL > --agent > active > single match
# ---------------------------------------------------------------------------

@test "precedence: a dual repo with no active assistant is refused, naming task-config use" {
  _dual_docs
  _detect
  assert_failure
  assert_output --partial "multiple agentic-workflow impls detected"
  assert_output --partial "task-config use <claude|kiro>"
}

@test "precedence: the active assistant resolves the dual repo" {
  _dual_docs
  git config task-force.assistant kiro
  _detect
  assert_success
  assert_output kiro-gh
  git config task-force.assistant claude
  _detect
  assert_output claude-gh
}

@test "precedence: --agent beats the active assistant" {
  _dual_docs
  git config task-force.assistant claude
  _detect "" kiro
  assert_success
  assert_output kiro-gh
}

@test "precedence: AW_IMPL beats the active assistant, and --impl beats AW_IMPL" {
  _dual_docs
  git config task-force.assistant claude
  AW_IMPL=kiro-gh _detect
  assert_output kiro-gh
  AW_IMPL=kiro-gh _detect claude-gh
  assert_output claude-gh
}

@test "precedence: --agent that contradicts --impl / AW_IMPL is refused, not silently dropped" {
  _dual_docs
  AW_IMPL=claude-gh _detect "" kiro
  assert_failure
  assert_output --partial "--agent kiro conflicts with loadout 'claude-gh'"
}

@test "precedence: --agent naming an assistant that is not installed is refused" {
  mkdir -p "$MAIN_REPO/.claude"; touch "$MAIN_REPO/.claude/gh-workflow.md"
  _detect "" kiro
  assert_failure
  assert_output --partial "no kiro loadout is configured"
  assert_output --partial "task-config add assistant kiro"
  _detect "" emacs
  assert_failure
  assert_output --partial "unknown agent 'emacs'"
}

@test "precedence: a single match wins over a stale active assistant" {
  mkdir -p "$MAIN_REPO/.claude"; touch "$MAIN_REPO/.claude/gh-workflow.md"
  git config task-force.assistant kiro
  _detect
  assert_success
  assert_output claude-gh
}

@test "different-tracker matches are still refused, whatever the active assistant says" {
  mkdir -p "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.claude/gh-workflow.md" "$MAIN_REPO/.kiro/steering/local-workflow.md"
  git config task-force.assistant kiro
  _detect
  assert_failure
  assert_output --partial "multiple agentic-workflow impls detected"
  assert_output --partial "Pass --impl"
  refute_output --partial "task-config use"
}

@test "different-tracker matches are still refused when --agent names one of them" {
  mkdir -p "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.claude/gh-workflow.md" "$MAIN_REPO/.kiro/steering/notion-workflow.md"
  _detect "" kiro
  assert_failure
  assert_output --partial "multiple agentic-workflow impls detected"
  assert_output --partial "Pass --impl"
  _detect "" claude
  assert_failure
  assert_output --partial "multiple agentic-workflow impls detected"
}

@test "a linked worktree resolves through the active assistant its main checkout set" {
  _dual_docs
  git config task-force.assistant kiro
  setup_worktree wt-probe
  _detect --in "$WORKTREE_BASE/wt-probe"
  assert_success
  assert_output kiro-gh
}

@test "aw_parse_agent_flag strips --agent in both spellings and keeps everything else" {
  run bash -c 'source "$1"; aw_parse_impl_flag a --agent kiro b --impl claude-gh -- --agent x
    aw_parse_agent_flag; printf "%s|" "$AW_PARSED_IMPL" "$AW_PARSED_AGENT" "${AW_REMAINING_ARGS[@]}"' _ "$DETECT"
  assert_success
  # Everything after `--` is positional, so a slug spelled --agent survives.
  assert_output "claude-gh|kiro|a|b|--|--agent|x|"
  run bash -c 'source "$1"; aw_parse_impl_flag --agent=claude s; aw_parse_agent_flag
    printf "%s|" "$AW_PARSED_AGENT" "${AW_REMAINING_ARGS[@]}"' _ "$DETECT"
  assert_output "claude|s|"
  run bash -c 'source "$1"; aw_parse_impl_flag --agent; aw_parse_agent_flag' _ "$DETECT"
  assert_failure
  assert_output --partial "--agent requires a value"
}

# ---------------------------------------------------------------------------
# show + drift
# ---------------------------------------------------------------------------

@test "show: a dual repo with an active assistant is described and exits 0" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "Dual: claude and kiro are installed on gh."
  assert_output --partial "active    : claude  (git config task-force.assistant"
  assert_output --partial "loadout   : claude-gh  (active)"
  assert_output --partial "loadout   : kiro-gh"
  refute_output --partial "Ambiguous"
}

@test "show: a dual repo with no active assistant says how to pick one and exits non-zero" {
  _init claude-gh --owner acme --repo widgets --project 7
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "active    : none"
  assert_output --partial "task-config use <claude|kiro>"
  refute_output --partial "Error:"
}

@test "show: drift between the two docs is flagged with both values, and exits non-zero" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  sed -i.bak 's/`widgets`/`gadgets`/' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  run "$TASK_CONFIG" show
  assert_failure
  assert_output --partial "Drift: the workflow docs disagree on the gh settings:"
  assert_output --partial "claude-gh=widgets"
  assert_output --partial "kiro-gh=gadgets"
  assert_output --partial "task-config sync"
  # Fields that agree are not listed.
  refute_output --regexp "owner +:"
}

@test "show: a stale active assistant on a single-loadout repo is named, not believed" {
  _init claude-gh --owner acme --repo widgets --project 7
  git config task-force.assistant kiro
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "active    : kiro (git config task-force.assistant) — not installed here, ignored"
}

@test "sync: the active assistant's doc wins and only the other doc is re-rendered" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  sed -i.bak 's/`widgets`/`gadgets`/' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  rm -f "$MAIN_REPO/.kiro/steering/gh-workflow.md.bak"
  local claude_doc
  claude_doc=$(_sum .claude/gh-workflow.md)
  run "$TASK_CONFIG" sync --yes
  assert_success
  assert_output --partial "claude-gh → kiro-gh"
  grep -qF '`widgets`' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  assert_equal "$(_sum .claude/gh-workflow.md)" "$claude_doc"
  run "$TASK_CONFIG" show
  assert_success
  refute_output --partial "Drift"
}

@test "sync --from copies the inactive assistant's settings instead" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  sed -i.bak 's/`widgets`/`gadgets`/' "$MAIN_REPO/.kiro/steering/gh-workflow.md"
  run "$TASK_CONFIG" sync --from kiro --yes
  assert_success
  grep -qF '`gadgets`' "$MAIN_REPO/.claude/gh-workflow.md"
  run "$TASK_CONFIG" sync --yes
  assert_success
  assert_output --partial "already carry the same gh settings"
}

@test "sync: refused outside a dual repo, and with no active assistant and no --from" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" sync --yes
  assert_failure
  assert_output --partial "sync needs both assistants installed"
  _init kiro-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" sync --yes
  assert_failure
  assert_output --partial "pass --from"
}

# ---------------------------------------------------------------------------
# set on a dual repo
# ---------------------------------------------------------------------------

# A dual repo committed clean, claude active: the state a refused command must
# leave exactly as it found it.
_dual_committed() {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  _commit_all dual
}

_assert_untouched() {
  run git -C "$MAIN_REPO" status --porcelain
  assert_output ""
  assert_equal "$(_active)" claude
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/agents/worker.json" ]
}

@test "set assistant on a dual repo is refused, changes nothing, and names use and remove (#303)" {
  _dual_committed
  local a
  for a in claude kiro; do
    run "$TASK_CONFIG" set assistant "$a" --yes
    assert_failure
    assert_output --partial "both assistants are installed here (claude-gh kiro-gh)"
    assert_output --partial "task-config use $a"
    assert_output --partial "task-config remove assistant $( [[ $a == claude ]] && echo kiro || echo claude )"
    refute_output --partial "removed"
    _assert_untouched
  done
}

@test "set loadout <assistant>-<same tracker> on a dual repo is refused like set assistant (#303)" {
  _dual_committed
  run "$TASK_CONFIG" set loadout claude-gh --yes
  assert_failure
  assert_output --partial "task-config use claude"
  assert_output --partial "task-config remove assistant kiro"
  _assert_untouched
}

@test "set assistant on a dual repo is refused without --yes too, before any prompt (#303)" {
  _dual_committed
  run bash -c "'$TASK_CONFIG' set assistant claude </dev/null"
  assert_failure
  refute_output --partial "Proceed?"
  _assert_untouched
}

@test "remove assistant drops only the other assistant's artifacts and makes the kept one active (#303)" {
  _dual_committed
  git config task-force.assistant kiro
  local before
  before=$(_sum .claude CLAUDE.md)
  run "$TASK_CONFIG" remove assistant kiro --yes
  assert_success
  assert_output --partial "removing kiro-gh, keeping claude-gh"
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert_equal "$(_sum .claude CLAUDE.md)" "$before"
  assert_equal "$(_active)" claude
  run bash -c "source '$DETECT'; aw_detect_matches '$MAIN_REPO'"
  assert_output claude-gh
  # Every change is a deletion under .kiro/: nothing of claude's was touched.
  run git -C "$MAIN_REPO" status --porcelain
  refute_line --regexp '^.. [^.]|^.. \.[^k]'
}

@test "remove assistant --dry-run previews the deletions and changes nothing (#303)" {
  _dual_committed
  run "$TASK_CONFIG" remove assistant kiro --dry-run
  assert_success
  assert_output --partial "removing kiro-gh:"
  assert_output --partial ".kiro/agents/worker.json"
  assert_output --partial "active assistant → claude"
  assert_output --partial "--dry-run: nothing was changed."
  _assert_untouched
}

@test "remove assistant is refused for the only assistant, one not installed, or a bad usage (#303)" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" remove assistant claude --yes
  assert_failure
  assert_output --partial "the only assistant installed here"
  assert_output --partial "task-remove"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  run "$TASK_CONFIG" remove assistant kiro --yes
  assert_failure
  assert_output --partial "kiro is not installed here"
  run "$TASK_CONFIG" remove tracker gh --yes
  assert_failure
  assert_output --partial "expected: task-config remove assistant"
  run "$TASK_CONFIG" remove assistant codex --yes
  assert_failure
  assert_output --partial "unknown assistant 'codex'"
}

@test "set assistant on a single-assistant repo still swaps, as before #293 (#303)" {
  _dual_committed
  run "$TASK_CONFIG" remove assistant kiro --yes
  assert_success
  run "$TASK_CONFIG" set assistant kiro --yes
  assert_success
  assert_output --partial "claude-gh → kiro-gh done."
  run bash -c "source '$DETECT'; aw_detect_matches '$MAIN_REPO'"
  assert_output kiro-gh
}

@test "show on a dual repo hints at the switch and the one-off launch (#303)" {
  _dual_committed
  run "$TASK_CONFIG" show
  assert_success
  assert_output --partial "switch: task-config use kiro · launch one: task-work … --agent kiro"
  git config task-force.assistant kiro
  run "$TASK_CONFIG" show
  assert_output --partial "switch: task-config use claude · launch one: task-work … --agent claude"
}

@test "set loadout on another tracker replaces both loadouts with the one named" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_CONFIG" set loadout claude-local --yes
  assert_success
  run bash -c "source '$DETECT'; aw_detect_matches '$MAIN_REPO'"
  assert_output claude-local
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  _detect
  assert_output claude-local
}

@test "set tracker on a dual repo is refused with the two-step recipe" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_CONFIG" set tracker local --yes
  assert_failure
  assert_output --partial "task-config set loadout claude-local"
  assert_output --partial "task-config add assistant"
  assert [ -f "$MAIN_REPO/.claude/gh-workflow.md" ]
  assert [ -f "$MAIN_REPO/.kiro/steering/gh-workflow.md" ]
}

@test "remove assistant on a local dual repo keeps the shared tasks/ scaffolding and .gitignore entry" {
  _init claude-local
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_CONFIG" remove assistant kiro --yes
  assert_success
  assert_output --partial "kept tasks/ scaffolding and the .gitignore entry — claude-local still uses them"
  assert [ -f "$MAIN_REPO/tasks/README.md" ]
  assert [ -f "$MAIN_REPO/tasks/_board.md" ]
  grep -qxF '.git/task-force/' "$MAIN_REPO/.gitignore"
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

# ---------------------------------------------------------------------------
# task-remove on a dual repo
# ---------------------------------------------------------------------------

@test "task-remove on a dual gh repo removes both and clears the active assistant" {
  _init claude-gh --owner acme --repo widgets --project 7
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_REMOVE" --yes
  assert_success
  assert_output --partial "removing claude-gh:"
  assert_output --partial "removing kiro-gh:"
  assert_output --partial "cleared the active assistant"
  assert [ ! -e "$MAIN_REPO/.claude" ]
  assert [ ! -e "$MAIN_REPO/.kiro" ]
  assert_equal "$(_active)" ""
}

@test "task-remove on a dual local repo walks the shared scaffolding once, and the plan says so" {
  _init claude-local
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_REMOVE" --dry-run
  assert_success
  assert_equal "$(grep -c 'would remove tasks/README.md' <<<"$output")" 1
  assert_equal "$(grep -c '.git/task-force/ entry' <<<"$output")" 1
  run "$TASK_REMOVE" --yes
  assert_success
  assert [ ! -e "$MAIN_REPO/tasks" ]
  assert [ ! -e "$MAIN_REPO/.gitignore" ]
  assert [ ! -e "$MAIN_REPO/.kiro" ]
}

@test "task-remove --impl on a dual local repo removes one and keeps what the other uses" {
  _init claude-local
  run "$TASK_CONFIG" add assistant kiro --yes
  run "$TASK_REMOVE" --impl kiro-local --yes
  assert_success
  assert_output --partial "claude-local still uses them"
  assert [ -f "$MAIN_REPO/tasks/README.md" ]
  grep -qxF '.git/task-force/' "$MAIN_REPO/.gitignore"
  # One loadout is left, so its choice stays: harmless, and right again on re-add.
  assert_equal "$(_active)" claude
}

# ---------------------------------------------------------------------------
# --agent: one launch on the other assistant
# ---------------------------------------------------------------------------

@test "task-work --agent kiro launches kiro in a claude-active repo and records AGENT=kiro" {
  _dual_docs
  git config task-force.assistant claude
  run "$TASK_WORK" probe-kiro --agent kiro
  assert_success
  run grep -m1 -F "new-tab --name probe-kiro" "$STUB_CALLS_DIR/zellij.calls"
  assert_output --partial "kiro-cli chat --agent worker"
  grep -qxF 'AGENT=kiro' "$WORKTREE_BASE/.probe-kiro.info"
  # Without the flag the repo's active assistant decides.
  run "$TASK_WORK" probe-claude
  assert_success
  run grep -m1 -F "new-tab --name probe-claude" "$STUB_CALLS_DIR/zellij.calls"
  refute_output --partial "kiro-cli"
  grep -qxF 'AGENT=claude' "$WORKTREE_BASE/.probe-claude.info"
  # The flag changed nothing persistent.
  assert_equal "$(_active)" claude
}

@test "task-pm --agent kiro launches the kiro PM in a claude-active repo" {
  _dual_docs
  git config task-force.assistant claude
  run "$TASK_PM" --agent kiro
  assert_success
  run stub_calls kiro-cli
  assert_output --partial "chat --agent pm"
}

@test "task-reviewer --agent kiro reviews on kiro in a claude-active repo" {
  _dual_docs
  git config task-force.assistant claude
  export GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  run "$TASK_REVIEWER" 42 --agent kiro
  assert_success
  run grep -m1 -F "new-tab --name review-pr42" "$STUB_CALLS_DIR/zellij.calls"
  assert_output --partial "kiro-cli chat --agent reviewer"
}

# A worker whose tab died, as task-work left it: worktree + sidecar, AGENT recorded.
_dead_worker() {
  local slug="$1" agent="$2"
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug"
  seed_hook_carriers "$WORKTREE_BASE/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nGH_URL=\nAGENT=%s\nTAB_ID=999\n' "$slug" "$agent" \
    > "$WORKTREE_BASE/.$slug.info"
}

@test "task-recreate-worker relaunches on the assistant task-work recorded, not the active one" {
  _dual_docs
  git config task-force.assistant claude
  _dead_worker issue-7 kiro
  run "$TASK_RECREATE_WORKER" issue-7
  assert_success
  assert_output --partial "Relaunching on kiro"
  run grep -m1 -F "new-tab --name issue-7" "$STUB_CALLS_DIR/zellij.calls"
  assert_output --partial "kiro-cli chat --agent worker"
}

@test "task-recreate-worker --agent overrides the recorded assistant" {
  _dual_docs
  git config task-force.assistant kiro
  _dead_worker issue-8 kiro
  run "$TASK_RECREATE_WORKER" issue-8 --agent claude
  assert_success
  refute_output --partial "Relaunching on"
  run grep -m1 -F "new-tab --name issue-8" "$STUB_CALLS_DIR/zellij.calls"
  refute_output --partial "kiro-cli"
}

@test "task-recreate-worker ignores a recorded assistant that is no longer installed" {
  mkdir -p "$MAIN_REPO/.claude"; touch "$MAIN_REPO/.claude/gh-workflow.md"
  _commit_all claude-only
  _dead_worker issue-9 kiro
  run "$TASK_RECREATE_WORKER" issue-9
  assert_success
  refute_output --partial "Relaunching on"
  run grep -m1 -F "new-tab --name issue-9" "$STUB_CALLS_DIR/zellij.calls"
  refute_output --partial "kiro-cli"
}

@test "task-done resolves a dual repo through the active assistant from a worker's worktree" {
  _dual_docs
  git config task-force.assistant kiro
  setup_worktree done-probe
  cd "$WORKTREE_BASE/done-probe"
  run "$TASK_DONE" --remove-worktree --force
  assert_success
  refute_output --partial "multiple agentic-workflow impls"
  assert [ ! -d "$WORKTREE_BASE/done-probe" ]
}

# ---------------------------------------------------------------------------
# Live worktrees that predate the assistant being switched to (#304)
# ---------------------------------------------------------------------------
# add and use change only the main checkout. A worktree forked before the other
# assistant's loadout was committed has no hooks for it, and a worker relaunched
# there on it would never register.

# A worker worktree as task-work leaves it, forked from main as it is NOW.
_live_worktree() {
  local slug="$1"
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/$slug" -b "task/$slug"
  printf 'BASE_BRANCH=main\nSLUG=%s\nGH_URL=\n' "$slug" > "$WORKTREE_BASE/.$slug.info"
}

_wt_phys() { printf '%s/%s-worktrees/%s' "$(cd "$MAIN_REPO/.." && pwd -P)" "$REPO_NAME" "$1"; }

@test "add assistant lists the live worktrees that lack the new assistant's hooks (#304)" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  _init claude-gh --owner acme --repo widgets --project 7
  _commit_all claude
  _live_worktree issue-7
  _live_worktree fresh-one
  seed_hook_carriers "$WORKTREE_BASE/fresh-one"
  _live_worktree review-pr9

  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  assert_output --partial "Warning: 1 live worktree(s) have no kiro radio hooks (.kiro/agents/worker.json)"
  assert_output --partial "git -C $(_wt_phys issue-7) merge main"
  refute_output --partial "fresh-one"
  refute_output --partial "review-pr9"
  # add has not committed anything, so the merge would bring nothing yet.
  assert_output --partial ".kiro/agents/worker.json is not committed on main yet"
}

@test "use lists the stale worktrees, and they drop off once merged (#304)" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  _init claude-gh --owner acme --repo widgets --project 7
  _commit_all claude
  _live_worktree issue-7
  run "$TASK_CONFIG" add assistant kiro --yes
  assert_success
  _commit_all dual

  run "$TASK_CONFIG" use kiro
  assert_success
  assert_output --partial "active assistant: kiro"
  assert_output --partial "Warning: 1 live worktree(s) have no kiro radio hooks"
  assert_output --partial "git -C $(_wt_phys issue-7) merge main"
  refute_output --partial "is not committed on main yet"

  git -C "$WORKTREE_BASE/issue-7" merge -q main
  run "$TASK_CONFIG" use claude
  assert_success
  run "$TASK_CONFIG" use kiro
  assert_success
  refute_output --partial "Warning"
}

@test "use warns, never refuses: the switch still happens (#304)" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  _init claude-gh --owner acme --repo widgets --project 7
  _commit_all claude
  _live_worktree issue-7
  run "$TASK_CONFIG" add assistant kiro --yes
  _commit_all dual
  run "$TASK_CONFIG" use kiro
  assert_success
  assert_equal "$(_active)" kiro
}
