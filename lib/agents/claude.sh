#!/usr/bin/env bash
# shellcheck disable=SC2034  # hooks set globals (AW_*, flag state) that bin/task-work reads
# Claude Code agent module (#236, #237). Sourced after the tracker module.
#
# This file is meant to be sourced, not executed.
#
# task-done has NO agent axis at all: `diff claude-gh/bin/task-done
# kiro-gh/bin/task-done` was empty, and neither copy ever mentioned `claude` or
# `kiro-cli` — the file only ever removes a worktree, sweeps radio state and
# closes a tab, none of which cares which agent was sitting in it.
#
# task-work's hooks (#237) are where this earns its keep — the launch line,
# --plan, --auto's permission-mode meaning, the usage Options block.

# ---------------- task-work hooks ----------------
#
# Globals this module owns: PLAN_MODE. It READS the body's AUTO_MODE, and only
# in aw_agent_validate_flags / aw_agent_launch_cmd: --auto's effect on radio
# auto-submit is the canonical body's, identical across agents, and no module
# may redefine it (#237).

aw_agent_name() { echo claude; }

aw_agent_usage_options() {
  cat <<'OPTS'
  -p, --plan          Launch claude with --permission-mode plan, running
                      /planner instead of /worker. Mutually exclusive with --auto.
                      (No effect with --no-launch.)
      --auto          Launch claude with --permission-mode auto (auto-accept
                      low-risk tool calls) and opt into radio auto-submit, as
                      --auto-submit does. Mutually exclusive with --plan.
      --auto-submit   Opt into radio auto-submit only: an incoming PM ping is
                      submitted for the agent instead of sitting in its prompt
                      box until someone presses Enter. Leaves the permission
                      mode alone, so it composes with --plan or no mode at all.
      --no-auto-submit
                      Keep the Enter gate on radio wakes even with --auto.
OPTS
}

aw_agent_usage_env() { :; }

aw_agent_usage_examples() {
  echo "  task-work spike-idea --plan"
}

aw_agent_init_flags() {
  PLAN_MODE=""
}

# aw_agent_parse_flag <args>...
#
# First refusal on the current token. Returns 0 and sets AW_FLAG_SHIFT when the
# token is ours; non-zero for anything else, positionals included.
aw_agent_parse_flag() {
  case "$1" in
    --plan|-p) PLAN_MODE="1"; AW_FLAG_SHIFT=1; return 0 ;;
  esac
  return 1
}

aw_agent_validate_flags() {
  if [[ -n "${AUTO_MODE:-}" && -n "$PLAN_MODE" ]]; then
    echo "Error: --auto and --plan are mutually exclusive" >&2
    exit 1
  fi
}

# claude needs no preflight: there is no per-repo agent config it can fall back
# from silently, which is what kiro's (#218) guards against.
aw_agent_preflight() { :; }

# aw_agent_launch_cmd <quoted-ref> <quoted-prompt>
#
# Both arguments arrive already `printf %q`-quoted by the body, so `$var`,
# `$(...)`, backticks and other shell metacharacters in a user-supplied ref
# survive the `bash -ic` re-parse without being expanded by the child shell.
# `set +H` in the launch-site prefix handles `!` history expansion; %q closes
# the rest of the metachar class. (#144 round-5 review.)
#
# Plan mode hands /planner the bare ref, not the worker payload: the planner's
# job is to write the spec, not to "implement" it.
aw_agent_launch_cmd() {
  local q_ref="$1" prompt="$2"
  if [[ -n "$PLAN_MODE" ]]; then
    if [[ -n "$q_ref" ]]; then
      echo "claude --permission-mode plan \"/planner $q_ref\""
    else
      echo "claude --permission-mode plan \"/planner\""
    fi
    return
  fi
  local mode_prefix=""
  [[ -n "${AUTO_MODE:-}" ]] && mode_prefix="--permission-mode auto "
  if [[ -n "$prompt" ]]; then
    echo "claude ${mode_prefix}\"/worker $prompt\""
  else
    echo "claude ${mode_prefix}\"/worker\""
  fi
}

# The noun in "Started <this> in <dir>".
aw_agent_started_message() { echo "worker"; }

# ---------------- task-recreate-worker hooks ----------------

# aw_agent_resume_cmd <session-id>
#
# The launch line that resumes this role's previous session instead of starting
# a fresh one (#239). An empty id hands over to Claude's own picker: the caller
# found nothing that identifies the session beyond doubt, and resuming the wrong
# one silently is worse than asking. Reads AUTO_MODE exactly as
# aw_agent_launch_cmd does.
aw_agent_resume_cmd() {
  local id="$1" mode_prefix=""
  [[ -n "${AUTO_MODE:-}" ]] && mode_prefix="--permission-mode auto "
  if [[ -n "$id" ]]; then
    echo "claude ${mode_prefix}--resume $id"
  else
    echo "claude ${mode_prefix}--resume"
  fi
}
