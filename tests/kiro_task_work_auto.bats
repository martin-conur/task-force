#!/usr/bin/env bats
# `task-work --auto` on the kiro loadouts (#206).
#
# The `radio-env-injection` region is byte-identical across all seven
# `task-work` copies and ends with:
#
#     [[ -n "${AUTO_MODE:-}" ]] && RADIO_ENV_PREFIX+="TASK_FORCE_AUTO_SUBMIT=1 "
#
# `$AUTO_MODE` is set by the flag loop, which is per-loadout and *outside* the
# region — so `tools/check-drift.sh` can prove the region identical while the
# variable it reads is undefinable in three of the hosts. That is exactly what
# happened: the kiro copies had no `--auto` case, so the line was dead and
# `task-work <slug> --auto` aborted with `unknown flag`.
#
# Pinned here:
#   - every host of the region can actually set AUTO_MODE (the precondition
#     drift-checking cannot see);
#   - `--auto` on each kiro loadout launches and injects
#     TASK_FORCE_AUTO_SUBMIT=1, which `radio register` persists as
#     AUTO_SUBMIT=1 → CR wake-up (see radio_auto_submit.bats);
#   - without `--auto`, nothing is injected (LF, human gate — unchanged);
#   - `--auto` and `-a/--trust-all` stay orthogonal: kiro's permission model is
#     `--trust-all-tools`, `--auto` governs radio auto-submit only.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# Every task-work copy that carries the shared region. The claude ones are
# included deliberately: the invariant under test is "host defines what the
# region reads", not "kiro was fixed".
ALL_TASK_WORK=(
  "$CLAUDE_GH_TASK_WORK"
  "$JIRA_TASK_WORK"
  "$CLAUDE_LOCAL_TASK_WORK"
  "$CLAUDE_NOTION_TASK_WORK"
  "$KIRO_GH_TASK_WORK"
  "$KIRO_LOCAL_TASK_WORK"
  "$KIRO_TASK_WORK"
)

setup() {
  setup_repo
  setup_kiro_agents   # kiro launchers preflight the agent (#218)
  setup_stubs
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

# The kiro copies take their spec argument in different shapes, so each test
# that launches one goes through this.
kiro_launch() {
  local impl="$1"; shift
  case "$impl" in
    gh)     run "$KIRO_GH_TASK_WORK" my-feature "$@" ;;
    local)  run "$KIRO_LOCAL_TASK_WORK" my-feature "$@" ;;
    notion) run "$KIRO_TASK_WORK" my-feature "$@" ;;
  esac
}

# ---------------------------------------------------------------------------
# The precondition drift-checking can't see
# ---------------------------------------------------------------------------

@test "every host of the radio-env-injection region can set AUTO_MODE (#206)" {
  for f in "${ALL_TASK_WORK[@]}"; do
    assert [ -f "$f" ]
    # Sanity: the file really does carry the region that reads AUTO_MODE.
    run grep -qFx '# region:radio-env-injection' "$f"
    assert_success
    run grep -qF '${AUTO_MODE:-}' "$f"
    assert_success
    # …and its own flag loop can set it. Without this the line above is inert
    # and drift stays green (#206).
    run grep -qE '^\s*--auto\) AUTO_MODE="1"; shift ;;$' "$f"
    assert_success
  done
}

# ---------------------------------------------------------------------------
# --auto launches and injects the opt-in
# ---------------------------------------------------------------------------

@test "kiro-gh: --auto launches and injects TASK_FORCE_AUTO_SUBMIT=1" {
  kiro_launch gh --auto
  assert_success
  refute_output --partial "unknown flag"
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

@test "kiro-local: --auto launches and injects TASK_FORCE_AUTO_SUBMIT=1" {
  kiro_launch local --auto
  assert_success
  refute_output --partial "unknown flag"
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

@test "kiro-notion: --auto launches and injects TASK_FORCE_AUTO_SUBMIT=1" {
  kiro_launch notion --auto
  assert_success
  refute_output --partial "unknown flag"
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

# ---------------------------------------------------------------------------
# Without --auto: unchanged (LF wake-up, human gate)
# ---------------------------------------------------------------------------

@test "kiro-gh: no --auto → no TASK_FORCE_AUTO_SUBMIT" {
  kiro_launch gh
  assert_success
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro-local: no --auto → no TASK_FORCE_AUTO_SUBMIT" {
  kiro_launch local
  assert_success
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro-notion: no --auto → no TASK_FORCE_AUTO_SUBMIT" {
  kiro_launch notion
  assert_success
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# --auto and --trust-all are orthogonal axes
# ---------------------------------------------------------------------------

@test "kiro --auto does not imply --trust-all-tools (permission model unchanged)" {
  kiro_launch gh --auto
  assert_success
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
  run grep -F -- "--trust-all-tools" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro --trust-all does not imply auto-submit" {
  kiro_launch gh --trust-all
  assert_success
  assert_stub_called zellij "--trust-all-tools"
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

@test "kiro --trust-all --auto: both apply" {
  kiro_launch gh --trust-all --auto
  assert_success
  assert_stub_called zellij "--trust-all-tools"
  assert_stub_called zellij "TASK_FORCE_AUTO_SUBMIT=1"
}

# ---------------------------------------------------------------------------
# The injected prefix still reaches kiro-cli as environment
# ---------------------------------------------------------------------------

@test "kiro --auto: 'set +H' precedes the radio env prefix (#144 round-4)" {
  kiro_launch gh --auto
  assert_success
  local cmd_line
  cmd_line=$(grep -m1 -F "new-tab --name my-feature" "$STUB_CALLS_DIR/zellij.calls")
  local set_pos="${cmd_line%%set +H;*}"
  local auto_pos="${cmd_line%%TASK_FORCE_AUTO_SUBMIT=*}"
  [[ ${#set_pos} -lt ${#auto_pos} ]] || {
    echo "'set +H;' must precede TASK_FORCE_AUTO_SUBMIT in: $cmd_line" >&2; return 1; }
}

@test "kiro --auto with --no-launch: no kiro-cli, so no injected env" {
  kiro_launch gh --auto --no-launch
  assert_success
  assert_output --partial "kiro NOT launched"
  run grep -F "TASK_FORCE_AUTO_SUBMIT" "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------

@test "kiro --help documents --auto as auto-submit only" {
  for tw in "$KIRO_GH_TASK_WORK" "$KIRO_LOCAL_TASK_WORK" "$KIRO_TASK_WORK"; do
    run "$tw" --help
    assert_success
    assert_output --partial "--auto"
    assert_output --partial "auto-submit"
    # Names the separate permission flag so nobody reads --auto as trust-all.
    assert_output --partial "-a/--trust-all"
  done
}
