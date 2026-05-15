#!/usr/bin/env bash
# Shared impl-detection logic for the root task-work / task-done dispatchers.
#
# This file is meant to be sourced, not executed.
#
# Exports:
#   aw_parse_impl_flag "$@"     -> populates AW_PARSED_IMPL and AW_REMAINING_ARGS
#   aw_detect_impl <flag-impl>  -> prints the impl name to stdout (or returns 1)
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

    local matches=()
    [[ -f "$repo_root/.claude/jira-workflow.md"          ]] && matches+=("claude-jira")
    [[ -f "$repo_root/.claude/notion-workflow.md"        ]] && matches+=("claude-notion")
    [[ -f "$repo_root/.claude/gh-workflow.md"            ]] && matches+=("claude-gh")
    [[ -f "$repo_root/.claude/local-workflow.md"         ]] && matches+=("claude-local")
    [[ -f "$repo_root/.kiro/steering/notion-workflow.md" ]] && matches+=("kiro-notion")
    [[ -f "$repo_root/.kiro/steering/gh-workflow.md"     ]] && matches+=("kiro-gh")
    [[ -f "$repo_root/.kiro/steering/local-workflow.md"  ]] && matches+=("kiro-local")

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

  case "$impl" in
    claude-jira|claude-notion|claude-gh|claude-local|kiro-notion|kiro-gh|kiro-local) ;;
    *)
      echo "Error: unknown impl '$impl'" >&2
      echo "Valid impls: claude-jira, claude-notion, claude-gh, claude-local, kiro-notion, kiro-gh, kiro-local" >&2
      return 1 ;;
  esac

  printf '%s\n' "$impl"
}
