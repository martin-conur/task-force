#!/usr/bin/env bash
# Guard: jq >= 1.6 is required because task-init embeds `#` line-comment
# sentinels inside the jq program (region:read-only-allow). `#` comments
# landed in jq 1.6 (2018); jq 1.5 errors out with `unexpected '#'` and
# leaves .claude/settings.json half-written.
#
# Source this file and call `require_jq_1_6` before any jq invocation
# whose program contains `#` comments.

require_jq_1_6() {
  local v maj min
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq (>= 1.6) is required" >&2
    echo "       Install jq (https://jqlang.github.io/jq/) and re-run task-init." >&2
    return 1
  fi
  if ! v=$(jq --version 2>/dev/null); then
    echo "Error: 'jq --version' failed — install a working jq (>= 1.6)" >&2
    return 1
  fi
  v=${v#jq-}
  IFS='.' read -r maj min _ <<<"$v"
  maj=${maj%%[!0-9]*}
  min=${min%%[!0-9]*}
  if [[ -z "$maj" || -z "$min" ]] || (( maj < 1 || (maj == 1 && min < 6) )); then
    echo "Error: jq >= 1.6 required (have ${v:-unknown}) — task-init uses '#' comments inside the jq program (introduced in 1.6)" >&2
    return 1
  fi
}
