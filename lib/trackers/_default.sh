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

# ---------------- task-reviewer hooks ----------------
#
# task-reviewer's second positional is "the spec this PR claims to close", which
# is not task-work's ref: a gh reviewer takes a bare issue number, and a local
# one takes a slug for a file that need not exist in the PR's checkout. So these
# are their own hooks rather than aw_tracker_is_ref reused (#239).
#
# The defaults are the opaque pass-through jira / notion / local all had (#144):
# whatever was typed reaches /reviewer verbatim, and there is no PR-body
# convention to fall back on.

# aw_tracker_review_spec <input> <pr_url> <pr_body>
#
# Sets AW_SPEC_ID (written to the reviewer's .info as ISSUE_NUMBER, empty when
# there is no spec) and AW_SPEC_REF (what /reviewer receives as its 2nd
# argument, empty for none). Non-zero only when a non-empty <input> is not a
# spec this tracker can name; the caller refuses on that.
aw_tracker_review_spec() {
  AW_SPEC_ID="$1"
  AW_SPEC_REF="$1"
}

# aw_tracker_review_spec_shape
#
# The noun phrase the default usage block names the spec by.
aw_tracker_review_spec_shape() { echo "this tracker's own task identifier"; }

# aw_tracker_review_usage_spec
#
# The <spec> paragraph of task-reviewer's usage. Printed.
aw_tracker_review_usage_spec() {
  cat <<TXT
  <spec-identifier>       Optional — the spec this PR claims to close:
                          $(aw_tracker_review_spec_shape),
                          passed to /reviewer as-is. PR-body auto-detect is
                          GitHub-only, so pass it explicitly. With no spec id,
                          the reviewer proceeds with a diff-only review.
TXT
}

# aw_tracker_review_no_spec_warning <pr_number>
#
# Why there is no spec. Printed to stdout; the caller sends it to stderr and
# adds the shared "diff-only review" line.
aw_tracker_review_no_spec_warning() {
  echo "⚠ No spec identifier passed for PR #$1."
  echo "  PR-body auto-detect is GitHub-only — pass the spec id (Jira key, Notion URL,"
  echo "  local task slug) as the 2nd positional arg to enable spec-compliance review."
}

# ---------------- task-monitor-snapshot hooks ----------------
#
# What the monitor shows for an item comes from the tracker, deterministically:
# no model writes it (#272). These hooks print JSON for bin/task-monitor-snapshot
# to assemble, and need jq plus lib/monitor-text.sh, which that binary sources
# before any module.
#
# Every item object has one shape, so the snapshot never asks which tracker made
# it: {ref, label, number, title, description, url}. `ref` is what the tracker
# names the item by, `label` is what a human reads in a list (`#267`,
# `PROJ-42`), and any field the tracker cannot know is null.
#
# A hook that reaches the forge returns NON-ZERO when the forge does not answer,
# rather than printing nothing. That is the snapshot's only way to tell "nothing
# to show" from "could not ask", and the second is what makes it fall back to the
# last forge result instead of blanking the item. Its --local mode depends on it:
# it shadows `gh` with a function that fails, so every forge-backed hook takes
# that path.

# aw_tracker_item_describe <ref> <slug> <repo_root>
#
# One item object for an in-flight or queued item, before any PR exists. The
# default is the jira / notion row of the epic's table: the shell has no read
# access to those trackers (they are agent-only MCP) and task-force adds no API
# credentials, so the title is the ref and the worker slug, `PROJ-42 ·
# kiro-universal-config`. A ref that is a URL is too long to be a label, so it
# becomes the url and the slug stands alone.
aw_tracker_item_describe() { _aw_tracker_item_describe_default "$@"; }

_aw_tracker_item_describe_default() {
  local ref="$1" slug="${2:-}" label="" url="" title
  case "$ref" in
    *://*) url="$ref" ;;
    *)     label="$ref" ;;
  esac
  if [[ -n "$label" && -n "$slug" ]]; then
    title="$label · $slug"
  elif [[ -n "$slug" ]]; then
    title="$slug"
  else
    title="$label"
  fi
  jq -cn --arg ref "$ref" --arg label "$label" --arg title "$title" --arg url "$url" \
    '{ref: $ref, label: (if $label == "" then null else $label end), number: null,
      title: $title, description: null, url: (if $url == "" then null else $url end)}'
}

# aw_tracker_pr_item <head_ref> <pr_body>
#
# Which item a pull request delivers, as an item object without title or
# description (the PR supplies those). Returns 1 for a PR that delivers none.
# The default links through the `task/<slug>` head branch task-work creates,
# which is the only link a non-gh tracker has: its refs never appear in a PR
# body in any shape the shell could parse.
aw_tracker_pr_item() { _aw_tracker_pr_item_default "$@"; }

_aw_tracker_pr_item_default() {
  local head="$1" slug
  [[ "$head" == task/* ]] || return 1
  slug="${head#task/}"
  [[ -n "$slug" ]] || return 1
  jq -cn --arg slug "$slug" \
    '{ref: $slug, label: $slug, number: null, title: null, description: null, url: null}'
}

# aw_tracker_next_fallback <repo_root> <workflow_doc> <limit>
#
# The "Next" section when the PM's queue is empty: item objects, one per line,
# in the tracker's own order. In-flight items are NOT excluded here; the caller
# does that, so print a few more than <limit>. The default has no backlog it can
# read (jira / notion), so it prints nothing and succeeds — "the section says it
# is empty" is the decided behaviour there, not a failure to fall back from.
aw_tracker_next_fallback() { :; }
