#!/usr/bin/env bash
# Workflow-doc setting bullets: `- **<name>**: `<value>``, read by task-watch
# (#328) and task-merge-gate (#329). The LAST matching bullet wins, so an
# override below the managed-region end marker beats the template's default and
# survives every task-init re-run. A value of `default` means the default.
#
# Sourced, never executed. Must run on /bin/bash 3.2.

# tf_doc_setting <doc> <bullet name> <default>
tf_doc_setting() {
  local v
  v=$(sed -nE "s|^- \*\*$2\*\*: \`([^\`]+)\`.*|\1|p" "$1" 2>/dev/null | tail -n 1)
  [[ -n "$v" && "$v" != default ]] || v="$3"
  printf '%s' "$v"
}

# tf_doc_number_setting <doc> <bullet name> <default>: as above, and refuses
# (stderr, return 1) a value that is not a whole number.
tf_doc_number_setting() {
  local v
  v=$(tf_doc_setting "$1" "$2" "$3")
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    echo "Error: '$2' in $1 must be a whole number, got '$v'" >&2
    return 1
  fi
  printf '%s' "$v"
}
