#!/usr/bin/env bash
# Jira tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed.
#
# One override for task-done, and it was the entire difference between
# claude-jira/bin/task-done and the other four tracker-backed copies — seven
# lines, sitting in the one part of that file the drift checker did not guard.

# A Jira key is uppercase (PROJ-123) but a branch name is not: task-work
# lowercases the key to build `task/proj-123`, so the default's
# `${branch#task/}` would title the PR `proj-123`. Uppercase it back when the
# slug still looks like a key, and leave a free-form slug alone — `task-work
# some-feature` on a jira repo is a supported shape and its PR should not be
# shouted.
aw_tracker_pr_section() {
  local base_branch="$1" branch="$2" slug="$3" pr_url pr_title
  pr_url=$(gh pr view --json url -q .url 2>/dev/null || true)
  if [[ -n "$pr_url" ]]; then
    echo "PR: $pr_url"
    return 0
  fi
  if [[ "$slug" =~ ^([a-z][a-z0-9_]+-[0-9]+)$ ]]; then
    pr_title=$(echo "$slug" | tr '[:lower:]' '[:upper:]')
  else
    pr_title="$slug"
  fi
  echo "To create a PR:"
  echo "  gh pr create --base $base_branch --head $branch --title \"$pr_title\" --fill"
}
