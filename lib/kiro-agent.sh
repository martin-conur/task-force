#!/usr/bin/env bash
# Guard: the kiro agent a launcher is about to spawn must actually resolve.
#
# `kiro-cli chat --agent <name>` does not fail when <name> cannot be found. It
# prints an io error to stderr — one line, immediately scrolled past by the TUI
# it then starts — and falls back to a built-in default agent. That fallback
# carries none of task-force's `hooks`, so the role never registers and radio
# is silently dead for the whole session, presenting exactly as #218.
#
# The way this happens in practice is not a missing install but a stale one.
# Before 3e45ce3, install.sh symlinked `~/.kiro/agents/*.json` into the checkout
# that ran it; renaming or moving that checkout leaves dangling links behind, and
# `kiro-cli agent list` then errors once per link and lists none of them. That is
# the state this repo's own machine was in when #218 was diagnosed. Nothing has
# written `~/.kiro/agents/` since — agents are per-repo, from `task-init` — so
# re-running install.sh leaves such a link exactly as it was (#250). The fix is
# to remove the leftover and run `task-init <loadout>` in the repo.
#
# Checked by filesystem, not by invoking `kiro-cli agent list`: the two
# directories below are where kiro-cli looks, and a pure `-r` test cannot go
# stale against a CLI version bump or turn a slow/unauthenticated CLI into a
# spurious abort. `-r` rather than `-f` because a dangling symlink is the case
# this exists to catch — `-f` follows the link and is false for it, but so is
# `-r`, and `-r` additionally catches an unreadable file.
#
# `workdir` is the directory kiro-cli will actually run in (kiro-cli reads
# `<cwd>/.kiro/agents/`). Callers that check before creating a worktree pass the
# repo root instead; that is deliberately conservative — it can only pass a case
# that would previously have been silently broken, never fail a working one.
aw_require_kiro_agent() {
  local name="$1" workdir="${2:-$PWD}" hint="${3:-task-init}"
  local ws="$workdir/.kiro/agents/$name.json"
  local global="$HOME/.kiro/agents/$name.json"

  if [[ -r "$ws" || -r "$global" ]]; then
    return 0
  fi

  {
    echo "Error: kiro agent '$name' does not resolve; refusing to launch."
    echo "       Looked for:"
    printf '         %s\n' "$ws" "$global"
    local dangling=
    if [[ -L "$global" && ! -e "$global" ]]; then
      dangling=1
      echo "       $global is a DANGLING SYMLINK -> $(readlink "$global")"
      echo "       (a leftover from an older install; nothing recreates it, since agents"
      echo "       are per-repo now — it also makes 'kiro-cli agent list' error)"
    fi
    echo
    echo "       kiro-cli would not fail on this: it falls back to a hookless built-in"
    echo "       agent, so the role never registers and radio goes silently dead (#218)."
    echo
    if [[ -n "$dangling" ]]; then
      echo "       Fix: remove the leftover, then run '$hint' in this repo:"
      echo "         rm '$global'"
    else
      echo "       Fix: run '$hint' in this repo."
    fi
  } >&2
  return 1
}
