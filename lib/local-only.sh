#!/usr/bin/env bash
# Local-only installs (#327): task-force in a repo without a single tracked change.
#
# This file is meant to be sourced, not executed.
#
# A normal install commits files to the repo: the `.claude/settings.json` hook
# merge, `.claude/commands/*.md`, the workflow doc and the `@.claude/<t>-workflow.md`
# import in `CLAUDE.md`. In a repo owned by another team none of that may reach
# the default branch, and a worker's PR must not carry it. A dedicated PM branch
# does not work: `task-work` forks workers from HEAD, so every worker branch
# would carry the files into its PR; and forking them from `main` instead leaves
# them without radio hooks, which #304's guard refuses.
#
# So a local-only install writes the same artifacts *untracked*:
#
#   - hooks + permissions go to `.claude/settings.local.json`, the import line to
#     `CLAUDE.local.md` — the two files Claude Code reads beside the shared ones
#     precisely so a checkout can carry settings nobody else sees;
#   - every path task-init writes is listed in `.git/info/exclude`, inside a
#     block this file owns. That file lives in git's common dir, so one block
#     covers the main checkout and every linked worktree, and it is never
#     committed — unlike a `.gitignore` entry, which would itself be a tracked
#     change;
#   - the mode is recorded in `git config task-force.install local-only`, which
#     linked worktrees share too. Every later task-init reads it, so a re-run or a
#     `task-config set` cannot drift back to writing tracked files.
#
# Untracked files do not follow `git worktree add`, so the launchers
# (task-work, task-reviewer, task-recreate-worker) call tf_local_only_sync to
# copy the set from the main checkout into the worktree before the agent starts.
#
# kiro is refused: its hooks live in `.kiro/agents/<role>.json`, which has no
# local counterpart the way settings.json has settings.local.json, so a repo
# tracking its own agent configs would get our hooks merged into a tracked file.
#
# Exports:
#   TF_INSTALL_KEY                       the git config key recording the mode
#   tf_local_only <repo>                 true when the repo is a local-only install
#   tf_local_only_patterns <loadout>     the exclude patterns that loadout writes
#   tf_local_only_tracked <repo> <pat>.. print the patterns that git tracks a file under
#   tf_local_only_record <repo> <pat>..  write the exclude block + the git config
#   tf_local_only_sync <repo> <worktree> copy the set into a worktree (missing files only)
#   tf_local_only_refuse_kiro <repo> <requested>  the kiro installers' refusal
#   tf_local_only_plan|remove <repo>     what task-remove does to the block + config

TF_INSTALL_KEY="task-force.install"
TF_EXCLUDE_START="# task-force:local-only:start — written by task-init --local-only; task-remove takes it out"
TF_EXCLUDE_END="# task-force:local-only:end"

# tf_local_only <repo>
# `|| true` inside the substitution is load-bearing: task-reviewer runs under
# `set -E`, which hands its ERR trap to command substitutions, so an unset key's
# exit 1 would run the trap's partial-launch cleanup in the subshell and delete
# the worktree it had just created.
tf_local_only() {
  [[ "$(git -C "$1" config --get "$TF_INSTALL_KEY" 2>/dev/null || true)" == local-only ]]
}

# The repo's main checkout, from any of its worktrees: the one place task-init
# wrote the local-only set, so the one place a worktree can copy it from.
_tf_main_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk 'NR == 1 { sub(/^worktree /, ""); print; exit }'
}

# Absolute path of the exclude file every worktree of the repo reads.
_tf_exclude_file() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  [[ "$common" == /* ]] || common="$1/$common"
  printf '%s/info/exclude' "$common"
}

# tf_local_only_patterns <loadout>
# One anchored pattern per line. A trailing `/` marks a directory.
tf_local_only_patterns() {
  local tracker="${1##*-}" role
  printf '%s\n' /CLAUDE.local.md /.claude/settings.local.json "/.claude/$tracker-workflow.md"
  for role in pm planner worker reviewer; do
    printf '/.claude/commands/%s.md\n' "$role"
  done
  # The *-local backlog is task-force content as much as the scaffolding is, and
  # it lives only in the main checkout (lib/trackers/local.sh reads it there).
  if [[ "$tracker" == local ]]; then printf '/tasks/\n'; fi
  return 0
}

# tf_local_only_tracked <repo> <pattern>...
# The patterns git already tracks a file under. Excluding a tracked file does
# nothing, so writing one would be exactly the tracked change this mode exists
# to avoid.
tf_local_only_tracked() {
  local repo="$1" pat rel; shift
  for pat in "$@"; do
    rel=${pat#/}
    if [[ -n "$(git -C "$repo" ls-files -- "$rel" 2>/dev/null)" ]]; then
      printf '%s\n' "$rel"
    fi
  done
  return 0
}

# The exclude file without our block.
_tf_exclude_without_block() {
  awk -v s="$TF_EXCLUDE_START" -v e="$TF_EXCLUDE_END" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$1"
}

_tf_exclude_has_block() {
  [[ -f "$1" ]] && grep -qxF -- "$TF_EXCLUDE_START" "$1"
}

# tf_local_only_record <repo> <pattern>...
# Replace the block with <pattern>s and record the mode. Replaced rather than
# appended to: only one claude loadout can be installed, so after a
# `task-config set` the block names the new loadout's files, not both.
tf_local_only_record() {
  local repo="$1" f rest; shift
  f=$(_tf_exclude_file "$repo") || { echo "Error: cannot find $repo's git dir" >&2; return 1; }
  mkdir -p "$(dirname "$f")"
  rest=""
  if [[ -f "$f" ]]; then rest=$(_tf_exclude_without_block "$f"); fi
  {
    if [[ -n "$rest" ]]; then printf '%s\n' "$rest"; fi
    printf '%s\n' "$TF_EXCLUDE_START"
    printf '%s\n' "$@"
    printf '%s\n' "$TF_EXCLUDE_END"
  } >"$f.tmp.$$"
  mv -f "$f.tmp.$$" "$f"
  git -C "$repo" config "$TF_INSTALL_KEY" local-only
  echo "✓ Local-only install: $# path(s) listed in ${f#"$repo"/} (git config $TF_INSTALL_KEY=local-only)"
}

# The block's file patterns (directories skipped), leading `/` stripped.
_tf_exclude_files() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk -v s="$TF_EXCLUDE_START" -v e="$TF_EXCLUDE_END" '
    $0 == s { on = 1; next }
    $0 == e { on = 0; next }
    on && $0 !~ /\/$/ { sub(/^\//, ""); print }
  ' "$f"
}

# tf_local_only_sync <repo> <worktree>
# Copy the local-only set from the main checkout into <worktree>. A no-op on a
# normal install. Only missing files are copied: a recovered worktree's
# settings.local.json may already hold permissions approved during the session,
# and those are the user's.
tf_local_only_sync() {
  local repo="$1" wt="$2" main f rel n=0
  tf_local_only "$repo" || return 0
  main=$(_tf_main_worktree "$repo")
  [[ -n "$main" && -d "$main" ]] || return 0
  f=$(_tf_exclude_file "$repo") || return 0
  [[ "$(cd "$main" && pwd -P)" != "$(cd "$wt" && pwd -P)" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "$rel" && -f "$main/$rel" && ! -e "$wt/$rel" ]] || continue
    mkdir -p "$(dirname "$wt/$rel")"
    cp -p "$main/$rel" "$wt/$rel"
    n=$((n + 1))
  done < <(_tf_exclude_files "$f")
  if ((n > 0)); then
    echo "Local-only install: copied $n untracked task-force file(s) from $main"
  fi
  return 0
}

# tf_local_only_refuse_kiro <repo> <requested:true|false>
# Fails, with the reason on stderr, when a kiro install would land in a
# local-only repo or was asked for --local-only.
tf_local_only_refuse_kiro() {
  local repo="$1" requested="$2" why
  if [[ "$requested" == true ]]; then why="--local-only was passed"
  elif tf_local_only "$repo"; then why="this repo is a local-only install (git config $TF_INSTALL_KEY)"
  else return 0
  fi
  {
    echo "Error: kiro cannot be installed local-only — $why."
    echo "       kiro reads its radio hooks from .kiro/agents/<role>.json, which has no"
    echo "       untracked counterpart the way .claude/settings.json has settings.local.json,"
    echo "       so the install could not keep every file out of the repo's branches."
    echo "       Use a claude loadout: task-init claude-<tracker> --local-only"
  } >&2
  return 1
}

# tf_local_only_plan <repo> / tf_local_only_remove <repo>
# Take the exclude block and the git config back out. Repo-wide rather than per
# loadout, like the ci-guard hook, so task-remove calls it once after the walk.
tf_local_only_plan()   { _tf_local_only_strip "$1" plan; }
tf_local_only_remove() { _tf_local_only_strip "$1" apply; }

_tf_local_only_strip() {
  local repo="$1" mode="$2" f rest verb
  if [[ "$mode" == plan ]]; then verb="would remove"; else verb="removed"; fi
  f=$(_tf_exclude_file "$repo") || return 0
  if _tf_exclude_has_block "$f"; then
    if [[ "$mode" == apply ]]; then
      rest=$(_tf_exclude_without_block "$f")
      if [[ -n "$rest" ]]; then printf '%s\n' "$rest" >"$f"; else : >"$f"; fi
    fi
    printf '  %s the task-force block from %s (your own entries stay)\n' "$verb" "${f#"$repo"/}"
  fi
  if [[ -n "$(git -C "$repo" config --get "$TF_INSTALL_KEY" 2>/dev/null || true)" ]]; then
    if [[ "$mode" == apply ]]; then git -C "$repo" config --unset "$TF_INSTALL_KEY" || true; fi
    printf '  %s git config %s\n' "$verb" "$TF_INSTALL_KEY"
  fi
  return 0
}
