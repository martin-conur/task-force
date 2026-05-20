#!/usr/bin/env bash
# Shared helper for the workflow-doc placeholder-preservation step.
#
# When a task-init script re-renders the workflow template into an existing
# target, we want to carry forward whatever values the user previously filled
# in. This file exposes a generic extractor; per-loadout task-init scripts
# define their own placeholder→pattern map and call extract_existing_value()
# for each placeholder.
#
# Precedence (per placeholder):
#   1. value from this-run's flag         (set before calling preserve)
#   2. value from existing rendered file  (extract_existing_value)
#   3. leave the {PLACEHOLDER} token

# extract_existing_value <file> <sed_ERE_pattern_with_one_capture> <placeholder>
#
# Runs the pattern as a sed -E substitution with a single capture group
# (matched value → \1). Prints the first match if it is non-empty and not
# equal to the literal placeholder. Otherwise prints nothing.
extract_existing_value() {
  local file="$1" pattern="$2" placeholder="$3"
  [[ -f "$file" ]] || return 0
  local matches value
  matches=$(sed -nE "s|$pattern|\1|p" "$file")
  # Take the first matched line without piping into head (avoids SIGPIPE
  # interactions when callers run with set -o pipefail).
  value="${matches%%$'\n'*}"
  if [[ -z "$value" || "$value" == "$placeholder" ]]; then
    return 0
  fi
  printf '%s' "$value"
}
