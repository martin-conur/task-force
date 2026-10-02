#!/usr/bin/env bash
# Shared impl-detection logic for the root task-work / task-done dispatchers.
#
# This file is meant to be sourced, not executed.
#
# Exports:
#   aw_parse_impl_flag "$@"     -> populates AW_PARSED_IMPL and AW_REMAINING_ARGS
#   aw_detect_impl <flag-impl>  -> prints the impl name to stdout (or returns 1)
#   aw_all_impls                -> every valid impl name, one per line
#   aw_impl_list                -> the same, on one line, for an error or a hint
#   aw_impl_workflow_doc <root> <impl> -> the workflow doc that marks that impl
#   aw_tracker_module <root> <tracker>  -> lib/trackers/<tracker>.sh, or an error
#   aw_agent_module <root> <agent>      -> lib/agents/<agent>.sh, or an error
#   aw_all_trackers / aw_all_agents     -> the axis names, derived from aw_all_impls
#   aw_detect_matches <root>    -> every impl configured in <root>, one per line
#   aw_collect_matches <root> [<pin>]  -> populates AW_MATCHES; 0 or many is fine
#   aw_require_configured <root> <pin> -> refuses a pin naming an impl that is not
#                                         configured in <root>
#
# Resolution order for the impl:
#   1. --impl <name> flag (consumed by aw_parse_impl_flag — not passed through)
#   2. AW_IMPL environment variable
#   3. Auto-detect from the presence of a workflow doc in the current git repo.
#      Single match -> that impl. Zero or >1 matches -> error.

# shellcheck disable=SC2034  # AW_PARSED_IMPL / AW_REMAINING_ARGS / AW_MATCHES are used by callers

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

# The two module files a canonical leaf script composes a loadout out of (#236).
#
# A loadout is {tracker × agent}, so the behaviour that used to live in seven
# copies of a script lives in four tracker modules and two agent modules instead.
# These resolve the paths, and they live here rather than in the leaf scripts for
# the same reason aw_all_impls does: "which loadouts exist" and "where does a
# loadout's behaviour come from" are one question, and the kiro-jira hole (#92)
# closes by adding a name to that list, not a file to a directory.
#
# Both print the path and return 0 only when the file is readable. The caller is
# expected to `|| exit 1` — a missing module is a broken checkout, and letting
# `source` fail on it instead produces bash's own "No such file or directory"
# naming a path the user never typed.
aw_tracker_module() { _aw_module tracker "$1" "$2"; }
aw_agent_module()   { _aw_module agent   "$1" "$2"; }

# _aw_module <kind> <root> <name>
#
# `kind` is singular for the message and plural for the directory, which is the
# only reason this is not two one-liners: `lib/trackers/gh.sh` reads better in a
# tree than `lib/tracker/gh.sh`, and "unknown tracker" reads better in an error
# than "unknown trackers".
_aw_module() {
  local kind="$1" root="$2" name="$3" path
  path="$root/lib/${kind}s/${name}.sh"
  if [[ ! -r "$path" ]]; then
    echo "Error: no $kind module for '$name' (expected $path)" >&2
    echo "       Is the repository complete?" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

# Every tracker / agent name a loadout can be built from, derived from
# aw_all_impls rather than listed again. The parity suite reads these, so a
# loadout added to the list above with no module file behind it fails a test
# instead of failing at someone's next task-done.
aw_all_trackers() { aw_all_impls | sed 's/.*-//' | sort -u; }
aw_all_agents()   { aw_all_impls | sed 's/-.*//' | sort -u; }

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

# The loadout names on one line, for an error message or a hint.
aw_impl_list() { aw_all_impls | tr '\n' ' ' | sed 's/ *$//'; }

# _aw_list_has <needle> <newline-separated-list>
# Whether <needle> is one of the lines. Reads the list from a here-string rather
# than a pipe on purpose: `producer | grep -qFx x` looks equivalent and is a trap
# under `set -o pipefail`, which every caller of this file sets. `grep -q` exits
# the instant it matches, so a producer that writes one line per item — which
# aw_detect_matches does — takes SIGPIPE on its *next* write and pipefail reports
# the pipeline as failed even though the match succeeded. It therefore misfires
# only when there are two or more items and the match is not the last one, i.e.
# exactly in the ambiguous repo that --impl exists for.
#
# All three call sites in this file use this helper, deliberately including
# aw_detect_impl's, where the producer is aw_all_impls — seven names in one printf,
# far smaller than the pipe buffer, so `grep -q` can never exit before the write
# completes and the fragile shape could not actually fire there. It was converted
# anyway: "works by accident of buffering" is not a property to leave in a file
# every dispatcher on all seven loadouts sources, and the trigger is not size but
# someone later making aw_all_impls emit per line, at which point every dispatcher
# starts rejecting valid impls. One shape everywhere also means nobody has to
# work out which of three call sites was the safe one.
_aw_list_has() {
  local needle="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<<"${2-}"
  return 1
}

# aw_collect_matches <root> [<pin>]
#
# Populate AW_MATCHES with every impl configured in <root> — or with just <pin>
# when one is given, which is how --impl / $AW_IMPL pin a repo to one loadout.
# Zero and many are both *fine* here; the callers differ in what they do about it
# (`task-config show` describes both, `task-config set` refuses many, and
# `task-remove` removes all of them). An unrecognised <pin> is the one refusal
# this makes itself, since no caller has a use for a name that does not exist.
#
# Shared by bin/task-config and bin/task-remove (#227). It was duplicated
# byte-for-byte between them with no drift sentinel, which is exactly how the
# --impl validation gap below came to exist in one copy and go unfixed in the
# other. Extracted rather than sentinelled, per the repo's own rule: this needed
# only $root and the two aw_ helpers already in this file, so there was nothing
# holding it in either script.
aw_collect_matches() {
  local root="$1" pin="${2:-}" m
  AW_MATCHES=()
  if [[ -n "$pin" ]]; then
    if ! _aw_list_has "$pin" "$(aw_all_impls)"; then
      echo "Error: unknown loadout '$pin'" >&2
      echo "       known: $(aw_impl_list)" >&2
      return 1
    fi
    AW_MATCHES=("$pin")
    return 0
  fi
  while IFS= read -r m; do
    [[ -n "$m" ]] && AW_MATCHES+=("$m")
  done < <(aw_detect_matches "$root")
  return 0
}

# aw_require_configured <root> <pin>
#
# Refuse a <pin> that names a real loadout which is not configured in <root>.
# No-op when <pin> is empty, so a caller can apply it unconditionally.
#
# `aw_all_impls` answers "is this a loadout name" and says *nothing* about what
# this repo has, so a pin that passes that check and no other is accepted while
# describing a loadout that is not there. Both callers then compute from the
# pinned name rather than from reality, and both fail by *appearing to succeed*:
# `task-remove --impl kiro-gh` on a claude-gh repo walked kiro-gh, removed
# nothing, and printed "task-force removed from <root>" — the only line a user
# stripping artifacts before a PR would check, so they ship every file they meant
# to strip. `task-config set tracker notion --impl kiro-gh` on the same repo was
# worse: it derived current=kiro-gh, removed kiro-gh's (nonexistent) artifacts and
# installed kiro-notion *beside* the untouched .claude/gh-workflow.md — two
# loadouts configured, which is the ambiguous state task-config exists to prevent
# and the one every dispatcher refuses on.
#
# Same failure class as #194's empty check list and #182's filter that failed
# open: correct-looking output for work that never happened.
aw_require_configured() {
  local root="$1" pin="${2:-}" detected
  [[ -n "$pin" ]] || return 0
  detected=$(aw_detect_matches "$root")
  _aw_list_has "$pin" "$detected" && return 0
  detected=$(printf '%s' "$detected" | tr '\n' ' ' | sed 's/ *$//')
  echo "Error: loadout '$pin' is not configured in $root" >&2
  echo "       configured here: ${detected:-none}" >&2
  return 1
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

  if ! _aw_list_has "$impl" "$(aw_all_impls)"; then
    echo "Error: unknown impl '$impl'" >&2
    echo "Valid impls: $(aw_all_impls | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi

  printf '%s\n' "$impl"
}
