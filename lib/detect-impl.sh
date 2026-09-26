#!/usr/bin/env bash
# Shared impl-detection logic for the root task-work / task-done dispatchers.
#
# This file is meant to be sourced, not executed.
#
# Exports:
#   aw_parse_impl_flag "$@"     -> populates AW_PARSED_IMPL and AW_REMAINING_ARGS
#   aw_detect_impl <flag-impl>  -> prints the impl name to stdout (or returns 1)
#   aw_all_impls                -> every valid impl name, one per line
#   aw_impl_workflow_doc <root> <impl> -> the workflow doc that marks that impl
#   aw_detect_matches <root>    -> every impl configured in <root>, one per line
#
# Resolution order for the impl:
#   1. --impl <name> flag (consumed by aw_parse_impl_flag — not passed through)
#   2. AW_IMPL environment variable
#   3. Auto-detect from the presence of a workflow doc in the current git repo.
#      Single match -> that impl. Zero or >1 matches -> error.

# shellcheck disable=SC2034  # AW_PARSED_IMPL / AW_REMAINING_ARGS are used by callers

# Parse --impl out of the argv. The flag (and its value) are stripped and
# everything else is preserved in order in AW_REMAINING_ARGS.
aw_parse_impl_flag() {
  AW_PARSED_IMPL=""
  AW_REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --impl)
        [[ $# -ge 2 ]] || { echo "Error: --impl requires a value" >&2; return 1; }
        AW_PARSED_IMPL="$2"; shift 2 ;;
      --impl=*)
        AW_PARSED_IMPL="${1#--impl=}"; shift ;;
      *)
        AW_REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
}

# The canonical impl list, in the order detection reports matches. Everything
# that needs to know "which loadouts exist" reads it from here (#219) —
# bin/task-config and lib/loadout-artifacts.sh included — so adding a combo is
# one edit rather than a hunt for hard-coded sevens.
aw_all_impls() {
  printf '%s\n' \
    claude-jira claude-notion claude-gh claude-local \
    kiro-notion kiro-gh kiro-local
}

# The workflow doc whose presence marks a repo as using <impl>. This is the
# detection key, and also the file `task-config show` reads tracker settings
# out of.
aw_impl_workflow_doc() {
  local root="$1" impl="$2" tracker="${2##*-}"
  case "${impl%%-*}" in
    claude) printf '%s/.claude/%s-workflow.md' "$root" "$tracker" ;;
    kiro)   printf '%s/.kiro/steering/%s-workflow.md' "$root" "$tracker" ;;
    *)      return 1 ;;
  esac
}

# Every impl configured in <root>, one per line. Zero, one or many — the caller
# decides what to do about it. aw_detect_impl treats anything but one as an
# error; `task-config show` treats all three as output (#219).
aw_detect_matches() {
  local root="$1" impl doc
  while IFS= read -r impl; do
    doc=$(aw_impl_workflow_doc "$root" "$impl") || continue
    [[ -f "$doc" ]] && printf '%s\n' "$impl"
  done < <(aw_all_impls)
  return 0
}

# Detect impl by inspecting the current git repo. Echoes the impl name on
# success, returns non-zero (and prints to stderr) on any error.
#
# Usage:
#   impl=$(aw_detect_impl "$AW_PARSED_IMPL") || exit 1
aw_detect_impl() {
  local flag_impl="${1:-}"
  local impl="$flag_impl"
  [[ -z "$impl" ]] && impl="${AW_IMPL:-}"

  if [[ -z "$impl" ]]; then
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) \
      || { echo "Error: not in a git repo" >&2; return 1; }

    local matches=() _m
    while IFS= read -r _m; do
      [[ -n "$_m" ]] && matches+=("$_m")
    done < <(aw_detect_matches "$repo_root")

    case "${#matches[@]}" in
      0)
        echo "Error: no agentic-workflow impl configured in $repo_root." >&2
        echo "Run: task-init <impl>  (e.g. task-init kiro-notion)" >&2
        return 1 ;;
      1)
        impl="${matches[0]}" ;;
      *)
        echo "Error: multiple agentic-workflow impls detected in $repo_root:" >&2
        printf '  - %s\n' "${matches[@]}" >&2
        echo "Pass --impl <name> or set AW_IMPL to pick one." >&2
        return 1 ;;
    esac
  fi

  if ! aw_all_impls | grep -qFx "$impl"; then
    echo "Error: unknown impl '$impl'" >&2
    echo "Valid impls: $(aw_all_impls | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi

  printf '%s\n' "$impl"
}
