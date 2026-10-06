#!/usr/bin/env bash
# shellcheck disable=SC2034  # hooks set globals (AW_*, flag state) that bin/task-work reads
# Kiro CLI agent module (#236, #237). Sourced after the tracker module.
#
# This file is meant to be sourced, not executed. $AW_ROOT must be set by the
# caller before sourcing.
#
# task-done has no agent axis: the three kiro copies were byte-identical to the
# matching claude ones, including the `radio unregister --manual` and mailbox
# sweep, because removing a worktree and closing a tab does not depend on which
# agent was in it.
#
# task-work is where the kiro divergence lives: -m/--model, -a/--trust-all,
# TASK_WORK_TRUST_ALL normalization, the aw_require_kiro_agent preflight (#218),
# and --auto meaning auto-submit only rather than a permission mode — kiro's
# permission model is --trust-all-tools, and stays separate.
#
# Globals this module owns: MODEL, TRUST_ALL. It reads the body's AUTO_MODE
# nowhere: on kiro --auto's whole effect is the radio prefix, which is the
# canonical body's.

# The agent preflight (#218). Lived outside the drift-guarded header on the three
# kiro task-work copies, since the claude ones have no kiro agent to check.
# shellcheck source=lib/kiro-agent.sh
source "$AW_ROOT/lib/kiro-agent.sh"

aw_agent_name() { echo kiro; }

aw_agent_usage_options() {
  cat <<'OPTS'
  -m, --model MODEL   Model to pass to kiro-cli (e.g. claude-opus-4.6,
                      claude-sonnet-4.5). Defaults to $TASK_WORK_MODEL if set,
                      else kiro-cli's own default (auto).
  -a, --trust-all     Pass --trust-all-tools to kiro-cli so the worker can run
                      commands without per-tool confirmation. Defaults to
                      $TASK_WORK_TRUST_ALL=1 if set.
      --auto          Opt this worker into radio's auto-submit wake-up: an
                      incoming ping is submitted for the agent instead of
                      sitting in its prompt box until someone presses Enter.
                      Governs auto-submit ONLY — kiro's permission model is
                      -a/--trust-all and stays separate. Also keeps focus on
                      the calling tab instead of switching to the new one.
                      (No effect with --no-launch.)
      --auto-submit   Auto-submit without the focus behaviour of --auto.
      --no-auto-submit
                      Keep the Enter gate on radio wakes even with --auto
                      (which then only keeps focus on the calling tab).
OPTS
}

aw_agent_usage_env() {
  cat <<'ENV'

Environment:
  TASK_WORK_MODEL         Default model (overridable with --model)
  TASK_WORK_TRUST_ALL     If set to 1/true, defaults --trust-all on
ENV
}

aw_agent_usage_examples() {
  echo "  task-work refactor-auth -m claude-opus-4.6 --trust-all"
  echo "  task-work refactor-auth --trust-all --auto   # radio pings submit themselves"
  echo "  TASK_WORK_MODEL=claude-sonnet-4.6 task-work new-thing"
}

aw_agent_init_flags() {
  MODEL="${TASK_WORK_MODEL:-}"
  TRUST_ALL=""
  # Treat TASK_WORK_TRUST_ALL=1 / true / yes as enabled
  case "${TASK_WORK_TRUST_ALL:-}" in
    1|true|TRUE|yes|YES) TRUST_ALL="1" ;;
  esac
}

# aw_agent_parse_flag <args>...
#
# First refusal on the current token. Returns 0 and sets AW_FLAG_SHIFT when the
# token is ours; non-zero for anything else, positionals included.
aw_agent_parse_flag() {
  case "$1" in
    -m|--model)
      [[ $# -ge 2 ]] || { echo "Error: --model requires a value" >&2; exit 1; }
      MODEL="$2"; AW_FLAG_SHIFT=2; return 0 ;;
    -a|--trust-all) TRUST_ALL="1"; AW_FLAG_SHIFT=1; return 0 ;;
  esac
  return 1
}

# No mutually exclusive pair on kiro: --auto is not a permission mode here, so
# it composes with --trust-all.
aw_agent_validate_flags() { :; }

# aw_agent_preflight <repo_root> <impl>
#
# Fail before anything is created (#218). A worktree + branch + tab spawned for
# an agent that will silently fall back to a hookless built-in is scaffolding
# nobody asked for, and the radio failure it causes looks like a radio bug.
# Checked against the repo root rather than the not-yet-created worktree: an
# agent config tracked in the repo is present in the worktree too, and a false
# pass only degrades to the previous behaviour. Takes the impl, not just the
# agent, because the remedy it prints names the exact `task-init <impl>`.
aw_agent_preflight() {
  aw_require_kiro_agent worker "$1" "task-init $2"
}

# aw_agent_launch_cmd <quoted-ref> <quoted-prompt>
#
# The prompt arrives already `printf %q`-quoted by the body (#144 round-5).
# kiro takes it as a bare positional, with no /worker wrapper: the agent is
# selected by --agent instead. MODEL is not quoted, as it never was.
aw_agent_launch_cmd() {
  local prompt="$2" cmd="kiro-cli chat --agent worker"
  [[ -n "$MODEL" ]] && cmd+=" --model $MODEL"
  [[ -n "$TRUST_ALL" ]] && cmd+=" --trust-all-tools"
  [[ -n "$prompt" ]] && cmd+=" \"$prompt\""
  echo "$cmd"
}

# The noun in "Started <this> in <dir>".
aw_agent_started_message() {
  local desc="worker"
  [[ -n "$MODEL" ]] && desc+=" [model=$MODEL]"
  [[ -n "$TRUST_ALL" ]] && desc+=" [trust-all]"
  echo "$desc"
}

# ---------------- task-recreate-worker hooks ----------------

# aw_agent_resume_cmd <session-id>
#
# Refuses: kiro-cli has no session picker and no resume-by-id, so there is no
# launch line to give. A hook that refuses rather than an absent one, so the
# caller gates on the hook's status instead of on the agent's name (#239).
aw_agent_resume_cmd() {
  echo "Error: --resume is claude-only; kiro-cli has no session picker to hand you." >&2
  echo "       Re-run without --resume for a fresh session on the same worktree." >&2
  return 1
}
