#!/usr/bin/env bash
# shellcheck disable=SC2034  # hooks set globals (AW_*, flag state) that bin/task-work reads
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

# ---------------- task-work hooks ----------------
#
# Ref resolution is driven by two small predicates rather than restated per
# tracker: every tracker-backed loadout ran the SAME positional-resolution chain
# around a different "is this a ref?" test and a different "slug from a ref"
# rule. So a tracker overrides `aw_tracker_is_ref` / `aw_tracker_ref_slug`, and
# the chain below stays one copy. `local` is the one tracker that also overrides
# the chain itself (it takes one positional, and absolutizes the path).

# aw_tracker_is_ref <arg>
#
# True when <arg> is this tracker's task reference. The default recognises
# nothing, so every positional is a free-form slug.
aw_tracker_is_ref() { return 1; }

# aw_tracker_ref_slug <ref>
#
# The slug a bare ref derives when no explicit slug was given.
aw_tracker_ref_slug() { aw_sanitize_slug "$1"; }

# aw_sanitize_slug <text>
#
# Not a hook — the one slug sanitizer, shared by every tracker. It was
# byte-identical in all seven task-work copies (claude-jira inlined it).
aw_sanitize_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g'
}

# aw_tracker_parse_ref <positional>...
#
# Sets AW_TASK_REF (empty when there is none) and AW_SLUG (unsanitized-empty
# when nothing could be derived — the caller refuses on that, and truncates).
#   1 arg,  a ref           -> slug derived from the ref
#   1 arg,  not a ref       -> slug only, no ref
#   2 args, a ref in either -> the other one is the slug
#
# The body lives under a private name so a tracker that overrides the hook can
# still delegate to it (local does, for its one-argument case).
aw_tracker_parse_ref() { _aw_tracker_parse_ref_default "$@"; }

_aw_tracker_parse_ref_default() {
  local p0="$1" p1="${2:-}"
  AW_TASK_REF=""
  AW_SLUG=""
  if [[ $# -ge 2 ]] && ! aw_tracker_is_ref "$p0" && aw_tracker_is_ref "$p1"; then
    AW_SLUG=$(aw_sanitize_slug "$p0")
    AW_TASK_REF="$p1"
  elif [[ $# -ge 2 ]] && aw_tracker_is_ref "$p0" && ! aw_tracker_is_ref "$p1"; then
    AW_TASK_REF="$p0"
    AW_SLUG=$(aw_sanitize_slug "$p1")
  elif aw_tracker_is_ref "$p0"; then
    AW_TASK_REF="$p0"
    AW_SLUG=$(aw_tracker_ref_slug "$p0")
  else
    AW_SLUG=$(aw_sanitize_slug "$p0")
  fi
}

# aw_tracker_info_key
#
# The key task-work writes the ref under in the worktree's .info sidecar —
# GH_URL / JIRA_REF / NOTION_URL / TASK_FILE. Deliberately has no working
# default: every tracker names its own, and a module that forgot to must not
# quietly write a key nothing downstream reads. Refusing here fails task-work
# before anything is created.
aw_tracker_info_key() {
  echo "Error: tracker module defines no .info key (aw_tracker_info_key)" >&2
  return 1
}

# aw_tracker_worker_prompt <quoted-ref>
#
# The payload the worker is launched with. Receives the ref ALREADY `printf %q`
# quoted by the caller: the agent wraps the payload in double quotes for the
# `bash -ic` re-parse, so only the user-supplied part may be escaped — quoting
# the whole sentence would leave literal backslashes before every space.
aw_tracker_worker_prompt() { printf 'Implement task: %s' "$1"; }

# aw_tracker_usage_synopsis
#
# The `Usage:` lines of task-work's help. Printed.
aw_tracker_usage_synopsis() {
  echo "  task-work <slug> <ref> [options]       # explicit slug + task reference"
  echo "  task-work <ref> [options]              # slug derived from the reference"
  echo "  task-work <free-form-slug> [options]   # ad-hoc, no task reference"
}

# aw_tracker_usage_notes
#
# Extra description paragraph(s) after the shared one. Most trackers have none.
aw_tracker_usage_notes() { :; }

# aw_tracker_usage_examples
#
# Tracker-flavoured lines of the `Examples:` block. Printed.
aw_tracker_usage_examples() {
  echo "  task-work refactor-auth"
  echo "  task-work spike-idea --no-launch"
}

# aw_tracker_post_worktree <repo_root> <slug> <branch> <worktree_dir> <ref>
#
# Fires after the worktree and its .info sidecar exist, before the tab opens.
# Tracker-local bookkeeping — only `local` has any.
aw_tracker_post_worktree() { :; }
