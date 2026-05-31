#!/usr/bin/env bats
# Tests for bin/task-reviewer: in-place reviewer-tab takeover.
# Asserts:
#   - rename-tab to "reviewer" via zellij (when $ZELLIJ is set)
#   - exec's `claude /reviewer`
#   - errors out cleanly outside a git repo
#   - sets ANTHROPIC_MODEL to claude-sonnet-4-6 (default) and respects an
#     existing value if pre-set
#   - dispatcher routes to the claude-gh variant when the workflow doc exists

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_repo
  setup_stubs
  cd "$MAIN_REPO"
  export ZELLIJ=fake-session
}

teardown() {
  teardown_all
}

# ----- claude variant -------------------------------------------------------

@test "claude task-reviewer renames the current tab to reviewer and exec's claude /reviewer" {
  run "$TASK_REVIEWER_CLAUDE"
  assert_success
  assert_stub_called zellij "action rename-tab reviewer"
  run stub_calls claude
  assert_output --partial "/reviewer"
}

@test "claude task-reviewer: works without zellij (\$ZELLIJ unset → no rename)" {
  unset ZELLIJ
  run "$TASK_REVIEWER_CLAUDE"
  assert_success
  run stub_calls zellij
  refute_output --partial "rename-tab"
  run stub_calls claude
  assert_output --partial "/reviewer"
}

@test "claude task-reviewer errors out cleanly outside a git repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  run "$TASK_REVIEWER_CLAUDE"
  assert_failure
  assert_output --partial "not in a git repo"
  rm -rf "$outside"
}

@test "claude task-reviewer defaults ANTHROPIC_MODEL to claude-sonnet-4-6" {
  # Replace the claude stub with one that dumps its env, so we can assert.
  cat >"$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "${STUB_CALLS_DIR}/claude.calls"
printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL:-}" >> "${STUB_CALLS_DIR}/claude.env"
printf 'TASK_FORCE_ROLE=%s\n' "${TASK_FORCE_ROLE:-}" >> "${STUB_CALLS_DIR}/claude.env"
printf 'TASK_FORCE_LOADOUT=%s\n' "${TASK_FORCE_LOADOUT:-}" >> "${STUB_CALLS_DIR}/claude.env"
printf 'ZELLIJ_TAB=%s\n' "${ZELLIJ_TAB:-}" >> "${STUB_CALLS_DIR}/claude.env"
EOF
  chmod +x "$STUB_BIN/claude"

  run "$TASK_REVIEWER_CLAUDE"
  assert_success

  run cat "$STUB_CALLS_DIR/claude.env"
  assert_output --partial "ANTHROPIC_MODEL=claude-sonnet-4-6"
  assert_output --partial "TASK_FORCE_LOADOUT=reviewer"
  assert_output --partial "ZELLIJ_TAB=reviewer"
  # Role is reviewer-<repo-basename>; the basename is whatever mktemp produced.
  assert_output --partial "TASK_FORCE_ROLE=reviewer-$(basename "$MAIN_REPO")"
}

@test "claude task-reviewer honors a pre-set ANTHROPIC_MODEL" {
  cat >"$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "${STUB_CALLS_DIR}/claude.calls"
printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL:-}" >> "${STUB_CALLS_DIR}/claude.env"
EOF
  chmod +x "$STUB_BIN/claude"

  ANTHROPIC_MODEL=claude-opus-4-7 run "$TASK_REVIEWER_CLAUDE"
  assert_success

  run cat "$STUB_CALLS_DIR/claude.env"
  assert_output --partial "ANTHROPIC_MODEL=claude-opus-4-7"
  refute_output --partial "ANTHROPIC_MODEL=claude-sonnet-4-6"
}

# ----- kiro variant ---------------------------------------------------------

@test "kiro task-reviewer renames the current tab to reviewer and exec's kiro-cli reviewer agent" {
  run "$TASK_REVIEWER_KIRO"
  assert_success
  assert_stub_called zellij "action rename-tab reviewer"
  run stub_calls kiro-cli
  assert_output --partial "chat --agent reviewer"
}

@test "kiro task-reviewer errors out cleanly outside a git repo" {
  local outside
  outside=$(mktemp -d)
  cd "$outside"
  run "$TASK_REVIEWER_KIRO"
  assert_failure
  assert_output --partial "not in a git repo"
  rm -rf "$outside"
}

# ----- dispatcher -----------------------------------------------------------

@test "top-level task-reviewer dispatches to the claude-gh variant based on workflow doc" {
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/gh-workflow.md"

  run "$TASK_REVIEWER_DISPATCHER"
  assert_success
  run stub_calls claude
  assert_output --partial "/reviewer"
}

@test "top-level task-reviewer dispatches to the kiro-gh variant based on workflow doc" {
  mkdir -p "$MAIN_REPO/.kiro/steering"
  touch "$MAIN_REPO/.kiro/steering/gh-workflow.md"

  run "$TASK_REVIEWER_DISPATCHER"
  assert_success
  run stub_calls kiro-cli
  assert_output --partial "chat --agent reviewer"
}

@test "top-level task-reviewer errors cleanly when no workflow doc is present" {
  run "$TASK_REVIEWER_DISPATCHER"
  assert_failure
  assert_output --partial "no agentic-workflow impl configured"
}

@test "top-level task-reviewer errors cleanly for impls without a reviewer variant" {
  # claude-local has no task-reviewer (only claude-gh + kiro-gh do). The
  # dispatcher should surface a clear error, not the generic "Is the
  # repository complete?" one.
  mkdir -p "$MAIN_REPO/.claude"
  touch "$MAIN_REPO/.claude/local-workflow.md"

  run "$TASK_REVIEWER_DISPATCHER"
  assert_failure
  assert_output --partial "task-reviewer is not available for impl"
}
