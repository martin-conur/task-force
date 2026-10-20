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

# ---------------- task-reviewer hooks ----------------
#
# The one tracker with a convention to fall back on: GitHub links a PR to its
# issue with `Closes #N`, so a reviewer dispatched with no 2nd argument still
# finds its spec. An explicit argument must be an issue number or an issue URL;
# a bare number is turned into a URL off the PR's own, so /reviewer always gets
# something it can open.
aw_tracker_review_spec() {
  local input="$1" pr_url="$2" pr_body="$3"
  AW_SPEC_ID=""
  AW_SPEC_REF=""
  if [[ -n "$input" ]]; then
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      AW_SPEC_ID="$input"
    elif [[ "$input" == *"github.com"*"/issues/"* ]]; then
      AW_SPEC_ID=$(echo "$input" | sed 's|.*/issues/||' | sed 's|[^0-9].*||')
      AW_SPEC_REF="$input"
    else
      return 1
    fi
  elif [[ -n "$pr_body" ]]; then
    AW_SPEC_ID=$(printf '%s\n' "$pr_body" \
      | grep -iEo '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
      | head -1 | grep -Eo '[0-9]+' || true)
  fi
  if [[ -n "$AW_SPEC_ID" && -z "$AW_SPEC_REF" && -n "$pr_url" ]]; then
    AW_SPEC_REF=$(printf '%s\n' "$pr_url" | sed "s|/pull/[0-9]*|/issues/$AW_SPEC_ID|")
  fi
}

aw_tracker_review_usage_spec() {
  cat <<'TXT'
  <issue-url-or-number>   Optional — the spec issue this PR claims to close: an
                          issue number or a GitHub issue URL. If omitted, it is
                          auto-detected from the PR body's Closes/Fixes/Resolves
                          #N. With neither, the reviewer proceeds with a
                          diff-only review.
TXT
}

aw_tracker_review_no_spec_warning() {
  echo "⚠ No spec issue associated with PR #$1 (no second arg, no Closes/Fixes in body)."
}

# ---------------- task-monitor-snapshot hooks ----------------
#
# gh is the one tracker the shell can read, so it describes items from the
# issue itself: its title, and the first paragraph of its body.

# <ref> is an issue URL (the .info sidecar's GH_URL) or a bare number (the PM
# queue's). `gh issue view` takes either, a number only from inside the repo.
aw_tracker_item_describe() {
  local ref="$1" root="$3" json desc
  [[ -n "$ref" ]] || return 1
  json=$(cd "$root" 2>/dev/null && gh issue view "$ref" --json number,title,body,url 2>/dev/null) || return 1
  [[ -n "$json" ]] || return 1
  desc=$(printf '%s' "$json" | jq -r '.body // ""' | tm_first_paragraph)
  printf '%s' "$json" | jq -c --arg ref "$ref" --arg d "$desc" '
    {ref: $ref, label: ("#" + (.number | tostring)), number: .number, title: .title,
     description: (if $d == "" then null else $d end), url: .url}'
}

# `Closes #N` (and its Fixes / Resolves kin, which GitHub honours alike) is how
# a gh PR names its issue, so it wins over the head branch. Same pattern as
# aw_tracker_review_spec above: the first such line is the one that counts.
aw_tracker_pr_item() {
  local head="$1" body="${2:-}" n
  n=$(printf '%s\n' "$body" \
    | grep -iEo '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | head -1 | grep -Eo '[0-9]+' || true)
  if [[ -z "$n" && "$head" =~ ^task/issue-([0-9]+)$ ]]; then
    n="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$n" ]]; then
    _aw_tracker_pr_item_default "$head"
    return
  fi
  jq -cn --argjson n "$n" \
    '{ref: ($n | tostring), label: ("#" + ($n | tostring)), number: $n, title: null, description: null, url: null}'
}

# Open project items in none of the three configured statuses (in progress / in
# review / done), in the order `gh project item-list` returns them. Read from the
# workflow doc rather than added as new settings (#272): the doc already names
# the project and all three statuses. Compared case-insensitively, since the
# template says `In Progress` and GitHub's own default column is `In progress`.
aw_tracker_next_fallback() {
  local root="$1" doc="$2" limit="${3:-10}" owner repo project statuses json item desc
  owner=$(tf_tracker_value "$doc" gh owner)
  repo=$(tf_tracker_value "$doc" gh repo)
  project=$(tf_tracker_value "$doc" gh project)
  [[ -n "$owner" && -n "$project" ]] || return 0
  # shellcheck disable=SC2016  # the backticks are literal markdown, not expansions
  statuses=$(sed -n -E 's/^- \*\*Status when (starting work|in review|done)\*\*: `([^`]*)`.*/\2/p' "$doc" 2>/dev/null \
    | jq -Rsc 'split("\n") | map(ascii_downcase | select(. != ""))')
  json=$(cd "$root" 2>/dev/null && gh project item-list "$project" --owner "$owner" --format json --limit 200 2>/dev/null) || return 1
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | jq -c --arg repo "${repo:+$owner/$repo}" --argjson skip "$statuses" --argjson limit "$limit" '
    [ .items[]
      | select(.content.type == "Issue")
      | select($repo == "" or .content.repository == $repo)
      | select(((.status // "") | ascii_downcase) as $s | ($skip | index($s)) | not)
    ][:$limit][]
    | .content
    | {ref: (.number | tostring), label: ("#" + (.number | tostring)), number: .number,
       title: .title, body: (.body // ""), url: .url}' \
  | while IFS= read -r item; do
      desc=$(printf '%s' "$item" | jq -r .body | tm_first_paragraph)
      printf '%s' "$item" | jq -c --arg d "$desc" \
        'del(.body) | .description = (if $d == "" then null else $d end)'
    done
}
