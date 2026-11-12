#!/usr/bin/env bash
# Does a checkout carry an assistant's radio hooks? (#304)
#
# This file is meant to be sourced, not executed.
#
# Each assistant reads its hooks from one file inside the directory it runs in —
# its *hook carrier*: claude from `.claude/settings.json`, kiro from the agent
# config it is launched with, `.kiro/agents/worker.json` for a worker. A worktree
# holds whatever was committed when it was forked, so a worktree cut before a
# loadout was installed (`task-config add assistant`, #293) has no carrier for
# that assistant. An agent started there runs fine and registers nothing: no
# SessionStart register, no Stop drain, no prompt-hook — radio is silently dead
# for the whole session, and nothing on screen says so.
#
# `task-config add` / `use` change only the main checkout, so this is the check
# every place that starts an agent somewhere other than a fresh fork of the base
# runs: task-recreate-worker on the surviving worktree, task-work on an explicit
# --from ref, and task-config's switch-time warning over the live worktrees.
#
# "Carries the hooks" means the file holds a `radio register` command, the hook
# that makes a role addressable at all. A grep rather than a jq walk: claude's
# settings and both of kiro's hooks shapes (#267) all hold it as a command
# string, and the test has to answer on a box without jq too. The two words are
# matched anywhere in that string, not only at its start, so a prefixed hook —
# `ENV=1 radio register`, `/usr/local/bin/radio register`, `command radio
# register` — still counts; `myradio register` does not.

# shellcheck source=lib/local-only.sh
. "$(dirname "${BASH_SOURCE[0]}")/local-only.sh"

# A local-only install (#327) puts claude's hooks in `.claude/settings.local.json`
# instead, untracked and copied into each worktree by the launcher. Claude Code
# reads that file beside settings.json, so a hook found there counts for any
# checkout; a worktree whose copy is missing still has neither, and is refused.

# aw_hook_carrier_rel <agent> [<role>]
# The carrier's path relative to the checkout root. On kiro the carrier is the
# role's own agent config (worker by default); claude's is one file for all.
aw_hook_carrier_rel() {
  case "$1" in
    claude) echo ".claude/settings.json" ;;
    kiro)   echo ".kiro/agents/${2:-worker}.json" ;;
    *)      return 1 ;;
  esac
}

# aw_role_file_rel <agent> <role>
# The file that makes the role's prompt exist (#393): claude's slash command,
# kiro's agent config. Without it claude takes `/worker …` as plain text and
# kiro falls back to a built-in agent.
aw_role_file_rel() {
  case "$1" in
    claude) echo ".claude/commands/$2.md" ;;
    kiro)   echo ".kiro/agents/$2.json" ;;
    *)      return 1 ;;
  esac
}

# aw_dir_has_role_file <agent> <dir> <role>
# kiro-cli also resolves an agent from the user's global dir (lib/kiro-agent.sh).
aw_dir_has_role_file() {
  local agent="$1" dir="$2" role="$3" rel
  rel=$(aw_role_file_rel "$agent" "$role") || return 1
  [[ -r "$dir/$rel" ]] && return 0
  [[ "$agent" == kiro && -r "$HOME/$rel" ]]
}

# Reads stdin. Captured rather than piped into `grep -q`: under `pipefail` the
# early exit SIGPIPEs the producer and the pipeline fails *because* it matched.
_aw_carries_radio_register() {
  local body
  body=$(cat)
  grep -Eq '(^|[^[:alnum:]_-])radio[[:space:]]+register([^[:alnum:]_-]|$)' <<<"$body"
}

# kiro-cli falls back to the user's global agent dir when the workspace has no
# `worker.json` (see lib/kiro-agent.sh), so a global carrier counts too.
_aw_global_hook_carrier() {
  local global="$HOME/.kiro/agents/${2:-worker}.json"
  [[ "$1" == kiro && -r "$global" ]] || return 1
  _aw_carries_radio_register < "$global"
}

# aw_dir_has_hook_carrier <agent> <dir> [<role>]
# True when an agent started in <dir> would run task-force's radio hooks.
aw_dir_has_hook_carrier() {
  local agent="$1" dir="$2" role="${3:-worker}" rel
  rel=$(aw_hook_carrier_rel "$agent" "$role") || return 1
  if [[ -r "$dir/$rel" ]] && _aw_carries_radio_register < "$dir/$rel"; then
    return 0
  fi
  if [[ "$agent" == claude && -r "$dir/.claude/settings.local.json" ]] \
     && _aw_carries_radio_register < "$dir/.claude/settings.local.json"; then
    return 0
  fi
  _aw_global_hook_carrier "$agent" "$role"
}

# aw_ref_has_hook_carrier <agent> <repo> <ref>
# The same question about a commit: would a worktree forked from <ref> carry
# the hooks? Asks git, so it answers before the worktree exists.
aw_ref_has_hook_carrier() {
  local agent="$1" repo="$2" ref="$3" rel body
  rel=$(aw_hook_carrier_rel "$agent") || return 1
  if body=$(git -C "$repo" show "$ref:$rel" 2>/dev/null) \
     && _aw_carries_radio_register <<<"$body"; then
    return 0
  fi
  _aw_global_hook_carrier "$agent"
}

# aw_stale_worktrees <main-worktree> <agent>
# One `<slug>\t<dir>\t<base>` line per live worker worktree that lacks <agent>'s
# carrier. Live means task-work's sidecar names it and the directory is there;
# reviewer worktrees are skipped, since nothing relaunches a reviewer in place.
aw_stale_worktrees() {
  local main="$1" agent="$2" base info slug dir branch
  base="$(cd "$main/.." && pwd -P)/$(basename "$main")-worktrees"
  [[ -d "$base" ]] || return 0
  for info in "$base"/.*.info; do
    [[ -f "$info" ]] || continue
    slug=$(basename "$info"); slug=${slug#.}; slug=${slug%.info}
    dir="$base/$slug"
    [[ -d "$dir" ]] || continue
    [[ "$slug" =~ ^review-pr[0-9]+$ ]] && continue
    aw_dir_has_hook_carrier "$agent" "$dir" && continue
    branch=$(awk 'index($0, "BASE_BRANCH=") == 1 { print substr($0, 13); exit }' "$info")
    printf '%s\t%s\t%s\n' "$slug" "$dir" "${branch:-main}"
  done
}

# aw_hook_carrier_remedy <agent> <dir> <base> <repo>
# The fix, printed to stdout with a 7-space indent for an `Error:` block: merge
# the base when it carries the hooks, else say the loadout is not committed yet
# — a merge brings only what is.
aw_hook_carrier_remedy() {
  local agent="$1" dir="$2" base="$3" repo="$4" rel
  rel=$(aw_hook_carrier_rel "$agent")
  # A local-only install commits nothing, so no merge can bring the hooks in:
  # the launcher copies them from the main checkout, which must have them.
  if tf_local_only "$repo"; then
    echo "       This is a local-only install (#327): the hooks live untracked in"
    echo "       $repo/.claude/settings.local.json and are copied into each worktree."
    echo "       If that file has no 'radio register' hook, restore it, then re-run:"
    echo "         (cd $repo && task-init <loadout> --local-only)"
    return 0
  fi
  if aw_ref_has_hook_carrier "$agent" "$repo" "$base"; then
    echo "       '$base' has it. Bring it in, then re-run:"
    echo "         git -C $dir merge $base      # or rebase onto $base"
  else
    echo "       '$base' does not have it either: commit $rel on $base first"
    echo "       (task-init / task-config add assistant $agent writes it), then:"
    echo "         git -C $dir merge $base"
  fi
}

# aw_launch_preflight <agent> <role> <dir> <base> <repo> <loadout> <what>
# The check every launcher runs after the worktree sync and before the agent
# starts (#393): the role's prompt file and a radio register hook. A miss on
# either starts an agent that looks, from outside, exactly like one still
# booting: no role prompt, or no register. So it is refused here, naming which
# file is missing and the fix, on stderr. <what> names the checkout in the
# message ("worktree 'issue-42'"); the caller prints its own retry line.
aw_launch_preflight() {
  local agent="$1" role="$2" dir="$3" base="$4" repo="$5" loadout="$6" what="$7"
  local rel ok=0
  if ! aw_dir_has_role_file "$agent" "$dir" "$role"; then
    ok=1
    rel=$(aw_role_file_rel "$agent" "$role")
    {
      echo "Error: $what has no $rel — refusing to launch $agent there."
      echo "       The $role would start with no role prompt."
      echo "       The main checkout has none to copy either ($repo/$rel)."
      echo "       Install the loadout there, then re-run:"
      echo "         (cd $repo && task-init $loadout)"
    } >&2
  fi
  if ! aw_dir_has_hook_carrier "$agent" "$dir" "$role"; then
    ok=1
    rel=$(aw_hook_carrier_rel "$agent" "$role")
    {
      echo "Error: $what has no $agent radio hooks — refusing to launch $agent there."
      echo "       $dir/$rel is missing, or carries no 'radio register' hook"
      echo "       (the launch copies a missing one from the main checkout, never over one"
      echo "       the worktree has): $agent would start, never register, and radio could"
      echo "       not reach it."
      aw_hook_carrier_remedy "$agent" "$dir" "$base" "$repo"
    } >&2
  fi
  return "$ok"
}
