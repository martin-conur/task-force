#!/usr/bin/env bash
# Build and link the task-monitor TUI (#277). Sourced by every loadout's
# install.sh from inside its drift-guarded install-shared-symlinks stanza.
#
# Exports:
#   aw_install_monitor <task-force-root>
#
# With `cargo` on PATH it runs `cargo build --release` on <root>/monitor and
# links the binary into ~/.local/bin/task-monitor. Without cargo it prints one
# line saying how to get the monitor and links nothing. A failed build warns
# and links nothing. Neither case fails the install: the bash commands
# (task-monitor-snapshot included) are what the rest of task-force runs on, and
# the monitor is a view over them.
#
# The binary's path is read off cargo's own JSON (the compiler-artifact
# message's "executable"), not assumed to be monitor/target/release: a
# CARGO_TARGET_DIR or a build.target-dir in ~/.cargo/config.toml moves it. The
# binary finds bin/task-monitor-snapshot through its canonicalized current_exe,
# which only works while it stays inside the checkout, so a target dir outside
# it needs $TASK_MONITOR_SNAPSHOT; the warning below says so.

aw_install_monitor() {
  local root
  root=$(cd "$1" && pwd)
  local manifest="$root/monitor/Cargo.toml"
  local binary
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  - Skipped: task-monitor (no cargo on PATH; install Rust >= 1.88 from https://rustup.rs and re-run this installer)"
    return 0
  fi
  echo "  … Building task-monitor (cargo build --release; the first build takes a minute or two)"
  binary=$(cargo build --release --quiet --message-format=json-render-diagnostics \
      --manifest-path "$manifest" \
    | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' | tail -n 1) || binary=""
  if [[ -z "$binary" || ! -x "$binary" ]]; then
    echo "  ! task-monitor build failed; not linked. Retry with: cargo build --release --manifest-path $manifest" >&2
    return 0
  fi
  ln -sf "$binary" ~/.local/bin/task-monitor
  echo "  ✓ Binary: task-monitor (Rust TUI, built from monitor/)"
  case "$(cd "$(dirname "$binary")" && pwd -P)/" in
    "$(cd "$root" && pwd -P)/"*) ;;
    *) echo "  ! task-monitor was built outside the checkout ($binary); export TASK_MONITOR_SNAPSHOT=$root/bin/task-monitor-snapshot so it finds its data" >&2 ;;
  esac
}
