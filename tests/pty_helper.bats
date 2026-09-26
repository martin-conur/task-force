#!/usr/bin/env bats
# Tests for the pty test helper itself — tests/helpers/common.bash's
# pty_stdin / pty_run / require_pty.
#
# Background (#207): `pty_run` is how the #198 tty-branch tests get a terminal
# on stdin. It shells out to `script`, which copies the *invoking* terminal's
# attributes onto the pty it allocates — so it calls tcgetattr() on whatever
# fd 0 it inherits. A tty is fine, a pipe or /dev/null yields ENOTTY that
# `script` tolerates, and a socket makes BSD `script` abort outright:
#
#   script: tcgetattr/ioctl: Operation not supported on socket
#
# An agent harness hands its child a socket, so the #198 tests failed there for
# a reason that had nothing to do with radio — and only on some invocations,
# because the same harness hands out a character device on others. A test that
# goes red for reasons unrelated to what it asserts teaches whoever runs the
# suite to discount red, which is the habit that hides a real regression.
#
# The fix stops inheriting fd 0. These tests pin that: the child still gets a
# real pty, it gets one from a socket-stdin caller too, and when no pty can be
# had the helper skips out loud instead of letting `script`'s error masquerade
# as a failure of the command under test.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
}

teardown() {
  teardown_all
}

@test "pty_run gives the command under test a real tty on stdin (#198's precondition)" {
  require_pty
  run pty_run '[ -t 0 ] && printf tty-on-stdin'
  assert_success
  assert_output "tty-on-stdin"
}

@test "pty_run allocates a pty even when the caller's stdin is a socket (#207)" {
  require_pty
  command -v python3 >/dev/null 2>&1 \
    || skip "python3 is how this test manufactures a socket on stdin"

  # `bash -c` under a socketpair — the fd shape an agent harness hands its
  # child, and the one that used to abort `script`. The inner script proves
  # the shape before using it, so this cannot pass vacuously on a host (or a
  # future harness) that quietly hands out something friendlier.
  local inner='
    [ -S /dev/fd/0 ] || { printf "stdin-is-not-a-socket"; exit 1; }
    source "'"$REPO_ROOT_REAL"'/tests/helpers/common.bash"
    pty_run "[ -t 0 ] && printf pty-ok"
  '
  run python3 -c '
import socket, subprocess, sys
a, _b = socket.socketpair()
sys.exit(subprocess.run(sys.argv[1:], stdin=a.fileno()).returncode)
' bash -c "$inner"

  assert_success
  refute_output --partial "stdin-is-not-a-socket"
  refute_output --partial "tcgetattr"
  assert_output --partial "pty-ok"
}

@test "pty_stdin never hands script the inherited fd (#207)" {
  # The whole fix in one assertion: whatever fd 0 is, the helper names a
  # device instead of passing it through.
  run pty_stdin
  assert_success
  case "$output" in
    /dev/tty | /dev/null) return 0 ;;
  esac
  fail "pty_stdin should pin /dev/tty or /dev/null, got: $output"
}

@test "pty_run strips the pty's own EOF echo from the child's output (#207)" {
  require_pty
  # On the /dev/null arm `script` closes the pty's input at once and the
  # terminal echoes that back as "^D\b\b". Left in, it prefixes the first line
  # and breaks assert_output on output the child never produced.
  run pty_run 'printf hello'
  assert_success
  assert_output "hello"
}

@test "pty_run still propagates the child's exit status (#198 assert_failure contract)" {
  require_pty
  run pty_run 'exit 7'
  assert_failure 7
}

@test "require_pty skips with a stated reason rather than silently (#207)" {
  # A skip nobody can read is worse than the flake it replaces: "not run" and
  # "passed" look identical in the summary. Stub bats' `skip` so the reason is
  # observable, and take `script` off PATH so the guard has to fire.
  _capture_skip() {
    skip() { printf 'skipped: %s' "$*"; exit 0; }
    PATH=$(mktemp -d) require_pty
    printf 'require_pty-returned-without-skipping'
  }
  run _capture_skip
  assert_success
  assert_output --partial "skipped: "
  assert_output --partial "script"
  refute_output --partial "require_pty-returned-without-skipping"
}

@test "pty_run's input argument answers a read prompt on the pty (#219)" {
  require_pty
  # The ordering trap this form exists to dodge: with the writer closed at once,
  # BSD `script` pushes ^D into the pty ahead of the bytes it buffered, and the
  # child's `read` fails with an empty answer.
  run pty_run '[ -t 0 ] || exit 9; read -rp "Q? " r; printf "GOT=[%s]" "$r"' $'hello\n'
  assert_success
  assert_output --partial "GOT=[hello]"
}

@test "pty_run with no input argument leaves the child at EOF (the pre-#219 behaviour)" {
  require_pty
  run pty_run 'if read -rp "Q? " r; then printf "GOT=[%s]" "$r"; else printf "EOF"; fi'
  assert_success
  assert_output --partial "EOF"
}
