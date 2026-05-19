#!/usr/bin/env bash
# Shared worktree creation. Sourced by every <impl>/bin/task-work.
#
# Exports:
#   aw_create_worktree <worktree_dir> <branch> [from_ref]
#
# Forks the new branch from <from_ref> (defaults to HEAD).
#
# Tries to create the worktree on a new branch (-b). If that fails because
# the branch already exists, reuses it — but emits a loud warning to stderr
# showing how the branch tip diverges from <from_ref>. This catches the
# foot-gun of running `task-work` after the worktree was deleted but the
# branch wasn't, which would otherwise silently base the new worktree on
# stale code (issue #38).

aw_create_worktree() {
  local worktree_dir="$1"
  local branch="$2"
  local from_ref="${3:-HEAD}"

  if git worktree add "$worktree_dir" -b "$branch" "$from_ref" 2>/dev/null; then
    return 0
  fi

  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Error: could not create worktree at '$worktree_dir'." >&2
    echo "       Possibly a stale worktree registration — try: git worktree prune" >&2
    return 1
  fi

  if ! git worktree add "$worktree_dir" "$branch" 2>/dev/null; then
    echo "Error: could not create worktree at '$worktree_dir'." >&2
    echo "       Possibly a stale worktree registration — try: git worktree prune" >&2
    return 1
  fi

  local from_label="$from_ref"
  if [[ "$from_label" = "HEAD" ]]; then
    from_label=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  fi

  local branch_tip branch_subj from_tip from_subj behind ahead
  branch_tip=$(git rev-parse --short "$branch" 2>/dev/null || echo "?")
  branch_subj=$(git log -1 --format=%s "$branch" 2>/dev/null || echo "?")
  from_tip=$(git rev-parse --short "$from_ref" 2>/dev/null || echo "?")
  from_subj=$(git log -1 --format=%s "$from_ref" 2>/dev/null || echo "?")
  behind=$(git rev-list --count "$branch..$from_ref" 2>/dev/null || echo "?")
  ahead=$(git rev-list --count "$from_ref..$branch" 2>/dev/null || echo "?")

  {
    echo ""
    echo "⚠ Branch $branch already exists. Reusing it."
    echo "  Branch tip:               $branch_tip ($branch_subj)"
    echo "  Current HEAD on $from_label: $from_tip ($from_subj)"
    echo "  Divergence:               $ahead ahead, $behind behind $from_label"
    echo "  If the branch is stale, exit and run: git branch -D $branch"
    echo ""
  } >&2
}
