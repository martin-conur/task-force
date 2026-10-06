#!/usr/bin/env bash
# PATH isolation guard (#223).
#
# task-work / task-done resolve `task-board` from $PATH *in preference to* this
# checkout's own root copy, and the commit-msg hook resolves `ci-guard` the same way.
# install.sh plants ~/.local/bin/<cmd> as a symlink into whichever checkout ran
# the installer last, so on any machine that has ever installed task-force the
# suite silently exercised **another checkout's** binary instead of the one under
# test. The two `regenerates tasks/_board.md` tests were the visible casualty:
# the foreign copy is the root bin/task-board, which refuses on a fixture repo that
# has no workflow doc, and a `|| true` on the call swallowed that so the only
# symptom was a missing artifact two assertions later, with nothing naming the
# cause. CI has nothing installed, so it took the sibling-copy fallback and
# passed — the suite was red for exactly the people most likely to run it and
# green for the machine that gates merges.
#
# Same class as the $TASK_FORCE_HOME leakage #203 fixed — a test reaching out of
# its fixture into real machine state — so it gets the same two layers:
#   * tests/setup_suite.bash rewrites $PATH once per run so that no task-force
#     command is reachable, while keeping everything *else* those directories
#     provide (jq, gh, python, …) available through a mirror of symlinks;
#   * this guard, invoked when tests/helpers/common.bash loads, fails loudly if
#     one is reachable anyway — a bats invocation that never picked up
#     setup_suite.bash, or a future regression in the rewrite.
#
# Sourced by both tests/setup_suite.bash and tests/helpers/common.bash.

# Every command the loadout installers symlink into ~/.local/bin. A test must
# reach the checkout under test through an explicit path ($CLAUDE_LOCAL_TASK_WORK
# and friends in helpers/common.bash), never through $PATH — so all eleven are
# stripped, not just the two that are currently resolved by name.
AW_TASK_FORCE_COMMANDS=(
  task-init task-work task-done task-board task-pm
  task-reviewer task-config task-remove task-recreate-worker radio ci-guard
)

# True when $1 names one of them.
_aw_is_task_force_command() {
  local name="$1" cmd
  for cmd in "${AW_TASK_FORCE_COMMANDS[@]}"; do
    [[ "$name" == "$cmd" ]] && return 0
  done
  return 1
}

# True when directory $1 exposes an executable task-force command.
_aw_dir_has_task_force_command() {
  local dir="$1" cmd
  for cmd in "${AW_TASK_FORCE_COMMANDS[@]}"; do
    [[ -x "$dir/$cmd" ]] && return 0
  done
  return 1
}

# Mirror directory $1 into $2 as symlinks, minus the task-force commands.
# Symlinks point at "$src/<name>" rather than at its target, so a relative
# symlink inside $src still resolves. Prints $2.
_aw_mirror_dir_without_task_force() {
  local src="$1" dest="$2" entry base globstate
  mkdir -p "$dest"
  globstate=$(shopt -p nullglob dotglob)
  shopt -s nullglob dotglob
  for entry in "$src"/*; do
    base=${entry##*/}
    _aw_is_task_force_command "$base" && continue
    # An unreadable or otherwise unlinkable entry is not worth failing over:
    # the mirror is a convenience, the stripping is the point.
    ln -sfn "$entry" "$dest/$base" 2>/dev/null || true
  done
  eval "$globstate"
  printf '%s' "$dest"
}

# Print "<command> -> <resolved path>" for every task-force command currently
# reachable on $PATH. Empty output means this process is isolated.
task_force_commands_on_path() {
  local cmd resolved
  # bash's command hash table is consulted before $PATH, so a rewrite that has
  # already happened could otherwise be reported stale.
  hash -r 2>/dev/null || true
  for cmd in "${AW_TASK_FORCE_COMMANDS[@]}"; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    printf '%s -> %s\n' "$cmd" "$resolved"
  done
}

# Print a $PATH from which no task-force command can be resolved, without losing
# anything else those directories provide. A directory holding one is replaced by
# a mirror of symlinks to its *other* entries rather than dropped outright:
# ~/.local/bin routinely carries jq, gh or python alongside the task-force
# symlinks, and dropping it wholesale would trade this bug for a worse one.
# Mirrors are created under $1, which the caller owns and must clean up.
sanitize_path_of_task_force() {
  local mirror_root="${1:?mirror root required}"
  local out='' seen='' dir n=0
  local -a dirs=()
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    # An empty entry means "the current directory" — never something a test
    # should be resolving a binary from, so it goes rather than being mirrored.
    [[ -n "$dir" ]] || continue
    # A $PATH listing the same directory twice is common and harmless in itself,
    # but mirroring it twice is not: each repeat would mint another mirror under
    # $mirror_root. Keep the first occurrence, which is the one that resolves.
    case ":$seen:" in *":$dir:"*) continue ;; esac
    seen+="${seen:+:}$dir"
    if _aw_dir_has_task_force_command "$dir"; then
      n=$((n + 1))
      dir=$(_aw_mirror_dir_without_task_force "$dir" \
        "$mirror_root/$(printf '%02d' "$n")-${dir##*/}")
    fi
    out+="${out:+:}$dir"
  done
  printf '%s' "$out"
}

# Fail loudly when a task-force command is reachable on $PATH. Returns 1
# (callers decide whether to exit).
require_task_force_free_path() {
  local leaked line
  leaked=$(task_force_commands_on_path)
  [[ -z "$leaked" ]] && return 0
  # printf and read, not `cat <<MSG`: this guard's whole subject is a $PATH that
  # resolves the wrong things, and a broken one would swallow the complaint.
  # shellcheck disable=SC2016  # prose for a human: `$PATH` is named, not expanded
  printf '%s\n' \
    'ERROR: refusing to run tests with task-force commands on $PATH (#223).' \
    '' \
    'Reachable by name:' >&2
  while IFS= read -r line; do printf '  %s\n' "$line" >&2; done <<< "$leaked"
  # shellcheck disable=SC2016,SC2088  # prose for a human: `$PATH` and `~/.local/bin` are named, not expanded
  printf '%s\n' \
    '' \
    "task-work and task-done prefer \$PATH's task-board over their own sibling" \
    'copy, so these shadow the checkout under test with whichever one' \
    '~/.local/bin points at — the suite then exercises another clone and fails' \
    'for reasons that have nothing to do with your change. Run the suite via' \
    './run_tests.sh (or any bats invocation that picks up' \
    'tests/setup_suite.bash), which rewrites $PATH for the run.' >&2
  return 1
}
