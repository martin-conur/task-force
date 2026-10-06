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

# ---------------- task-work hooks ----------------
#
# A ref is a Jira browse URL or a bare key. Both derive the lowercased key as
# the slug; the ref passed to the worker is whatever was typed, URL or key.
#
# Before #237 claude-jira/bin/task-work had its own resolution order and took
# only one positional. It now runs the shared chain in _default.sh, which is
# what gives it the `<slug> <ref>` form the other trackers already had.
aw_tracker_is_ref() {
  [[ "$1" =~ atlassian\.net/browse/[A-Z][A-Z0-9_]+-[0-9]+ ]] \
    || [[ "$1" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]
}

aw_tracker_ref_slug() {
  local key
  if [[ "$1" =~ atlassian\.net/browse/([A-Z][A-Z0-9_]+-[0-9]+) ]]; then
    key="${BASH_REMATCH[1]}"
  else
    key="$1"
  fi
  echo "$key" | tr '[:upper:]' '[:lower:]'
}

aw_tracker_info_key() { echo JIRA_REF; }

aw_tracker_worker_prompt() { printf 'Implement Jira issue: %s' "$1"; }

aw_tracker_usage_synopsis() {
  echo "  task-work <slug> <jira-key-or-url> [options]   # explicit slug + Jira issue"
  echo "  task-work <jira-key-or-url> [options]          # slug derived from the key (proj-123)"
  echo "  task-work <free-form-slug> [options]           # ad-hoc, no Jira issue"
}

aw_tracker_usage_examples() {
  echo "  task-work PROJ-123"
  echo "  task-work https://your.atlassian.net/browse/PROJ-123"
  echo "  task-work add-store-filtering"
  echo "  task-work --base develop PROJ-456"
  echo "  task-work spike-idea --no-launch"
  echo "  # Stack a follow-up on top of an in-flight branch:"
  echo "  task-work PROJ-789 --from task/proj-456 --base main"
}
