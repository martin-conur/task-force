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
  local help
  help=$(kiro-cli chat --help 2>/dev/null) || return 0
  [[ "$help" =~ (^|[[:space:],])--tui([[:space:],]|$) ]] && printf ' --tui'
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
# The fix it names is `false`, not `true`. Both skip the dialog, but true lets
# kiro-cli rewrite .kiro/agents/*.json in place into its "universal" format,
# whose `hooks` is an array: the radio hooks survive that rewrite, but
# task-init's hook merge reads `hooks` as an object and fails on every
# re-run. Under false the configs stay as task-init wrote them, and V3 loads
# them as they are, radio hooks firing (verified on 2.32.0).
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
    echo "           kiro-cli settings chat.enableAutoAgentUpgrade false"
    echo "         (true skips it too, but rewrites .kiro/agents/*.json into a format"
    echo "         task-init cannot merge radio hooks into yet.)"
  } >&2
  return 0
}
