#!/usr/bin/env bash
# Worktree-proof main-repo name for radio roles (#165 RC-2 / RC-6).
#
# Inside a linked git worktree, `basename $(git rev-parse --show-toplevel)` is
# the *worktree* directory name (the task slug), not the repository — so radio
# roles derived from it (`pm-<reponame>`, `worker-<reponame>-<slug>`) would key
# off the slug and never match across worktrees. `git rev-parse --git-common-dir`
# points at the shared `.git` of the main worktree regardless of which worktree
# we're standing in; its parent directory is the repository root. The result is
# sanitized to radio's role charset ([a-z0-9-]) so a repo with a dot or other
# character (`my.app`) can't produce a role name `_validate_role` rejects (#165
# RC-6) — mirrors task-work's `sanitize_slug`.

# Sanitize an arbitrary string to radio's role-segment charset. Keep this
# byte-identical with radio's `_sanitize_role_segment` and task-work's
# `sanitize_slug` so a repo name derived launcher-side and re-derived
# register-side resolve to the same role.
aw_sanitize_repo_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g'
}

# Print the sanitized main-repo name for the git repo containing $1 (default cwd).
# Falls back to the sanitized basename of $1 when git can't answer (not a repo).
aw_main_repo_name() {
  local dir="${1:-$PWD}" common root
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || {
    aw_sanitize_repo_name "$(basename "$dir")"; return; }
  [[ -n "$common" ]] || { aw_sanitize_repo_name "$(basename "$dir")"; return; }
  # --git-common-dir is absolute for a linked worktree, relative (".git") for
  # the main worktree — resolve it against $dir in the relative case.
  case "$common" in /*) : ;; *) common="$dir/$common" ;; esac
  root=$(cd "$common/.." 2>/dev/null && pwd) || root="$dir"
  aw_sanitize_repo_name "$(basename "$root")"
}
