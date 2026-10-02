#!/usr/bin/env bash
# Default bodies for every tracker hook. Sourced by a canonical leaf script
# BEFORE the tracker's own module, which overrides only what it needs (#236).
#
# This file is meant to be sourced, not executed.
#
# The defaults are not neutral stubs — they are the behaviour four of the seven
# loadouts actually had, which is the whole reason this shape removes
# duplication rather than relocating it. `gh` and `notion` override nothing
# here; if they had to restate an identical PR section the seven copies would
# just have become four.
#
# A hook that a tracker genuinely has nothing to do for is a no-op returning 0,
# not an absent function: the parity suite asserts every hook resolves for every
# impl (`declare -F`), so "the module forgot to define it" and "this tracker has
# nothing to do" stay distinguishable.

# ---------------- task-done hooks ----------------

# aw_tracker_usage_steps
#
# The numbered list inside task-done's usage(). Printed, not returned.
aw_tracker_usage_steps() {
  echo "  1. Show the diff summary and existing PR (or print gh pr create command)"
  echo "  2. Remove the worktree"
  echo "  3. Close the zellij tab"
}

# aw_tracker_pr_section <base_branch> <branch> <slug>
#
# Show the existing PR, or print the command that would create it.
#
# Every tracker shells out to `gh` here, including notion and local — the PR
# lives on the forge whatever the spec is tracked in, so this is deliberately
# not abstracted away from `gh`. Only the --title differs, and only on jira.
aw_tracker_pr_section() {
  local base_branch="$1" branch="$2" pr_url
  pr_url=$(gh pr view --json url -q .url 2>/dev/null || true)
  if [[ -n "$pr_url" ]]; then
    echo "PR: $pr_url"
  else
    echo "To create a PR:"
    echo "  gh pr create --base $base_branch --head $branch --title \"${branch#task/}\" --fill"
  fi
}

# aw_tracker_post_cleanup <main_worktree> <slug> <impl>
#
# Fires mid-cleanup, after the info file is removed and before the branch is
# deleted. Tracker-local bookkeeping that has to happen while the slug is still
# known. Called with `|| true` at the site, because by then the worktree and the
# tab are already gone and there is nothing useful left to abort.
aw_tracker_post_cleanup() { :; }
