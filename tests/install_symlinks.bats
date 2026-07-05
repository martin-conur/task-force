#!/usr/bin/env bats
# Per-loadout install.sh symlink coverage. Asserts that running each loadout's
# install.sh creates the expected symlinks under ~/.local/bin (with $HOME
# pointed at a tempdir so the real ~/.local/bin is not touched).

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  FAKE_HOME=$(mktemp -d)
  export HOME="$FAKE_HOME"
}

teardown() {
  [[ -z "${FAKE_HOME:-}" ]] || rm -rf "$FAKE_HOME"
}

@test "claude-gh install symlinks task-pm and radio into ~/.local/bin" {
  bash "$REPO_ROOT_REAL/claude-gh/install.sh" >/dev/null
  assert [ -L "$HOME/.local/bin/task-pm" ]
  assert [ -L "$HOME/.local/bin/radio" ]
  # And the existing dispatchers are still there.
  assert [ -L "$HOME/.local/bin/task-work" ]
  assert [ -L "$HOME/.local/bin/task-done" ]
}

@test "kiro-gh install symlinks task-pm and radio into ~/.local/bin" {
  bash "$REPO_ROOT_REAL/kiro-gh/install.sh" >/dev/null
  assert [ -L "$HOME/.local/bin/task-pm" ]
  assert [ -L "$HOME/.local/bin/radio" ]
}

@test "claude-local install symlinks task-pm and radio into ~/.local/bin" {
  bash "$REPO_ROOT_REAL/claude-local/install.sh" >/dev/null
  assert [ -L "$HOME/.local/bin/task-pm" ]
  assert [ -L "$HOME/.local/bin/radio" ]
  # claude-local also adds the task-board symlink.
  assert [ -L "$HOME/.local/bin/task-board" ]
}

@test "radio symlink target is the canonical root bin/radio" {
  bash "$REPO_ROOT_REAL/claude-gh/install.sh" >/dev/null
  local target resolved
  target=$(readlink "$HOME/.local/bin/radio")
  # The installer links $SCRIPT_DIR/../bin/radio — resolve the ../ and pin
  # the physical path to the single canonical copy (#170).
  resolved=$(cd "$(dirname "$target")" && pwd)/$(basename "$target")
  [[ "$resolved" == "$REPO_ROOT_REAL/bin/radio" ]]
}
