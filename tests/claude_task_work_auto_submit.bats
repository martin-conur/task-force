#!/usr/bin/env bats
# Radio auto-submit is its own setting on the claude task-work copies (#246).
#
# Before this, `--auto` was the only way in, and it also meant
# `--permission-mode auto`: a worker could not get its mail submitted without
# also auto-accepting edits, and a worker deliberately launched *without*
# --auto (a release cut, say) silently lost auto-submit as a side effect.
#
# Contract, pinned on all four claude copies against the captured launch line
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

CLAUDE_TASK_WORK=(
  "$CLAUDE_GH_TASK_WORK"
  "$JIRA_TASK_WORK"
  "$CLAUDE_LOCAL_TASK_WORK"
  "$CLAUDE_NOTION_TASK_WORK"
)

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  mkdir -p "$MAIN_REPO/tasks"   # claude-local regenerates its board
}

teardown() {
  teardown_all
}

# Launch one copy with a fresh slug and print the claude launch line it sent
# to zellij. A fresh calls file per launch keeps copies from reading each
# other's lines.
_launch_line() {
  local tw="$1"; shift
  : > "$STUB_CALLS_DIR/zellij.calls"
  "$tw" "auto-sub-$RANDOM" "$@" >/dev/null 2>&1 || {
    echo "launch failed: $tw $*" >&2; return 1; }
  grep -m1 -F "new-tab --name" "$STUB_CALLS_DIR/zellij.calls"
}

@test "--auto-submit: auto-submit on, permission mode untouched (all claude copies)" {
  local tw line
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    line=$(_launch_line "$tw" --auto-submit)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]] || { echo "$tw: $line" >&2; return 1; }
    [[ "$line" != *"--permission-mode"* ]]          || { echo "$tw: $line" >&2; return 1; }
  done
}

@test "--auto: auto-submit AND --permission-mode auto (regression guard)" {
  local tw line
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    line=$(_launch_line "$tw" --auto)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]]   || { echo "$tw: $line" >&2; return 1; }
    [[ "$line" == *"claude --permission-mode auto "* ]] || { echo "$tw: $line" >&2; return 1; }
  done
}

@test "no flag: neither, with auto-submit explicitly off (regression guard)" {
  local tw line
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    line=$(_launch_line "$tw")
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]] || { echo "$tw: $line" >&2; return 1; }
    [[ "$line" != *"TASK_FORCE_AUTO_SUBMIT=1"* ]]  || { echo "$tw: $line" >&2; return 1; }
    [[ "$line" != *"--permission-mode"* ]]          || { echo "$tw: $line" >&2; return 1; }
  done
}

@test "--no-auto-submit wins over --auto in either order" {
  local tw line order
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    for order in "--auto --no-auto-submit" "--no-auto-submit --auto"; do
      # shellcheck disable=SC2086  # deliberate word split into two flags
      line=$(_launch_line "$tw" $order)
      [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=0 "* ]]      || { echo "$tw $order: $line" >&2; return 1; }
      [[ "$line" == *"claude --permission-mode auto "* ]] || { echo "$tw $order: $line" >&2; return 1; }
    done
  done
}

@test "--plan --auto-submit: plan mode with auto-submit (no longer mutually exclusive)" {
  local tw line
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    line=$(_launch_line "$tw" --plan --auto-submit)
    [[ "$line" == *"TASK_FORCE_AUTO_SUBMIT=1 "* ]]       || { echo "$tw: $line" >&2; return 1; }
    [[ "$line" == *"claude --permission-mode plan "* ]]  || { echo "$tw: $line" >&2; return 1; }
  done
}

@test "--help documents the split on every claude copy" {
  local tw
  for tw in "${CLAUDE_TASK_WORK[@]}"; do
    run "$tw" --help
    assert_output --partial "--auto-submit"
    assert_output --partial "--no-auto-submit"
  done
}

# The behaviour the whole issue is about, end to end: what --auto-submit puts on
# the launch line is what makes radio's wake end in CR instead of LF.
@test "a --auto-submit launch yields a CR wake; a plain launch yields LF" {
  setup_task_force_home
  export ZELLIJ=fake-session
  seed_zellij_tabs worker-on worker-off

  local on off
  on=$(_launch_line "$CLAUDE_GH_TASK_WORK" --auto-submit | grep -oE 'TASK_FORCE_AUTO_SUBMIT=[0-9]+')
  off=$(_launch_line "$CLAUDE_GH_TASK_WORK" | grep -oE 'TASK_FORCE_AUTO_SUBMIT=[0-9]+')
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
