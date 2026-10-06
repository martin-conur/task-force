#!/usr/bin/env bats
# bin/task-work's agent axis (#237): what lib/agents/<agent>.sh decides.
#
# The extra flags, the launch line, the completion message — and the one seam
# the module shape made risky: the agent module gets first refusal on every
# command-line token, so an agent flag would shadow a shared one on a name
# collision. There are none today; the parity section below is what makes a
# future one fail loudly instead of silently rebinding a shared flag.
#
# Radio auto-submit is its own setting, not a side effect of permission mode
# (#246). On claude --auto also means --permission-mode auto; on kiro it means
# auto-submit only, because kiro's permission model is --trust-all-tools. The
# contract on the claude loadouts, pinned against the captured launch line
# (never against the parsed flag):
#   --auto-submit           TASK_FORCE_AUTO_SUBMIT=1, no --permission-mode auto
#   --auto                  both (every existing doc and habit uses this)
#   (nothing)               neither — and the off is an explicit `=0`, because
#                           radio reads an unset value as "restore this role's
#                           recorded setting", which a fresh launch must not do
#   --auto --no-auto-submit permission mode only, in either order
#   --plan --auto-submit    auto-submit composes with plan mode

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

# Every impl on <agent>, derived rather than listed.
_impls_on() { bash -c "source '$DETECT'; aw_all_impls" | grep "^$1-"; }

# Launch one impl with a fresh slug and print the launch line it sent to zellij.
# A fresh calls file per launch keeps impls from reading each other's lines.
_launch_line() {
  local impl="$1"; shift
  : > "$STUB_CALLS_DIR/zellij.calls"
  env AW_IMPL="$impl" "$TASK_WORK" "launch-$RANDOM" "$@" >/dev/null 2>&1 || {
    echo "launch failed: $impl $*" >&2; return 1; }
  grep -m1 -F "new-tab --name" "$STUB_CALLS_DIR/zellij.calls"
}

# ---------------------------------------------------------------------------
# Shared flags: identical under every agent module
# ---------------------------------------------------------------------------

# Structural half: no agent module claims a shared flag's token. Every token
# the body's own `case` owns is listed; adding a shared flag means adding it.
SHARED_FLAG_TOKENS=(-h --help -b --base -f --from --no-launch --auto
                    --auto-submit --no-auto-submit --)

@test "no agent module claims a shared flag (first refusal never shadows)" {
  local agent tok
  for agent in $(bash -c "source '$DETECT'; aw_all_agents"); do
    for tok in "${SHARED_FLAG_TOKENS[@]}"; do
      run bash -c "
        AW_ROOT='$REPO_ROOT_REAL'
        source \"\$AW_ROOT/lib/agents/$agent.sh\"
        aw_agent_init_flags
        aw_agent_parse_flag '$tok' value
      "
      [[ "$status" -ne 0 ]] || {
        echo "agent '$agent' claims shared flag '$tok' — it would shadow the body's arm" >&2
        return 1; }
    done
  done
}

# Behavioural half: the shared flags land the same observable on every agent.
@test "-b / -f / --no-launch / --auto behave identically under every agent" {
  git -C "$MAIN_REPO" checkout -q -b feature-x
  echo "x" > "$MAIN_REPO/x.txt"
  git -C "$MAIN_REPO" add x.txt
  git -C "$MAIN_REPO" commit -q -m "x"
  local feat_head agent impl slug
  feat_head=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C "$MAIN_REPO" checkout -q main

  for agent in $(bash -c "source '$DETECT'; aw_all_agents"); do
    impl="$agent-gh"; slug="parity-$agent"
    : > "$STUB_CALLS_DIR/zellij.calls"
    ZELLIJ=1 STUB_ZELLIJ_TABS_JSON='[{"name":"pm","position":0,"active":true}]' \
      run env AW_IMPL="$impl" "$TASK_WORK" -b develop -f feature-x --no-launch --auto "$slug"
    [[ "$status" -eq 0 ]] || { echo "$impl: exit $status: $output" >&2; return 1; }
    [[ "$(source "$WORKTREE_BASE/.$slug.info"; echo "$BASE_BRANCH")" == develop ]] || {
      echo "$impl: -b did not set BASE_BRANCH" >&2; return 1; }
    [[ "$(git -C "$WORKTREE_BASE/$slug" rev-parse HEAD)" == "$feat_head" ]] || {
      echo "$impl: -f did not fork from feature-x" >&2; return 1; }
    [[ "$output" == *"NOT launched (--no-launch)"* ]] || {
      echo "$impl: --no-launch not honoured: $output" >&2; return 1; }
    # --auto still snaps focus back to the calling tab with --no-launch.
    run grep -F -- "go-to-tab 1" "$STUB_CALLS_DIR/zellij.calls"
    [[ "$status" -eq 0 ]] || {
      echo "$impl: --auto did not keep focus" >&2; cat "$STUB_CALLS_DIR/zellij.calls" >&2; return 1; }
  done
}

@test "-h / --help exit 0 under every agent" {
  local agent flag
  for agent in $(bash -c "source '$DETECT'; aw_all_agents"); do
    for flag in -h --help; do
      run env AW_IMPL="$agent-gh" "$TASK_WORK" "$flag"
      [[ "$status" -eq 0 && "$output" == Usage:* ]] || {
        echo "$agent $flag: exit $status: $output" >&2; return 1; }
    done
  done
}

@test "an unknown flag is refused under every agent" {
  local agent
  for agent in $(bash -c "source '$DETECT'; aw_all_agents"); do
    run env AW_IMPL="$agent-gh" "$TASK_WORK" --unknown-flag my-feature
    assert_failure
    assert_output --partial "unknown flag '--unknown-flag'"
  done
}

# Each agent's own flags are its own: the other module refuses them.
@test "claude's --plan is an unknown flag on kiro; kiro's -m / -a are unknown on claude" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" --plan my-feature
  assert_failure
  assert_output --partial "unknown flag '--plan'"
  run env AW_IMPL=claude-gh "$TASK_WORK" -m some-model my-feature
  assert_failure
  assert_output --partial "unknown flag '-m'"
  run env AW_IMPL=claude-gh "$TASK_WORK" -a my-feature
  assert_failure
  assert_output --partial "unknown flag '-a'"
}

# ---------------------------------------------------------------------------
# claude: radio auto-submit vs permission mode (#246)
# ---------------------------------------------------------------------------

@test "claude --auto-submit: auto-submit on, permission mode untouched (all claude impls)" {
  local impl line
  for impl in $(_impls_on claude); do
    line=$(_launch_line "$impl" --auto-submit)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]] || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" != *"--permission-mode"* ]]          || { echo "$impl: $line" >&2; return 1; }
  done
}

@test "claude --auto: auto-submit AND --permission-mode auto (all claude impls)" {
  local impl line
  for impl in $(_impls_on claude); do
    line=$(_launch_line "$impl" --auto)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]]      || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" == *"claude --permission-mode auto "* ]] || { echo "$impl: $line" >&2; return 1; }
  done
}

@test "claude, no flag: neither, with auto-submit explicitly off (all claude impls)" {
  local impl line
  for impl in $(_impls_on claude); do
    line=$(_launch_line "$impl")
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]] || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" != *"TASK_FORCE_AUTO_SUBMIT=1"* ]]  || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" != *"--permission-mode"* ]]          || { echo "$impl: $line" >&2; return 1; }
  done
}

@test "claude --no-auto-submit wins over --auto in either order (all claude impls)" {
  local impl line order
  for impl in $(_impls_on claude); do
    for order in "--auto --no-auto-submit" "--no-auto-submit --auto"; do
      # shellcheck disable=SC2086  # deliberate word split into two flags
      line=$(_launch_line "$impl" $order)
      [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]]      || { echo "$impl $order: $line" >&2; return 1; }
      [[ "$line" == *"claude --permission-mode auto "* ]] || { echo "$impl $order: $line" >&2; return 1; }
    done
  done
}

@test "claude --plan --auto-submit: plan mode with auto-submit (all claude impls)" {
  local impl line
  for impl in $(_impls_on claude); do
    line=$(_launch_line "$impl" --plan --auto-submit)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]]      || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" == *"claude --permission-mode plan "* ]] || { echo "$impl: $line" >&2; return 1; }
  done
}

@test "claude --auto --plan is refused on every claude impl" {
  local impl
  for impl in $(_impls_on claude); do
    run env AW_IMPL="$impl" "$TASK_WORK" --auto --plan my-feature
    assert_failure
    assert_output --partial "--auto and --plan are mutually exclusive"
  done
}

@test "claude --help documents the auto-submit split on every claude impl" {
  local impl
  for impl in $(_impls_on claude); do
    run env AW_IMPL="$impl" "$TASK_WORK" --help
    assert_success
    assert_output --partial "--auto-submit"
    assert_output --partial "--no-auto-submit"
    assert_output --partial "--permission-mode auto"
  done
}

# The behaviour the whole of #246 is about, end to end: what --auto-submit puts
# on the launch line is what makes radio's wake end in CR instead of LF.
@test "a --auto-submit launch yields a CR wake; a plain launch yields LF" {
  setup_task_force_home
  export ZELLIJ=fake-session
  seed_zellij_tabs worker-on worker-off

  local on off
  on=$(_launch_line claude-gh --auto-submit | grep -oE 'TASK_FORCE_AUTO_SUBMIT=[0-9]+')
  off=$(_launch_line claude-gh | grep -oE 'TASK_FORCE_AUTO_SUBMIT=[0-9]+')
  env "$on"  "$RADIO" register --role worker-on  --tab worker-on  --agent claude
  env "$off" "$RADIO" register --role worker-off --tab worker-off --agent claude

  : > "$STUB_CALLS_DIR/zellij.calls"
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-on --intent changes-requested --body "rework"
  run grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls"
  assert_output "1"

  : > "$STUB_CALLS_DIR/zellij.calls"
  TASK_FORCE_ROLE=pm "$RADIO" send --to worker-off --intent changes-requested --body "rework"
  run grep -cF $'radio check\r' "$STUB_CALLS_DIR/zellij.calls"
  assert_output "0"
  assert_stub_called zellij "radio check"
}

# ---------------------------------------------------------------------------
# kiro: -m / -a, their env defaults, and --auto as auto-submit only (#206)
# ---------------------------------------------------------------------------

@test "kiro -m / --model passes the model to kiro-cli" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" -m claude-opus-4.6 my-feature
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker --model claude-opus-4.6"
  run env AW_IMPL=kiro-gh "$TASK_WORK" --model claude-sonnet-4.5 other-feature
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker --model claude-sonnet-4.5"
}

@test "kiro -a / --trust-all passes --trust-all-tools to kiro-cli" {
  local flag
  for flag in -a --trust-all; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    run env AW_IMPL=kiro-gh "$TASK_WORK" "$flag" "trust$flag"
    assert_success
    assert_stub_called zellij "kiro-cli chat --agent worker --trust-all-tools"
  done
}

@test "kiro TASK_WORK_MODEL sets the default model" {
  TASK_WORK_MODEL=claude-sonnet-4.6 run env AW_IMPL=kiro-gh "$TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "--model claude-sonnet-4.6"
}

@test "kiro TASK_WORK_TRUST_ALL=1/true/yes enables --trust-all-tools; other values do not" {
  local v
  for v in 1 true TRUE yes YES; do
    : > "$STUB_CALLS_DIR/zellij.calls"
    TASK_WORK_TRUST_ALL="$v" run env AW_IMPL=kiro-gh "$TASK_WORK" "on-$v"
    assert_success
    assert_stub_called zellij "--trust-all-tools"
  done
  : > "$STUB_CALLS_DIR/zellij.calls"
  TASK_WORK_TRUST_ALL=0 run env AW_IMPL=kiro-gh "$TASK_WORK" off-0
  assert_success
  run grep -F -- "--trust-all-tools" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro --model missing its value is an error" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" --model
  assert_failure
  assert_output --partial "--model requires a value"
}

@test "kiro --no-launch opens the tab without starting kiro-cli" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" --no-launch my-feature
  assert_success
  assert_output --partial "kiro NOT launched"
  run grep -F "kiro-cli" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro free-form slug: bare worker invocation, no payload" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" my-feature
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker"
  run grep -F "Implement task:" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro with a ref: the payload is a bare positional, no /worker wrapper" {
  local url="https://github.com/owner/repo/issues/42"
  run env AW_IMPL=kiro-gh "$TASK_WORK" my-feature "$url"
  assert_success
  assert_stub_called zellij "kiro-cli chat --agent worker \"Implement task: $url\""
  run grep -F "/worker" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro completion message names the model and trust-all" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" -m X -a my-feature
  assert_success
  assert_output --partial "Started worker [model=X] [trust-all] in "
}

@test "kiro --auto does not imply --trust-all-tools (permission model unchanged)" {
  local impl line
  for impl in $(_impls_on kiro); do
    line=$(_launch_line "$impl" --auto)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]] || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" != *"--trust-all-tools"* ]]          || { echo "$impl: $line" >&2; return 1; }
    [[ "$line" != *"--permission-mode"* ]]          || { echo "$impl: $line" >&2; return 1; }
  done
}

@test "kiro --trust-all does not imply auto-submit" {
  local line
  line=$(_launch_line kiro-gh --trust-all)
  [[ "$line" == *"--trust-all-tools"* ]]         || { echo "$line" >&2; return 1; }
  [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]] || { echo "$line" >&2; return 1; }
}

@test "kiro --trust-all --auto: both apply" {
  local line
  line=$(_launch_line kiro-gh --trust-all --auto)
  [[ "$line" == *"--trust-all-tools"* ]]         || { echo "$line" >&2; return 1; }
  [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]] || { echo "$line" >&2; return 1; }
}

@test "kiro --auto: 'set +H' precedes the radio env prefix (#144 round-4)" {
  local line set_pos auto_pos
  line=$(_launch_line kiro-gh --auto)
  set_pos="${line%%set +H;*}"
  auto_pos="${line%%TASK_FORCE_AUTO_SUBMIT=*}"
  [[ "$line" == *"set +H;"* && ${#set_pos} -lt ${#auto_pos} ]] || {
    echo "'set +H;' must precede TASK_FORCE_AUTO_SUBMIT in: $line" >&2; return 1; }
}

@test "kiro --auto with --no-launch: no kiro-cli, so no injected env" {
  run env AW_IMPL=kiro-gh "$TASK_WORK" my-feature --auto --no-launch
  assert_success
  assert_output --partial "kiro NOT launched"
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro --help documents --auto as auto-submit only, on every kiro impl" {
  local impl
  for impl in $(_impls_on kiro); do
    run env AW_IMPL="$impl" "$TASK_WORK" --help
    assert_success
    assert_output --partial "--auto"
    assert_output --partial "auto-submit"
    # Names the separate permission flag so nobody reads --auto as trust-all.
    assert_output --partial "-a/--trust-all"
    assert_output --partial "TASK_WORK_TRUST_ALL"
  done
}
