#!/usr/bin/env bash
# Shared worktree creation. Sourced by every <impl>/bin/task-work.
#
# Exports:
#   aw_create_worktree <worktree_dir> <branch> <base_branch>
#
# Tries to create the worktree on a new branch (-b). If that fails because
# the branch already exists, reuses it — but emits a loud warning to stderr
# showing how the branch tip diverges from <base_branch>. This catches the
# foot-gun of running `task-work` after the worktree was deleted but the
# branch wasn't, which would otherwise silently base the new worktree on
# stale code (issue #38).

aw_create_worktree() {
  local worktree_dir="$1"
  local branch="$2"
  local base_branch="$3"

  if git worktree add "$worktree_dir" -b "$branch" 2>/dev/null; then
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

  local branch_tip branch_subj base_tip base_subj behind ahead
  branch_tip=$(git rev-parse --short "$branch" 2>/dev/null || echo "?")
  branch_subj=$(git log -1 --format=%s "$branch" 2>/dev/null || echo "?")
  base_tip=$(git rev-parse --short "$base_branch" 2>/dev/null || echo "?")
  base_subj=$(git log -1 --format=%s "$base_branch" 2>/dev/null || echo "?")
  behind=$(git rev-list --count "$branch..$base_branch" 2>/dev/null || echo "?")
  ahead=$(git rev-list --count "$base_branch..$branch" 2>/dev/null || echo "?")

  {
    echo ""
    echo "⚠ Branch $branch already exists. Reusing it."
    echo "  Branch tip:               $branch_tip ($branch_subj)"
    echo "  Current HEAD on $base_branch: $base_tip ($base_subj)"
    echo "  Divergence:               $ahead ahead, $behind behind $base_branch"
    echo "  If the branch is stale, exit and run: git branch -D $branch"
    echo ""
  } >&2
}
