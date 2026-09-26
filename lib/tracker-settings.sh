#!/usr/bin/env bash
# Single source of truth for "what settings does a tracker carry, and how are
# they spelled in a rendered workflow doc?" (#219).
#
# This file is meant to be sourced, not executed.
#
# Before #219 the extraction regexes lived inside each loadout's
# bin/task-init, as a per-loadout _preserve_placeholders function — fine while
# task-init was the only reader, but `task-config` has to read the *same*
# values back out of a doc the installer wrote, and a second copy of a regex
# that has to agree byte-for-byte with the template is exactly the drift the
# repo's `# region:` sentinels exist to prevent.
#
# Exports:
#   tf_tracker_table <tracker>              -> one "field|placeholder|flag|regex" line per setting
#   tf_tracker_fields <tracker>             -> space-separated field names
#   tf_tracker_value <doc> <tracker> <field>-> the filled-in value, or nothing
#   tf_tracker_extract <doc> <tracker>      -> "field=value" lines for filled-in settings
#   tf_tracker_init_flags <doc> <tracker>   -> task-init flag tokens, one per line
#   tf_preserve_gh <doc>                    -> fills OWNER / REPO / PROJECT
#   tf_preserve_jira <doc>                  -> fills SITE / KEY / BOARD

_TF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/preserve-placeholders.sh
. "$_TF_LIB_DIR/preserve-placeholders.sh"

# The settings table, per tracker. Fields are |-separated:
#
#   <field>       lowercase key used by `task-config show` and the flag mapping
#   <placeholder> the literal token the template carries before it is filled in;
#                 extract_existing_value treats a doc still holding it as unset
#   <flag>        the task-init flag that sets it (empty = not flag-driven, so
#                 task-config cannot carry it and task-init cannot be told it)
#   <regex>       sed ERE with one capture group, matched against the rendered
#                 markdown bullet in <loadout>/steering/<tracker>-workflow.example.md
#
# The backticks are literal: the templates render every value inside a markdown
# code span. claude and kiro share one template shape per tracker, which is why
# `task-config set assistant` can carry these across and `set tracker` cannot.
tf_tracker_table() {
  case "$1" in
    gh)
      cat <<'EOF'
owner|{OWNER}|--owner|^- \*\*Owner\*\*: `([^`]+)`.*
repo|{REPO}|--repo|^- \*\*Repo\*\*: `([^`]+)`.*
project|{PROJECT}|--project|^- \*\*Project number\*\*: `([^`]+)`.*
EOF
      ;;
    jira)
      cat <<'EOF'
site|{SITE}|--site|^- \*\*Site\*\*: `([^`]+)`.*
key|{KEY}|--key|^- \*\*Project key\(s\)\*\*: `([^`]+)`.*
board|{BOARD}|--board|^- \*\*Board name\*\*: `([^`]+)`.*
EOF
      ;;
    notion)
      # Notion's IDs are not flag-driven: they cannot be derived from a URL and
      # only an active Notion MCP session can discover them (`task-init
      # claude-notion --help-ids`). So they are readable — `show` prints them —
      # but there is no flag for task-config to hand forward, which is why a
      # claude-notion ↔ kiro-notion switch leaves them for you to re-paste.
      cat <<'EOF'
tasks|collection://<YOUR_TASKS_DATA_SOURCE_ID>||^- \*\*Tasks\*\*: `([^`]+)`.*
projects|collection://<YOUR_PROJECTS_DATA_SOURCE_ID>||^- \*\*Projects\*\*: `([^`]+)`.*
board|<YOUR_BOARD_PAGE_ID>||^- \*\*Board page\*\*: `([^`]+)`.*
EOF
      ;;
    local)
      # Local tracking has no tracker settings at all — the backlog is the
      # tasks/ directory, and its location is not configurable.
      : ;;
    *) return 1 ;;
  esac
}

# tf_tracker_fields <tracker> -> "owner repo project" (empty for local)
tf_tracker_fields() {
  local field rest out=""
  while IFS='|' read -r field rest; do
    [[ -n "$field" ]] || continue
    out+="${out:+ }$field"
  done < <(tf_tracker_table "$1")
  printf '%s' "$out"
}

# tf_tracker_value <workflow-doc> <tracker> <field>
# Prints the value the doc carries for one setting, or nothing when the doc is
# missing, the bullet is absent, or the placeholder is still in place.
tf_tracker_value() {
  local doc="$1" tracker="$2" want="$3" field ph flag pat
  while IFS='|' read -r field ph flag pat; do
    [[ "$field" == "$want" ]] || continue
    # shellcheck disable=SC2034  # flag is part of the table shape, unused here
    : "$flag"
    extract_existing_value "$doc" "$pat" "$ph"
    return 0
  done < <(tf_tracker_table "$tracker")
  return 0
}

# tf_tracker_extract <workflow-doc> <tracker>
# Prints "field=value" for every setting the doc has a real value for. A
# setting still holding its placeholder is omitted, not reported as empty.
tf_tracker_extract() {
  local doc="$1" tracker="$2" field ph flag pat v
  while IFS='|' read -r field ph flag pat; do
    [[ -n "$field" ]] || continue
    # shellcheck disable=SC2034  # flag is part of the table shape, unused here
    : "$flag"
    v=$(extract_existing_value "$doc" "$pat" "$ph")
    [[ -n "$v" ]] || continue
    printf '%s=%s\n' "$field" "$v"
  done < <(tf_tracker_table "$tracker")
  return 0
}

# tf_tracker_init_flags <workflow-doc> <tracker>
# Prints the task-init flags that carry the doc's settings forward — one token
# per line, so a caller can `mapfile` them into an array without word-splitting
# a value that contains spaces (a Jira board name does).
tf_tracker_init_flags() {
  local doc="$1" tracker="$2" field ph flag pat v
  while IFS='|' read -r field ph flag pat; do
    [[ -n "$flag" ]] || continue
    v=$(extract_existing_value "$doc" "$pat" "$ph")
    [[ -n "$v" ]] || continue
    printf '%s\n%s\n' "$flag" "$v"
  done < <(tf_tracker_table "$tracker")
  return 0
}

# tf_preserve_gh <existing-workflow-doc>
# Fills OWNER / REPO / PROJECT in the *caller's* scope from an already-rendered
# gh workflow doc, for each value the caller did not set via flag and has not
# otherwise resolved. Precedence is unchanged from the pre-#219 in-task-init
# version: this-run flag > existing file > interactive prompt > {PLACEHOLDER}.
tf_preserve_gh() {
  local existing="$1" v
  [[ -f "$existing" ]] || return 0
  if [[ "${OWNER_VIA_FLAG:-false}" == false && -z "${OWNER:-}" ]]; then
    v=$(tf_tracker_value "$existing" gh owner)
    if [[ -n "$v" ]]; then OWNER="$v"; fi
  fi
  if [[ "${REPO_VIA_FLAG:-false}" == false && -z "${REPO:-}" ]]; then
    v=$(tf_tracker_value "$existing" gh repo)
    if [[ -n "$v" ]]; then REPO="$v"; fi
  fi
  if [[ "${PROJECT_VIA_FLAG:-false}" == false && -z "${PROJECT:-}" ]]; then
    v=$(tf_tracker_value "$existing" gh project)
    if [[ -n "$v" ]]; then PROJECT="$v"; fi
  fi
  return 0
}

# tf_preserve_jira <existing-workflow-doc>
# The Jira counterpart: SITE / KEY / BOARD.
tf_preserve_jira() {
  local existing="$1" v
  [[ -f "$existing" ]] || return 0
  if [[ "${SITE_VIA_FLAG:-false}" == false && -z "${SITE:-}" ]]; then
    v=$(tf_tracker_value "$existing" jira site)
    if [[ -n "$v" ]]; then SITE="$v"; fi
  fi
  if [[ "${KEY_VIA_FLAG:-false}" == false && -z "${KEY:-}" ]]; then
    v=$(tf_tracker_value "$existing" jira key)
    if [[ -n "$v" ]]; then KEY="$v"; fi
  fi
  if [[ "${BOARD_VIA_FLAG:-false}" == false && -z "${BOARD:-}" ]]; then
    v=$(tf_tracker_value "$existing" jira board)
    if [[ -n "$v" ]]; then BOARD="$v"; fi
  fi
  return 0
}
