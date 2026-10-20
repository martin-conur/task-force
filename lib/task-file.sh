#!/usr/bin/env bash
# Local task-file frontmatter reader, shared by bin/task-board and the local
# tracker module's task-monitor hooks (#273).
#
# This file is meant to be sourced, not executed. Pure awk, no jq, bash 3.2 safe.

# Read a single field from YAML frontmatter (very small grammar — keys are
# simple lowercase, values are scalar; strips surrounding quotes).
# Usage: aw_task_fm <file> <key>
aw_task_fm() {
  local file="$1" key="$2"
  awk -v key="$key" '
    /^---[[:space:]]*$/ {
      if (in_fm) { exit }
      in_fm = 1; next
    }
    in_fm && $0 ~ "^" key "[[:space:]]*:" {
      sub("^" key "[[:space:]]*:[[:space:]]*", "")
      gsub(/^"|"$/, "")
      gsub(/^'\''|'\''$/, "")
      print
      exit
    }
  ' "$file"
}
