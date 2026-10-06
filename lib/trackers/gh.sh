#!/usr/bin/env bash
# GitHub Projects tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed.
#
# Overrides nothing for task-done: the defaults in _default.sh *are* the gh
# behaviour, since four of the seven task-done copies were byte-identical and gh
# was one of them. task-work's hooks (#237) are where this module earns its
# keep — ref parsing, the issue-N slug, the GH_URL sidecar key.

aw_tracker_is_ref() {
  [[ "$1" == *"github.com"*"/issues/"* ]]
}

# issue-N from the issue number; a URL with no number after /issues/ falls back
# to its last path segment, sanitized.
aw_tracker_ref_slug() {
  local url="$1" issue_num
  issue_num=$(echo "$url" | sed 's|.*/issues/||' | sed 's|[^0-9].*||')
  if [[ -n "$issue_num" ]]; then
    echo "issue-${issue_num}"
  else
    echo "$url" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g'
  fi
}

aw_tracker_info_key() { echo GH_URL; }

aw_tracker_usage_synopsis() {
  echo "  task-work <slug> <gh-url> [options]    # explicit slug + GitHub issue URL (preferred when an agent kicks it off)"
  echo "  task-work <gh-url> [options]           # slug derived from issue number (issue-N)"
  echo "  task-work <free-form-slug> [options]   # ad-hoc, no GitHub URL"
}

aw_tracker_usage_examples() {
  echo '  task-work add-auth "https://github.com/owner/repo/issues/42"'
  echo "  task-work https://github.com/owner/repo/issues/42"
  echo "  task-work refactor-auth"
  echo "  task-work spike-idea --no-launch"
  echo '  task-work issue-42 "https://github.com/owner/repo/issues/42" --auto'
  echo "  # Stack a follow-up PR on top of an in-flight branch:"
  echo "  task-work issue-99 <url> --from task/issue-46 --base main --auto"
  echo "  # Spike off origin/main without checking it out:"
  echo "  task-work spike --from origin/main"
}
