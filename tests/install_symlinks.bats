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

# Resolve a ~/.local/bin symlink to its physical target path.
resolve_link() {
  local target
  target=$(readlink "$HOME/.local/bin/$1")
  echo "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
}

@test "all 7 installers: shared symlinks resolve to the canonical root copies" {
  # Every loadout must land radio / task-pm (and, where shipped, task-reviewer)
  # on the same root binaries — the exact regression class the #170
  # consolidation exists to prevent. Each installer runs against a clean
  # ~/.local/bin so a previous loadout's links can't mask a broken target.
  local impls=(claude-gh claude-jira claude-local claude-notion kiro-gh kiro-local kiro-notion)
  for impl in "${impls[@]}"; do
    rm -rf "$HOME/.local/bin"
    bash "$REPO_ROOT_REAL/$impl/install.sh" >/dev/null

    for cmd in task-init task-work task-done task-pm radio; do
      [ -L "$HOME/.local/bin/$cmd" ] || { echo "$impl: $cmd symlink missing"; return 1; }
      [ -e "$HOME/.local/bin/$cmd" ] || { echo "$impl: $cmd symlink dangling"; return 1; }
    done
    [ "$(resolve_link radio)" = "$REPO_ROOT_REAL/bin/radio" ] \
      || { echo "$impl: radio resolves to $(resolve_link radio)"; return 1; }
    [ "$(resolve_link task-pm)" = "$REPO_ROOT_REAL/bin/task-pm" ] \
      || { echo "$impl: task-pm resolves to $(resolve_link task-pm)"; return 1; }

    case "$impl" in
      claude-*|kiro-gh)
        [ -e "$HOME/.local/bin/task-reviewer" ] || { echo "$impl: task-reviewer missing/dangling"; return 1; }
        [ "$(resolve_link task-reviewer)" = "$REPO_ROOT_REAL/bin/task-reviewer" ] \
          || { echo "$impl: task-reviewer resolves to $(resolve_link task-reviewer)"; return 1; }
        ;;
      *)
        # kiro-local / kiro-notion ship no reviewer until #146.
        [ ! -e "$HOME/.local/bin/task-reviewer" ] || { echo "$impl: unexpected task-reviewer"; return 1; }
        ;;
    esac
  done
}
