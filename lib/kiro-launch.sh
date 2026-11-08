#!/usr/bin/env bash
# kiro-cli startup gates that hold a dispatched agent's first turn (#157, #257).
# Sourced by lib/agents/kiro.sh, bin/task-pm and bin/task-reviewer.
#
# A dispatched kiro agent gets its first turn as the positional [INPUT] of
# `kiro-cli chat` — "The first question to ask" in kiro-cli's own help, and
# verified to run on 2.29.1 in a pty and in a zellij tab, hooks attached. What
# holds it is anything kiro-cli puts up *before* that turn: a prompt nobody
# answers, because nobody types in a dispatched tab. Three are within reach here:
#
#   - the classic UI's "Classic is being deprecated" dialog, observed holding
#     the first turn until dismissed. The terminal UI is kiro-cli's default,
#     but `chat.ui = legacy` selects the classic one. aw_kiro_ui_flag pins
#     `--tui`, which was verified to override that setting.
#   - the trust-all-tools confirmation, which kiro-cli documents
#     `chat.disableTrustAllConfirmation` as skipping "on startup". Documented,
#     not observed here. Skipping a safety confirmation is the user's call,
#     never ours: aw_kiro_warn_trust_gate says so instead.
#   - the V3 engine's "Upgrade your agent configs to run on V3?" dialog (#257),
#     observed holding the first turn on 2.32.0 with `--tui` pinned. It is
#     `chat.enableAutoAgentUpgrade`: unset prompts, true rewrites configs
#     silently, false never asks. kiro-cli has no flag or env var that sets it
#     per launch, so aw_kiro_warn_upgrade_gate warns instead.
#
# All three ask kiro-cli itself rather than reading its files (unlike
# aw_require_kiro_agent): the flag set and the settings scope rules are
# kiro-cli's to define. None can abort a launch — a slow or broken CLI
# degrades to the old launch line, or to no warning.
#
# Not a gate but in the same family, aw_kiro_warn_hooks_shape (#370) flags an
# agent config whose hooks V3 will lose. It reads the config's `hooks` shape
# off the file, because that shape is task-init's to write; the engine and
# the setting it still asks kiro-cli for.

# The model every task-force kiro launch except the reviewer's passes as
# --model (#259): task-work's worker, task-pm's PM, task-recreate-worker's
# rebuilt worker. kiro-cli spells models with dots (claude-opus-5.5), Claude Code
# with hyphens (claude-opus-5-5); this is the kiro spelling. The reviewer runs on
# the cheaper AW_KIRO_REVIEWER_MODEL below.
#
# On the launch line, not in the agent JSONs, and that placement decides who
# wins. Measured on kiro-cli 2.32.0 from the model_id each session records: a
# `--model` flag beats the agent config's `model` field, which beats the user's
# `chat.defaultModel` setting. So with no --model here, a launch ran on whatever
# chat.defaultModel said; with it, the flag wins over both. The override is
# TASK_WORK_MODEL, or task-work's -m.
# shellcheck disable=SC2034  # read by the scripts that source this file
AW_KIRO_DEFAULT_MODEL=claude-opus-5.5

# The kiro reviewer's default --model (#259). Also overridden by
# TASK_WORK_MODEL, which the reviewer has always read: a worker override set in
# the shell turns reviewers into that model too.
# shellcheck disable=SC2034  # read by bin/task-reviewer
AW_KIRO_REVIEWER_MODEL=claude-sonnet-5.5

# aw_kiro_ui_flag
#
# Prints ` --tui` (leading space, for appending to a command string) when the
# installed kiro-cli accepts it, and nothing otherwise: an older kiro-cli would
# refuse an unknown flag, which would turn every launch into a dead tab.
# Captured, not piped into `grep -q`: grep exits on its match, kiro-cli takes
# SIGPIPE writing the rest, and under the callers' pipefail the pipeline fails.
aw_kiro_ui_flag() {
  _aw_kiro_chat_flag --tui
}

# aw_kiro_trust_workspace_flag
#
# Prints ` --trust-workspace` when the installed kiro-cli advertises it, and
# nothing otherwise or under TASK_WORK_NO_TRUST_WORKSPACE=1 (#378). The V3
# engine stores trust per folder and asks "Trust this workspace?" in one it has
# never seen, which is every worktree task-work creates; nobody types in a
# dispatched tab, so the worker would wait there for good. The flag skips that
# prompt for one launch and saves nothing.
#
# Unlike the trust-all confirmation above, this is ours to skip. task-force made
# the folder, from the user's own repo, and what the prompt guards (the
# folder's hooks, agents and MCP servers) is that repo's committed config with
# task-force's radio hooks in it.
# TASK_WORK_NO_TRUST_WORKSPACE=1 puts the prompt back for a user who wants it.
#
# Gated on --help alone, not on aw_kiro_engine: kiro-cli 3.1.0 takes the flag on
# the v2 engine and ignores it (probed: a `--v2 --no-interactive` run with it
# answered as one without, exit 0), and parses it with `--agent-engine v1`. A
# kiro-cli older than the flag gets nothing.
aw_kiro_trust_workspace_flag() {
  [[ "${TASK_WORK_NO_TRUST_WORKSPACE:-}" == 1 ]] && return 0
  _aw_kiro_chat_flag --trust-workspace
}

# aw_kiro_supervise_prefix
#
# Prints the launch-line prefix that runs kiro under bin/agent-supervise
# (#388): `<path> ` with a trailing space, %q-quoted for the tab's `bash -ic`.
# A tab close does not reach kiro's backend, which runs in a session of its
# own; the supervisor outlives the agent and stops what it left in the
# worktree. Worker and reviewer launches only: the PM runs in the main
# checkout, which is no one tab's to reap, and execs kiro in place.
aw_kiro_supervise_prefix() {
  printf '%q ' "$AW_ROOT/bin/agent-supervise"
}

# _aw_kiro_chat_flag <flag>
#
# Prints " <flag>" when `kiro-cli chat --help` lists it, and nothing otherwise.
# Captured, not piped into `grep -q`, for the reason given above.
_aw_kiro_chat_flag() {
  local help flag="$1"
  help=$(kiro-cli chat --help 2>/dev/null) || return 0
  [[ "$help" =~ (^|[[:space:],])"$flag"([[:space:],]|$) ]] && printf ' %s' "$flag"
  return 0
}

# aw_kiro_warn_trust_gate <workdir> <what>
#
# Warn on stderr that <what> will stall on kiro-cli's trust-all confirmation
# unless chat.disableTrustAllConfirmation is true. Read with kiro-cli from
# <workdir>, so a workspace-scoped setting counts. Always returns 0.
aw_kiro_warn_trust_gate() {
  local workdir="${1:-$PWD}" what="${2:-the agent}" v
  v=$(cd "$workdir" 2>/dev/null && kiro-cli settings -f json chat.disableTrustAllConfirmation 2>/dev/null) || v=""
  [[ "$v" == true ]] && return 0
  {
    echo "Warning: --trust-all-tools is on and kiro-cli's trust-all confirmation is not"
    echo "         disabled, so $what will stop at that confirmation before its first"
    echo "         turn, and nobody types in a dispatched tab (#157). Answer it in the tab,"
    echo "         or skip it for good:"
    echo "           kiro-cli settings chat.disableTrustAllConfirmation true"
  } >&2
  return 0
}

# aw_kiro_engine <workdir>
#
# Prints the agent engine (v1, v2, v3) a launch from <workdir> runs on when
# the launch line names none, which none of ours does: the `chat.agentEngine`
# setting, else the default `kiro-cli chat --help` advertises ("v2" (default) on
# 2.32.0). Prints nothing when neither says, as on a kiro-cli with one engine.
# An unset setting reads as `null` on 2.32.0 and as a non-zero exit on 2.29.1.
aw_kiro_engine() {
  local workdir="${1:-$PWD}" v help
  v=$(cd "$workdir" 2>/dev/null && kiro-cli settings -f json chat.agentEngine 2>/dev/null) || v=""
  v=${v//\"/}
  if [[ -z "$v" || "$v" == null ]]; then
    v=""
    help=$(kiro-cli chat --help 2>/dev/null) || help=""
    [[ "$help" =~ \"(v[0-9]+)\"\ \(default\) ]] && v=${BASH_REMATCH[1]}
  fi
  printf '%s' "$v"
  return 0
}

# aw_kiro_warn_upgrade_gate <workdir> <what>
#
# Warn on stderr that <what> will stall on the V3 engine's agent-config upgrade
# dialog (#257) when it runs on V3 and chat.enableAutoAgentUpgrade is unset —
# either value of the setting skips the dialog. Read with kiro-cli from
# <workdir>, so workspace-scoped settings count. Always returns 0.
#
# The fix it names is `true`, which skips the dialog by rewriting
# .kiro/agents/*.json in place into kiro-cli's "universal" format, whose
# `hooks` is an array. task-init's hook merge and task-remove's strip handle
# that shape since #267. It used to name `false`, under which the configs stay
# as task-init wrote them: V3 loaded those with radio hooks firing on 2.32.0,
# but on 3.1.0 it loads none of their hooks, so a worker never registers
# (#370). What `true` leaves behind is aw_kiro_warn_hooks_shape's concern.
aw_kiro_warn_upgrade_gate() {
  local workdir="${1:-$PWD}" what="${2:-the agent}" v
  [[ "$(aw_kiro_engine "$workdir")" == v3 ]] || return 0
  v=$(cd "$workdir" 2>/dev/null && kiro-cli settings -f json chat.enableAutoAgentUpgrade 2>/dev/null) || v=""
  [[ "$v" == true || "$v" == false ]] && return 0
  {
    echo "Warning: kiro-cli runs $what on its V3 engine and chat.enableAutoAgentUpgrade is"
    echo "         unset, so $what will stop at kiro's \"upgrade your agent configs\""
    echo "         dialog before its first turn, and nobody types in a dispatched tab"
    echo "         (#257). Answer it in the tab, or skip it for good:"
    echo "           kiro-cli settings chat.enableAutoAgentUpgrade true"
  } >&2
  return 0
}

# aw_kiro_warn_hooks_shape <workdir> <agent> <what>
#
# Warn on stderr when <what> will run on the V3 engine from an agent config
# whose `hooks` is still the object task-init writes, not kiro-cli's universal
# array (#370). <workdir>/.kiro/agents/<agent>.json is read, else the global
# ~/.kiro/agents one, as aw_require_kiro_agent resolves it. Always returns 0.
#
# Probed on kiro-cli 3.1.0 in a scratch HOME, two turns per run:
#   - chat.enableAutoAgentUpgrade false: the object-shaped file is loaded as
#     is and not one of its hooks fires, agentSpawn included.
#   - true (or the dialog answered): the file is rewritten to universal at
#     launch and every hook fires, but the committed copy is still the object
#     shape. When anything puts that copy back while the agent runs (a `git
#     stash`, `checkout`, `reset --hard`, a branch switch or merge), V3
#     hot-reloads the agent from it and drops every hook for the rest of the
#     session, even once the universal file is back. Nothing refreshes the
#     heartbeat, and radio calls the role dead. A reload of a universal file,
#     edited or not, keeps them.
# A committed universal config has neither problem. Shipping one from
# task-init is #350; until then the fix is to upgrade and commit it by hand.
aw_kiro_warn_hooks_shape() {
  local workdir="${1:-$PWD}" agent="${2:-worker}" what="${3:-the agent}" cfg v
  command -v jq >/dev/null 2>&1 || return 0
  cfg="$workdir/.kiro/agents/$agent.json"
  [[ -r "$cfg" ]] || cfg="$HOME/.kiro/agents/$agent.json"
  [[ -r "$cfg" ]] || return 0
  [[ "$(jq -r '.hooks | type' "$cfg" 2>/dev/null)" == object ]] || return 0
  [[ "$(aw_kiro_engine "$workdir")" == v3 ]] || return 0
  v=$(cd "$workdir" 2>/dev/null && kiro-cli settings -f json chat.enableAutoAgentUpgrade 2>/dev/null) || v=""
  {
    if [[ "$v" == false ]]; then
      echo "Warning: $cfg still has task-init's object-shaped \`hooks\`, and"
      echo "         chat.enableAutoAgentUpgrade is false, so kiro-cli's V3 engine loads it"
      echo "         as is and fires none of its hooks (kiro-cli 3.1.0): $what will never"
      echo "         register with radio (#370)."
    else
      echo "Warning: $cfg still has task-init's object-shaped \`hooks\`. kiro-cli's V3"
      echo "         engine rewrites it at launch, but the committed copy keeps the old shape:"
      echo "         a git stash, checkout or reset that puts it back while $what runs"
      echo "         drops every radio hook for the rest of the session, and radio then calls"
      echo "         it dead (#370)."
    fi
    echo "         Fix it once, in the main checkout, and commit the result:"
    echo "           kiro-cli settings chat.enableAutoAgentUpgrade true"
    echo "           kiro-cli agent upgrade .kiro/agents && git add .kiro/agents && git commit"
    echo "         task-init keeps the upgraded shape (#267); a worktree forked before the"
    echo "         commit needs \`git merge <base>\`."
  } >&2
  return 0
}
