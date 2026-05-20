#!/usr/bin/env bats
# Regression guard for issue #23: installer prompts must use `read -erp`
# (readline enabled) so arrow keys provide editing/history instead of
# echoing raw escape bytes (`^[[A`, `^[[B`, ...).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

@test "installer prompts use 'read -erp' (readline enabled)" {
  local files=(
    "$REPO_ROOT_REAL/install.sh"
    "$REPO_ROOT_REAL/task-init"
    "$REPO_ROOT_REAL/claude-jira/bin/task-init"
    "$REPO_ROOT_REAL/claude-gh/bin/task-init"
    "$REPO_ROOT_REAL/kiro-gh/bin/task-init"
  )
  # Match `read -rp` NOT preceded by `-e` (i.e. not `read -erp`). Skip comments.
  run grep -nE '^[[:space:]]*[^#[:space:]].*\bread -rp\b' "${files[@]}"
  assert_failure
}
