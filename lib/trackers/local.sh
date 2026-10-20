#!/usr/bin/env bash
# Local-markdown tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed. $AW_ROOT must be set by the
# caller before sourcing — this is the only module that pulls in another lib,
# and bin/task-done / bin/task-work set AW_ROOT for lib/detect-impl.sh before
# they get here.
#
# The only tracker whose task-done does real work of its own: the backlog lives
# in the repo, so a finished task has to be struck off two local artifacts no
# forge is going to update.

# shellcheck source=lib/board-regen.sh
source "$AW_ROOT/lib/board-regen.sh"
# shellcheck source=lib/task-file.sh
source "$AW_ROOT/lib/task-file.sh"

aw_tracker_usage_steps() {
  echo "  1. Show the diff summary and existing PR (or print gh pr create command)"
  echo "  2. Remove the slug entry from .git/task-force/state.json"
  echo "  3. Regenerate tasks/_board.md from the main worktree"
  echo "  4. Remove the worktree"
  echo "  5. Close the zellij tab"
}

# Drop this slug's line from the JSONL sidecar, then re-render the board.
#
# Both read the MAIN worktree: `tasks/` and `.git/task-force/` live there, and
# by the time this fires the task worktree has already been removed.
#
# `aw_regenerate_board` always returns 0 by contract (lib/board-regen.sh) — a
# board that failed to render is worth a warning, not worth aborting a cleanup
# whose worktree and tab are already gone (#223). The `|| true` at the call site
# is belt-and-braces over that, not a substitute for it.
aw_tracker_post_cleanup() {
  # $3 (the impl) is part of the hook interface (lib/trackers/_default.sh) but
  # unused here since #238: there is one task-board, whichever local loadout ran.
  local main_worktree="$1" slug="$2" state_file
  state_file="$main_worktree/.git/task-force/state.json"
  if [[ -f "$state_file" ]]; then
    awk -v slug="$slug" '
      $0 !~ ("\"slug\"[[:space:]]*:[[:space:]]*\"" slug "\"") { print }
    ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  fi
  # Pass the caller explicitly rather than letting aw_regenerate_board default
  # `self` to ${BASH_SOURCE[1]} (lib/board-regen.sh:30): from here that would be
  # THIS file, which has no task-board beside it, and the sibling fallback would
  # silently find nothing. The root task-done does — since #238 the one
  # task-board copy is bin/task-board — so $PATH first, then that.
  aw_regenerate_board "$main_worktree" "$AW_ROOT/bin/task-done"
}

# ---------------- task-work hooks ----------------

aw_tracker_is_ref() {
  [[ "$1" == *.md && -f "$1" ]]
}

# Slug = filename minus a leading NNN- and the .md.
aw_tracker_ref_slug() {
  local base slug
  base=$(basename "$1")
  slug="${base%.md}"
  slug="${slug#[0-9][0-9][0-9]-}"
  aw_sanitize_slug "$slug"
}

# One positional only: a task file, or a free-form slug. Unlike the URL
# trackers there is no `<slug> <file>` form — the file name IS the slug — so a
# second positional is ignored, as it always was. The shared chain is reused
# for the one-argument case rather than restated.
#
# The ref is made absolute without dereferencing symlinks, so the path stays
# consistent with $PWD (on macOS /var -> /private/var would otherwise change form
# depending on whether `cd -P` was used). The worker opens it from a different
# directory, so a relative path would point at nothing.
aw_tracker_parse_ref() {
  _aw_tracker_parse_ref_default "$1"
  if [[ -n "$AW_TASK_REF" && "$AW_TASK_REF" != /* ]]; then
    AW_TASK_REF="$PWD/$AW_TASK_REF"
  fi
}

aw_tracker_info_key() { echo TASK_FILE; }

aw_tracker_usage_synopsis() {
  echo "  task-work tasks/NNN-slug.md [options]   # preferred — local task tracking"
  echo "  task-work <free-form-slug> [options]    # ad-hoc, no task file"
}

aw_tracker_usage_notes() {
  echo ""
  echo "After creating the worktree, writes a sidecar entry to"
  echo "\`.git/task-force/state.json\` and regenerates \`tasks/_board.md\`."
}

aw_tracker_usage_examples() {
  echo "  task-work tasks/001-add-login-flow.md"
  echo "  task-work tasks/042-refactor-auth.md --base develop"
  echo "  task-work tasks/007-spike-idea.md --no-launch"
  echo "  # Stack a follow-up on top of an in-flight branch:"
  echo "  task-work tasks/099-followup.md --from task/042-refactor-auth --base main"
}

# Record the task in the JSONL sidecar (one line per slug), then re-render the
# board. Was 16 lines byte-identical between claude-local and kiro-local with no
# drift sentinel on it (#237).
aw_tracker_post_worktree() {
  local repo_root="$1" slug="$2" branch="$3" worktree_dir="$4" ref="$5"
  local state_dir="$repo_root/.git/task-force" state_file now
  state_file="$state_dir/state.json"
  mkdir -p "$state_dir"
  # Drop any existing entry for this slug (idempotent), then append the new one.
  if [[ -f "$state_file" ]]; then
    awk -v slug="$slug" '
      $0 !~ ("\"slug\"[[:space:]]*:[[:space:]]*\"" slug "\"") { print }
    ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"slug":"%s","branch":"%s","worktree":"%s","started_at":"%s","task_file":"%s"}\n' \
    "$(_aw_json_escape "$slug")" \
    "$(_aw_json_escape "$branch")" \
    "$(_aw_json_escape "$worktree_dir")" \
    "$now" \
    "$(_aw_json_escape "$ref")" \
    >> "$state_file"

  # A failure warns and names which copy of task-board ran instead of aborting
  # the run: the silent `|| true` this replaces is how a foreign ~/.local/bin
  # copy came to fail on every local-loadout machine with no symptom but a
  # missing artifact (#223). The caller is passed explicitly — see
  # aw_tracker_post_cleanup above for why the default would resolve wrongly.
  aw_regenerate_board "$repo_root" "$AW_ROOT/bin/task-work"
}

# JSON-escape a string (backslash and double-quote only — paths/slugs never
# contain control chars in practice).
_aw_json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ---------------- task-reviewer hooks ----------------
#
# Only the noun differs from the default: the spec still passes to /reviewer
# verbatim, with no PR-body convention to fall back on (#144, #239).
aw_tracker_review_spec_shape() { echo "a local task slug or filename"; }

# ---------------- task-monitor-snapshot hooks ----------------
#
# The backlog is files in the repo, so these never touch the forge and work the
# same in the snapshot's --local mode as in a full one.

# The task file a ref names. The .info sidecar records an absolute path into the
# main checkout; the PM queue may hold a filename or a bare slug instead. Prints
# nothing when no file matches.
_aw_local_task_file() {
  local ref="$1" slug="$2" root="$3" f
  for f in "$ref" "$root/tasks/$ref" "$root/tasks/$ref.md" "$root/tasks/$(basename "$ref")"; do
    [[ -n "$f" && "$f" != */ && -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  for f in "$root"/tasks/[0-9][0-9][0-9]-"${slug:-$ref}".md; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# Item object for one task file: frontmatter title and id, and the first prose
# paragraph of the body. The ref is the file path, as task-work records it.
_aw_local_task_item() {
  local f="$1" ref="${2:-$1}" id title slug desc
  id=$(aw_task_fm "$f" id)
  title=$(aw_task_fm "$f" title)
  slug=$(aw_tracker_ref_slug "$f")
  desc=$(tm_strip_frontmatter < "$f" | tm_first_paragraph)
  jq -cn --arg ref "$ref" --arg id "$id" --arg title "${title:-$slug}" --arg d "$desc" --arg url "$f" '
    {ref: $ref, label: (if $id == "" then null else $id end),
     number: ($id | if test("^[0-9]+$") then tonumber else null end),
     title: $title, description: (if $d == "" then null else $d end), url: $url}'
}

aw_tracker_item_describe() {
  local f
  f=$(_aw_local_task_file "$1" "${2:-}" "$3")
  if [[ -z "$f" ]]; then
    _aw_tracker_item_describe_default "$@"
    return
  fi
  _aw_local_task_item "$f" "$1"
}

# The tasks/ backlog in its own order — numeric id, as task-board's Todo column
# sorts it — skipping anything whose frontmatter says in-progress or done.
aw_tracker_next_fallback() {
  local root="$1" limit="${3:-10}" tf base status id
  [[ -d "$root/tasks" ]] || return 0
  for tf in "$root"/tasks/*.md; do
    [[ -f "$tf" ]] || continue
    base=$(basename "$tf")
    [[ "$base" == "_board.md" || "$base" == "README.md" ]] && continue
    status=$(aw_task_fm "$tf" status)
    case "$status" in in-progress|in_progress|"in progress"|done) continue ;; esac
    id=$(aw_task_fm "$tf" id)
    [[ "$id" =~ ^[0-9]+$ ]] || id=9999
    printf '%s\t%s\n' "$id" "$tf"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2 | head -n "$limit" | while IFS="$(printf '\t')" read -r id tf; do
    _aw_local_task_item "$tf"
  done
}
