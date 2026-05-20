#!/usr/bin/env bats
# Regression guard for issue #23: installer prompts must use `read -erp`
# (readline enabled) so arrow keys provide editing/history instead of
# echoing raw escape bytes (`^[[A`, `^[[B`, ...).
#
# Recursive on purpose — any future loadout that adds a `bin/task-init`
# or an installer `*.sh` is auto-covered. Vendored bats submodules under
# tests/libs/ are excluded to avoid upstream false-positives.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

@test "installer prompts use 'read -erp' (readline enabled)" {
  # Match `read -rp` NOT preceded by `-e` (i.e. not `read -erp`). Skip comment lines.
  run grep -rnE '^[[:space:]]*[^#[:space:]].*\bread -rp\b' "$REPO_ROOT_REAL" \
    --include='task-init' --include='*.sh' \
    --exclude-dir='libs'
  assert_failure
}
