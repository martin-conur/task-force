#!/usr/bin/env bats
# The per-impl table for the canonical bin/task-work (#237).
#
# tests/loadout_modules.bats proves every hook RESOLVES for every impl. That is
# structural, and #206 is why it is not enough: a region can be byte-identical
# and still inert when a precondition differs per host. So each row here asserts
# an impl-distinguishing observable that a failed or wrong module load cannot
# produce — the tracker's own .info key, the agent's own binary and flags, both
# axes' tokens in --help, and --auto's radio prefix.
#
# Rows are DERIVED from aw_all_impls, never listed: a hard-coded list is
# satisfied by its own copy and says nothing when the real one grows. What is
# literal is the expectation per axis (_tracker_* / _agent_* below), and an axis
# value with no expectation fails the row instead of being skipped — so a new
# combo built from a new module must add its expectations here.
#
# Detection is real, not pinned: each row seeds that impl's workflow doc and
# runs with AW_IMPL unset, so the table also covers the path a user actually
# takes from a repo root.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

DETECT="$REPO_ROOT_REAL/lib/detect-impl.sh"

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  cd "$MAIN_REPO"
  mkdir -p "$MAIN_REPO/tasks"   # the local tracker regenerates its board
  unset AW_IMPL
}

teardown() {
  teardown_all
}

_impls() { bash -c "source '$DETECT'; aw_all_impls"; }

# Mark $MAIN_REPO as an <impl> repo the way task-init would: its workflow doc.
_seed_impl() {
  local impl="$1" doc
  rm -rf "$MAIN_REPO/.claude" "$MAIN_REPO/.kiro/steering"
  doc=$(bash -c "source '$DETECT'; aw_impl_workflow_doc '$MAIN_REPO' '$impl'")
  mkdir -p "$(dirname "$doc")"
  : > "$doc"
}

# A ref in this tracker's own shape for slug $2, and the key it must land under.
_tracker_ref() {
  case "$1" in
    gh)     echo "https://github.com/owner/repo/issues/42" ;;
    jira)   echo "PROJ-42" ;;
    notion) echo "https://www.notion.so/Row-Page-abc123def456abc123def456abc123de" ;;
    local)  echo "x" > "$MAIN_REPO/tasks/042-$2.md"
            echo "$MAIN_REPO/tasks/042-$2.md" ;;
    *)      echo "no _tracker_ref expectation for tracker '$1' — add one" >&2; return 1 ;;
  esac
}
_tracker_key() {
  case "$1" in
    gh) echo GH_URL ;; jira) echo JIRA_REF ;; notion) echo NOTION_URL ;; local) echo TASK_FILE ;;
    *)  echo "no _tracker_key expectation for tracker '$1' — add one" >&2; return 1 ;;
  esac
}
# A token from this tracker's usage synopsis that no other tracker prints.
_tracker_help_token() {
  case "$1" in
    gh) echo "<gh-url>" ;; jira) echo "<jira-key-or-url>" ;;
    notion) echo "<notion-url>" ;; local) echo "tasks/NNN-slug.md" ;;
    *)  echo "no _tracker_help_token expectation for tracker '$1' — add one" >&2; return 1 ;;
  esac
}

# The launch line's agent binary + the flag a launch with $2 must carry.
_agent_launch_prefix() {
  case "$1" in
    claude) echo 'claude ' ;; kiro) echo 'kiro-cli chat --agent worker' ;;
    *)      echo "no _agent_launch_prefix expectation for agent '$1' — add one" >&2; return 1 ;;
  esac
}
_agent_flag_args() {
  case "$1" in claude) echo "--auto" ;; kiro) echo "--trust-all" ;;
    *) echo "no _agent_flag_args expectation for agent '$1' — add one" >&2; return 1 ;; esac
}
_agent_flag_token() {
  case "$1" in claude) echo "--permission-mode auto" ;; kiro) echo "--trust-all-tools" ;;
    *) echo "no _agent_flag_token expectation for agent '$1' — add one" >&2; return 1 ;; esac
}
_agent_help_token() {
  case "$1" in claude) echo "-p, --plan" ;; kiro) echo "-m, --model" ;;
    *) echo "no _agent_help_token expectation for agent '$1' — add one" >&2; return 1 ;; esac
}

_launch_line() {
  grep -m1 -F "new-tab --name $1" "$STUB_CALLS_DIR/zellij.calls"
}

@test "the table has a row per impl, and every axis value has expectations" {
  local impls impl
  impls=$(_impls)
  assert [ -n "$impls" ]
  for impl in $impls; do
    _tracker_key "${impl##*-}" >/dev/null
    _tracker_help_token "${impl##*-}" >/dev/null
    _agent_launch_prefix "${impl%%-*}" >/dev/null
    _agent_flag_token "${impl%%-*}" >/dev/null
    _agent_help_token "${impl%%-*}" >/dev/null
  done
}

@test "each impl writes its own tracker's .info key, holding the ref" {
  local impl tracker key ref slug n=0
  for impl in $(_impls); do
    tracker="${impl##*-}"; n=$((n + 1))
    _seed_impl "$impl"
    slug="row-$n"
    key=$(_tracker_key "$tracker"); ref=$(_tracker_ref "$tracker" "$slug")
    # local has no `<slug> <ref>` form — the file name is the slug — so its
    # row passes the file alone, named so it derives the same slug.
    if [[ "$tracker" == local ]]; then
      run "$TASK_WORK_DISPATCHER" "$ref"
    else
      run "$TASK_WORK_DISPATCHER" "$slug" "$ref"
    fi
    [[ "$status" -eq 0 ]] || { echo "$impl: exit $status: $output" >&2; return 1; }
    run grep -Fx "$key=$ref" "$WORKTREE_BASE/.$slug.info"
    [[ "$status" -eq 0 ]] || {
      echo "$impl: .$slug.info lacks '$key=$ref':" >&2; cat "$WORKTREE_BASE/.$slug.info" >&2; return 1; }
  done
}

@test "each impl launches its own agent's binary, carrying that agent's flag" {
  local impl agent prefix flag_tok line slug n=0
  for impl in $(_impls); do
    agent="${impl%%-*}"; n=$((n + 1))
    _seed_impl "$impl"
    prefix=$(_agent_launch_prefix "$agent"); flag_tok=$(_agent_flag_token "$agent")
    slug="agent-$n"
    # shellcheck disable=SC2046  # the flag is one word per agent
    run "$TASK_WORK_DISPATCHER" "$slug" $(_agent_flag_args "$agent")
    [[ "$status" -eq 0 ]] || { echo "$impl: exit $status: $output" >&2; return 1; }
    line=$(_launch_line "$slug")
    # The agent command follows the radio prefix, so assert it is the command
    # AFTER the last env assignment rather than merely present somewhere.
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT="[01]" $prefix"* ]] || {
      echo "$impl: launch is not '$prefix…': $line" >&2; return 1; }
    [[ "$line" == *"$flag_tok"* ]] || { echo "$impl: no '$flag_tok': $line" >&2; return 1; }
  done
}

@test "each impl's --help carries its tracker's synopsis and its agent's options" {
  local impl ttok atok
  for impl in $(_impls); do
    _seed_impl "$impl"
    ttok=$(_tracker_help_token "${impl##*-}"); atok=$(_agent_help_token "${impl%%-*}")
    run "$TASK_WORK_DISPATCHER" --help
    [[ "$status" -eq 0 ]] || { echo "$impl: --help exit $status" >&2; return 1; }
    [[ "$output" == *"$ttok"* ]] || { echo "$impl: --help lacks '$ttok'" >&2; return 1; }
    [[ "$output" == *"$atok"* ]] || { echo "$impl: --help lacks '$atok'" >&2; return 1; }
  done
}

# --auto's effect on the radio prefix is the canonical body's, and no module may
# redefine it (#237 seam 2). On claude --auto also means --permission-mode auto,
# on kiro it does not — so the one thing both must share is this.
@test "--auto sets TASK_FORCE_AUTO_SUBMIT=1 on every impl; plain sets =0" {
  local impl line n=0
  for impl in $(_impls); do
    n=$((n + 1))
    _seed_impl "$impl"
    run "$TASK_WORK_DISPATCHER" "on-$n" --auto
    [[ "$status" -eq 0 ]] || { echo "$impl --auto: exit $status: $output" >&2; return 1; }
    line=$(_launch_line "on-$n")
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]] || { echo "$impl --auto: $line" >&2; return 1; }

    run "$TASK_WORK_DISPATCHER" "off-$n"
    [[ "$status" -eq 0 ]] || { echo "$impl plain: exit $status: $output" >&2; return 1; }
    line=$(_launch_line "off-$n")
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]] || { echo "$impl plain: $line" >&2; return 1; }
  done
}
