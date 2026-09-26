#!/usr/bin/env bash
# Enumerate — and remove — the artifacts one loadout owns inside a repo (#219).
#
# This file is meant to be sourced, not executed.
#
# Two consumers by design: `bin/task-config set`, which cannot switch a repo
# between loadouts without first taking the old one out (leave one file behind
# and every dispatcher starts refusing with a multi-match error), and
# `task-remove` (#220), which is the same removal with no install after it.
#
# The governing rule is the inverse of task-init's idempotent merge (#183,
# #212): task-init adds its entries to files that may be the user's, so removal
# takes *only* its entries back out and deletes a file only when nothing else
# was in it. Concretely — a CLAUDE.md with the user's own instructions survives
# with just the `@.claude/<t>-workflow.md` import gone; a settings.json carrying
# the user's own Stop hook survives with just the radio hooks gone; a .gitignore
# loses only the `.git/task-force/` entry; and a tasks/ directory holding a real
# backlog keeps it.
#
# The role files need the same care, and this is the likeliest place in a switch
# to destroy work. task-init installs `.claude/commands/<role>.md` and
# `.kiro/agents/<role>.json` through install_file, whose `keep` / `prompt`
# policies let an existing file survive a re-run — and on kiro it then merges the
# radio hooks *into* that kept file (#218/#222), so an agent config can be the
# user's work carrying our entries. So removal never deletes a role file it
# cannot prove is task-init's own: it compares the installed file against the
# copy that shipped (on kiro, after stripping the radio hooks back out, which is
# the exact mirror of the install merge's `startswith("radio ")` guard), deletes
# only on a match, and otherwise keeps the file and says so.
#
# The workflow doc is the one file that must go regardless — it is the detection
# key, and leaving it is the multi-match state this all exists to avoid. When it
# carries repo-specific sections below the managed-region end marker (#183), it
# is copied to <doc>.bak first, the same way task-init's own adoption path does.
#
# Every function is safe to call for a loadout that was never installed here:
# enumeration reports only what is actually on disk.
#
# Exports:
#   la_assistant <loadout>            -> claude | kiro
#   la_tracker <loadout>              -> gh | jira | notion | local
#   la_workflow_doc <root> <loadout>  -> the detection key's path
#   la_owned_paths <root> <loadout>   -> existing task-init-written files, repo-relative
#                                        (inventory only — #220's task-remove asks
#                                        this without removing anything)
#   la_seeded_allow <loadout>         -> the permission literals task-init seeds
#   la_plan <root> <loadout>          -> what removal would do; touches nothing
#   la_remove <root> <loadout>        -> does it, printing the same lines

_LA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The task-force checkout, one level up from lib/. Removal needs it to compare an
# installed role file against the copy that shipped — see _la_role_disposition.
LA_AW_ROOT="$(dirname "$_LA_LIB_DIR")"
# shellcheck source=lib/detect-impl.sh
. "$_LA_LIB_DIR/detect-impl.sh"
# For MANAGED_END / managed_markers_present / _managed_tail_stub /
# _managed_backup_path — removal reads the same boundary task-init writes, so the
# "everything below the end marker is yours" promise (#183) survives a switch.
# shellcheck source=lib/managed-region.sh
. "$_LA_LIB_DIR/managed-region.sh"

# The role files task-init installs. Enumerated by name rather than globbed:
# `.claude/commands/` and `.kiro/agents/` are shared directories, and a command
# or agent of the user's own sitting beside ours is not ours to delete. (The
# kiro local/notion loadouts ship only three of the four — a name that is not
# there is skipped, not an error.)
LA_ROLES=(pm planner worker reviewer)

# The inert .kiro/hooks/*.json files task-init wrote before #218, when it
# believed kiro-cli read that directory. Removed here for the same reason the
# #218 sweep removes them: left behind they are a stale copy of the radio
# wiring, pointed at by the docs, that never runs.
LA_LEGACY_KIRO_HOOKS=(radio-register radio-busy radio-ready)

# The two files task-init scaffolds inside tasks/ on the *-local loadouts.
# Everything else in tasks/ is the backlog, and stays.
LA_LOCAL_SCAFFOLD=(README.md _board.md)

# Directories task-init may create, deepest first. Each is reclaimed only once
# removal has emptied it — a .claude/ still holding the user's settings, or a
# second loadout's workflow doc, stays.
LA_DIRS=(.claude/commands .kiro/agents .kiro/hooks .kiro/steering tasks .claude .kiro)

la_assistant() { printf '%s' "${1%%-*}"; }
la_tracker()   { printf '%s' "${1##*-}"; }

la_workflow_doc() { aw_impl_workflow_doc "$1" "$2"; }

# la_seeded_allow <loadout>
# The `permissions.allow` literals that loadout's task-init seeds into
# .claude/settings.json, one per line. Kept in lockstep with the jq merge in
# <loadout>/bin/task-init — tests/task_config.bats reads both and compares.
#
# Known imprecision, accepted (#219): removal matches this literal set, so an
# entry the user independently wanted *and* task-init also seeds (`Read`,
# `Bash(ls *)`) goes away with a switch. `--dry-run` is the mitigation. A
# provenance manifest was weighed and rejected: task-config only ever removes
# one *named* loadout's artifacts, never "everything task-init ever did here",
# so the set is derivable from the loadout name alone.
la_seeded_allow() {
  local loadout="$1"
  case "$(la_tracker "$loadout")" in
    gh)
      printf '%s\n' \
        'Bash(gh issue view *)' \
        'Bash(gh issue list *)' \
        'Bash(gh issue comment *)' \
        'Bash(gh project view *)' \
        'Bash(gh project item-list *)' \
        'Bash(gh project field-list *)' \
        'Bash(gh project list *)' \
        'Bash(gh search issues *)' \
        'Bash(gh pr view *)' \
        'Bash(gh pr diff *)' \
        'Bash(gh pr list *)' \
        'Bash(gh label list *)' \
        'Bash(gh auth status)' \
        'Bash(gh repo view *)' ;;
    jira)
      printf '%s\n' \
        'mcp__atlassian__getJiraIssue' \
        'mcp__atlassian__searchJiraIssuesUsingJql' \
        'mcp__atlassian__getVisibleJiraProjects' \
        'mcp__atlassian__getJiraIssueRemoteIssueLinks' \
        'mcp__atlassian__getTransitionsForJiraIssue' \
        'mcp__atlassian__getJiraProjectIssueTypesMetadata' \
        'mcp__atlassian__getIssueLinkTypes' \
        'mcp__atlassian__lookupJiraAccountId' \
        'mcp__atlassian__atlassianUserInfo' ;;
    notion)
      printf '%s\n' \
        'mcp__notion__notion-search' \
        'mcp__notion__notion-fetch' \
        'mcp__notion__notion-query-data-sources' \
        'mcp__notion__notion-query-database-view' \
        'mcp__notion__notion-get-comments' \
        'mcp__notion__notion-get-teams' \
        'mcp__notion__notion-get-users' \
        'mcp__notion__notion-get-user' \
        'mcp__notion__notion-get-self' ;;
  esac
  # The tail every claude loadout shares: `Bash(radio *)` plus the
  # `read-only-allow` region.
  printf '%s\n' \
    'Bash(radio *)' \
    'Read' \
    'Grep' \
    'Glob' \
    'Bash(find *)' \
    'Bash(ls *)' \
    'Bash(cat *)' \
    'Bash(rg *)'
}

# region:radio-legacy-hook-guard
# True only for a .kiro/hooks/<name>.json that radio itself wrote: it carries
# both the "shellCommand" wrapper the pre-#218 installer used and a radio command
# inside it. A hook of the user's own in that directory is not ours to touch.
#
# Deliberately duplicated rather than shared, and guarded because of it: the kiro
# installers sweep these files when they install (#218/#222), lib/loadout-artifacts.sh
# removes them when a loadout is taken out (#219), and the installers do not
# source that lib. Extracting it would mean reworking a region that #220 and #221
# both queue against, so the copies stay — byte-identical and drift-guarded, so
# editing one without the other is caught instead of silently diverging, which is
# the failure that produced the ${TASK_FORCE_LOADOUT:-} drift #222 had to clean up.
_tf_is_legacy_radio_hook() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -q '"shellCommand"' "$f" 2>/dev/null || return 1
  grep -q '"radio ' "$f" 2>/dev/null || return 1
  return 0
}
# endregion:radio-legacy-hook-guard

# _la_other_owned_paths <root> <loadout>
# The task-init-written files that are unconditionally removable — nothing of the
# user's is ever merged into them, so there is no disposition to decide. Today:
# the inert pre-#218 .kiro/hooks/*.json, and the tasks/ scaffolding on the
# *-local loadouts. One repo-relative path per line.
_la_other_owned_paths() {
  local root="$1" loadout="$2" name
  if [[ "$(la_assistant "$loadout")" == kiro ]]; then
    for name in "${LA_LEGACY_KIRO_HOOKS[@]}"; do
      if _tf_is_legacy_radio_hook "$root/.kiro/hooks/$name.json"; then
        printf '.kiro/hooks/%s.json\n' "$name"
      fi
    done
  fi
  if [[ "$(la_tracker "$loadout")" == local ]]; then
    for name in "${LA_LOCAL_SCAFFOLD[@]}"; do
      if [[ -f "$root/tasks/$name" ]]; then printf 'tasks/%s\n' "$name"; fi
    done
  fi
  return 0
}

# la_owned_paths <root> <loadout>
# Every task-init-written file for that loadout that currently exists, one
# repo-relative path per line — the *inventory*, with no judgement about what a
# removal would do to each. #220's task-remove asks exactly this question before
# deciding anything, and `task-config show` renders it as the `owns` list.
#
# CLAUDE.md, .claude/settings.json and .gitignore are *edited* rather than owned,
# so they are not here; la_plan / la_remove report what comes out of them.
la_owned_paths() {
  local root="$1" loadout="$2" role doc action rel
  if doc=$(la_workflow_doc "$root" "$loadout"); then
    if [[ -f "$doc" ]]; then printf '%s\n' "${doc#"$root"/}"; fi
  fi
  for role in "${LA_ROLES[@]}"; do
    IFS=$'\t' read -r action rel < <(_la_role_disposition "$root" "$loadout" "$role")
    [[ "$action" == absent ]] || printf '%s\n' "$rel"
  done
  _la_other_owned_paths "$root" "$loadout"
  return 0
}

# _la_strip_agent_hooks <agent-json>
# Print the agent config with every radio-owned hook entry removed, emptied
# triggers dropped, and `hooks` itself dropped if that empties it.
#
# The `(.command // "") | startswith("radio ")` test is the exact mirror of the
# guard kiro-*/bin/task-init's _radio_install_hooks merge uses to recognise its
# own work (#218/#222) — an entry of the user's own on the same trigger is left
# alone. Unlike the install merge this sweeps *every* trigger rather than the
# three it writes, so the invalid `agentStop` entries older task-inits left
# behind come out too.
_la_strip_agent_hooks() {
  jq '
    def drop_radio(arr):
      [ (arr // [])[] | select(((.command // "") | startswith("radio ")) | not) ];
    ( if (.hooks | type) == "object"
      then .hooks = ( .hooks
                      | with_entries(.value = drop_radio(.value))
                      | with_entries(select((.value | length) > 0)) )
      else . end )
    | ( if (.hooks | type) == "object" and (.hooks | length) == 0
        then del(.hooks) else . end )
    ' "$1"
}

# _la_strip_agent_radio_hooks <root> <rel> <mode>
# Take the radio hooks out of an agent config that is staying, and say so. This
# is the kiro counterpart of the settings.json strip: the file is the user's, our
# entries are not, and only ours come out.
_la_strip_agent_radio_hooks() {
  local root="$1" rel="$2" mode="$3"
  local f="$root/$rel" stripped
  if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found — leaving $rel alone; remove its radio hooks by hand" >&2
    return 0
  fi
  if ! stripped=$(_la_strip_agent_hooks "$f" 2>/dev/null); then
    echo "Warning: $rel is not valid JSON — leaving it alone" >&2
    return 0
  fi
  if [[ "$(printf '%s' "$stripped" | jq -S .)" == "$(jq -S . "$f")" ]]; then
    # No radio hooks in it after all — nothing to take out, nothing to report
    # beyond the fact that the file is staying.
    if [[ "$mode" == plan ]]; then
      printf '  would keep %s — it is not the copy task-init ships, so it may be yours\n' "$rel"
    else
      printf '  kept %s — it is not the copy task-init ships, so it may be yours\n' "$rel"
    fi
    return 0
  fi
  if [[ "$mode" == apply ]]; then printf '%s\n' "$stripped" >"$f"; fi
  if [[ "$mode" == plan ]]; then
    printf '  would keep %s, radio hooks stripped — the rest of it may be yours\n' "$rel"
  else
    printf '  kept %s, radio hooks stripped — the rest of it may be yours\n' "$rel"
  fi
  return 0
}

# _la_role_disposition <root> <loadout> <role>
#
# Decide what to do with one installed role file, and print
# "<action>\t<repo-relative-path>" where <action> is:
#
#   delete   the file is task-init's own copy — safe to remove
#   keep     it differs from the shipped copy, so treat it as the user's
#   absent   task-init never installed it here (or it is already gone)
#
# For kiro the comparison is made against the *stripped* installed file, because
# task-init merges the radio hooks into whatever is on disk. So a pristine agent
# config compares equal and is deleted; a customized one does not, and is kept
# with only the radio hooks taken out.
_la_role_disposition() {
  local root="$1" loadout="$2" role="$3"
  local assistant installed shipped rel
  assistant=$(la_assistant "$loadout")

  if [[ "$assistant" == claude ]]; then
    rel=".claude/commands/$role.md"
    installed="$root/$rel"
    shipped="$LA_AW_ROOT/$loadout/commands/$role.md"
    [[ -f "$installed" ]] || { printf 'absent\t%s\n' "$rel"; return 0; }
    if [[ -f "$shipped" ]] && cmp -s "$shipped" "$installed"; then
      printf 'delete\t%s\n' "$rel"
    else
      printf 'keep\t%s\n' "$rel"
    fi
    return 0
  fi

  rel=".kiro/agents/$role.json"
  installed="$root/$rel"
  shipped="$LA_AW_ROOT/$loadout/agents/$role.json"
  [[ -f "$installed" ]] || { printf 'absent\t%s\n' "$rel"; return 0; }
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$shipped" ]]; then
    # Without jq there is no way to tell a pristine agent config from the user's,
    # and guessing here is exactly the guess that loses work.
    printf 'keep\t%s\n' "$rel"
    return 0
  fi
  local stripped
  if ! stripped=$(_la_strip_agent_hooks "$installed" 2>/dev/null); then
    printf 'keep\t%s\n' "$rel"
    return 0
  fi
  if [[ "$(printf '%s' "$stripped" | jq -S .)" == "$(jq -S . "$shipped")" ]]; then
    printf 'delete\t%s\n' "$rel"
  else
    printf 'keep\t%s\n' "$rel"
  fi
  return 0
}

# _la_workflow_doc_tail <doc>
# Whatever the user put below the managed-region end marker, with task-init's own
# stub tail removed. Empty when there is nothing of theirs to preserve.
_la_workflow_doc_tail() {
  local doc="$1" tail stub
  [[ -f "$doc" ]] || return 0
  if ! managed_markers_present "$doc"; then
    # A pre-#183 doc has no boundary to read. Its whole body is either the
    # template or the template plus the user's edits, and task-init's own
    # adoption path already refuses to guess which — so neither will this: treat
    # it as having content worth backing up.
    printf 'pre-markers'
    return 0
  fi
  tail=$(awk -v e="$MANAGED_END" 'f { print } $0 == e { f = 1 }' "$doc")
  stub=$(_managed_tail_stub)
  # Strip the stub wherever it sits, then see whether anything is left.
  tail=${tail//"$stub"/}
  printf '%s' "${tail//[[:space:]]/}"
}

# How many files in tasks/ are backlog rather than task-init scaffolding.
_la_backlog_count() {
  local root="$1" base scaffold keep n=0
  if [[ ! -d "$root/tasks" ]]; then printf '0'; return 0; fi
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    keep=0
    for scaffold in "${LA_LOCAL_SCAFFOLD[@]}"; do
      if [[ "$base" == "$scaffold" ]]; then keep=1; fi
    done
    if (( ! keep )); then n=$((n + 1)); fi
  done < <(ls -A "$root/tasks" 2>/dev/null || true)
  printf '%s' "$n"
}

# _la_dir_empty_after <root> <dir> <removed-newline-list> <created-newline-list>
# True when every entry currently in <dir> is one the removal takes out, and the
# removal puts nothing new there. In apply mode the removed entries are already
# gone and the created ones already present, so this degrades to a plain
# emptiness test; in plan mode it is what lets the plan predict the rmdir.
#
# <created> is why this takes four arguments rather than three. A workflow doc
# with sections of the user's own is backed up beside itself, and in plan mode
# that .bak does not exist yet — so without it the plan promised to reclaim
# .kiro/steering/ while the real run correctly left the backup sitting in it.
# A dry-run that over-promises is the failure the shared code path exists to
# rule out, so the created set travels with the removed one.
_la_dir_empty_after() {
  local root="$1" dir="$2" removed="$3" created="${4-}" base
  [[ -d "$root/$dir" ]] || return 1
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    if ! printf '%s\n' "$removed" | grep -qxF -- "$dir/$base"; then
      return 1
    fi
  done < <(ls -A "$root/$dir" 2>/dev/null || true)
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    [[ "$base" == "$dir/"* && "$base" != "$dir/"*/* ]] && return 1
  done < <(printf '%s\n' "$created")
  return 0
}

la_plan()   { _la_walk "$1" "$2" plan; }
la_remove() { _la_walk "$1" "$2" apply; }

# _la_walk <root> <loadout> <plan|apply>
#
# One body for both modes on purpose: a --dry-run that is a separate code path
# from the real thing is a --dry-run that can lie.
_la_walk() {
  local root="$1" loadout="$2" mode="$3"
  local assistant tracker verb rel dir removed="" created=""
  assistant=$(la_assistant "$loadout")
  tracker=$(la_tracker "$loadout")
  if [[ "$mode" == plan ]]; then verb="would remove"; else verb="removed"; fi

  # 1. The workflow doc — the detection key. It goes either way, but repo-specific
  #    sections below the managed-region end marker are backed up first.
  local doc doc_rel doc_tail backup
  doc=$(la_workflow_doc "$root" "$loadout")
  if [[ -f "$doc" ]]; then
    doc_rel="${doc#"$root"/}"
    doc_tail=$(_la_workflow_doc_tail "$doc")
    if [[ -n "$doc_tail" ]]; then
      backup=$(_managed_backup_path "$doc")
      if [[ "$mode" == apply ]]; then cp "$doc" "$backup"; fi
      created+="${backup#"$root"/}"$'\n'
      printf '  %s %s → kept a copy at %s (it has sections of yours below the managed-region marker)\n' \
        "$verb" "$doc_rel" "${backup#"$root"/}"
    else
      printf '  %s %s\n' "$verb" "$doc_rel"
    fi
    if [[ "$mode" == apply ]]; then rm -f "$doc"; fi
    removed+="$doc_rel"$'\n'
  fi

  # 2. The role files — deleted only where they can be proven task-init's own.
  local role action
  for role in "${LA_ROLES[@]}"; do
    IFS=$'\t' read -r action rel < <(_la_role_disposition "$root" "$loadout" "$role")
    case "$action" in
      delete)
        if [[ "$mode" == apply ]]; then rm -f "$root/$rel"; fi
        removed+="$rel"$'\n'
        printf '  %s %s\n' "$verb" "$rel" ;;
      keep)
        if [[ "$assistant" == kiro ]]; then
          _la_strip_agent_radio_hooks "$root" "$rel" "$mode"
        else
          if [[ "$mode" == plan ]]; then
            printf '  would keep %s — it differs from the copy %s ships, so it may be yours\n' "$rel" "$loadout"
          else
            printf '  kept %s — it differs from the copy %s ships, so it may be yours\n' "$rel" "$loadout"
          fi
        fi ;;
    esac
  done

  # 3. The inert pre-#218 .kiro/hooks/*.json, and the *-local tasks/ scaffolding.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ "$mode" == apply ]]; then rm -f "$root/$rel"; fi
    removed+="$rel"$'\n'
    printf '  %s %s\n' "$verb" "$rel"
  done < <(_la_other_owned_paths "$root" "$loadout")

  if [[ "$tracker" == local ]]; then
    local backlog
    backlog=$(_la_backlog_count "$root")
    if (( backlog > 0 )); then
      # The backlog is the user's content, exactly as their own CLAUDE.md
      # sections are. Scaffolding goes; task files stay, and say so.
      printf '  kept tasks/ — %s backlog file(s), yours rather than task-init'\''s\n' "$backlog"
    fi
  fi

  # CLAUDE.md and settings.json are claude-side only; kiro's task-init never
  # touches either.
  if [[ "$assistant" == claude ]]; then
    if _la_strip_line "$root" CLAUDE.md "@.claude/$tracker-workflow.md" "$mode" \
         "@.claude/$tracker-workflow.md import"; then
      removed+="CLAUDE.md"$'\n'
    fi
    if _la_strip_settings "$root" "$loadout" "$mode"; then
      removed+=".claude/settings.json"$'\n'
    fi
  fi

  # The *-local loadouts also append .git/task-force/ to .gitignore, on both
  # assistants.
  if [[ "$tracker" == local ]]; then
    if _la_strip_line "$root" .gitignore '.git/task-force/' "$mode" \
         ".git/task-force/ entry"; then
      removed+=".gitignore"$'\n'
    fi
  fi

  for dir in "${LA_DIRS[@]}"; do
    if _la_dir_empty_after "$root" "$dir" "$removed" "$created"; then
      if [[ "$mode" == apply ]]; then rmdir "$root/$dir" 2>/dev/null || continue; fi
      removed+="$dir"$'\n'
      printf '  %s %s/ (now empty)\n' "$verb" "$dir"
    fi
  done
  return 0
}

# _la_strip_line <root> <relpath> <line> <mode> <what>
#
# Take one whole line back out of a file task-init appended it to — the
# `@.claude/<t>-workflow.md` import in CLAUDE.md, the `.git/task-force/` entry
# the *-local loadouts append to .gitignore. The file is deleted only when that
# line was all it held, and <what> names the line in the report.
#
# Returns 0 only when the whole file went, so the caller can count it toward
# emptying a parent directory.
_la_strip_line() {
  local root="$1" rel="$2" line="$3" mode="$4" what="$5"
  local f="$root/$rel"
  [[ -f "$f" ]] || return 1
  grep -qxF -- "$line" "$f" || return 1

  local remaining
  remaining=$(grep -vxF -- "$line" "$f" || true)
  if [[ -z "${remaining//[[:space:]]/}" ]]; then
    if [[ "$mode" == apply ]]; then rm -f "$f"; fi
    if [[ "$mode" == plan ]]; then
      printf '  would remove %s (it held only the %s)\n' "$rel" "$what"
    else
      printf '  removed %s (it held only the %s)\n' "$rel" "$what"
    fi
    return 0
  fi

  if [[ "$mode" == apply ]]; then printf '%s\n' "$remaining" >"$f"; fi
  if [[ "$mode" == plan ]]; then
    printf '  would strip the %s from %s (your own content stays)\n' "$what" "$rel"
  else
    printf '  stripped the %s from %s (your own content stays)\n' "$what" "$rel"
  fi
  return 1
}

# Strip the radio hook entries and the seeded allow-list literals from
# .claude/settings.json. Radio entries are identified the same way task-init's
# merge recognises its own work — `(.command // "") | startswith("radio ")` —
# so a hook of the user's own on the same event survives. Returns 0 only when
# the whole file goes, as above.
_la_strip_settings() {
  local root="$1" loadout="$2" mode="$3"
  local f="$root/.claude/settings.json" rel=".claude/settings.json"
  [[ -f "$f" ]] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found — leaving $rel alone; remove its radio hooks by hand" >&2
    return 1
  fi

  local seeded stripped
  seeded=$(la_seeded_allow "$loadout" | jq -Rn '[inputs]')

  if ! stripped=$(jq --argjson seeded "$seeded" '
    def strip_radio(arr):
      [ (arr // [])[]
        | .hooks = [ ((.hooks // [])[])
                     | select(((.command // "") | startswith("radio ")) | not) ]
        | select((.hooks | length) > 0) ];

    ( if (.hooks | type) == "object"
      then .hooks = ( .hooks
                      | with_entries(.value = strip_radio(.value))
                      | with_entries(select((.value | length) > 0)) )
      else . end )
    | ( if (.hooks | type) == "object" and (.hooks | length) == 0
        then del(.hooks) else . end )
    # `. as $entry` is load-bearing: inside index(f), jq evaluates f with the
    # *piped* input as `.`, so a bare `$seeded | index(.)` would ask whether
    # $seeded contains itself — true for every entry, which quietly deleted the
    # whole allow-list including the users own.
    | ( if (.permissions | type) == "object" and (.permissions.allow | type) == "array"
        then .permissions.allow = [ .permissions.allow[]
                                    | . as $entry
                                    | select(($seeded | index($entry)) | not) ]
        else . end )
    | ( if (.permissions | type) == "object" and (.permissions.allow | type) == "array"
          and (.permissions.allow | length) == 0
        then .permissions = (.permissions | del(.allow)) else . end )
    | ( if (.permissions | type) == "object" and (.permissions | length) == 0
        then del(.permissions) else . end )
    ' "$f" 2>/dev/null); then
    echo "Warning: $rel is not valid JSON — leaving it alone" >&2
    return 1
  fi

  if [[ "$(printf '%s' "$stripped" | jq -c .)" == '{}' ]]; then
    if [[ "$mode" == apply ]]; then rm -f "$f"; fi
    if [[ "$mode" == plan ]]; then
      printf '  would remove %s (it held only task-force entries)\n' "$rel"
    else
      printf '  removed %s (it held only task-force entries)\n' "$rel"
    fi
    return 0
  fi

  if [[ "$mode" == apply ]]; then printf '%s\n' "$stripped" >"$f"; fi
  if [[ "$mode" == plan ]]; then
    printf '  would strip the radio hooks + seeded allow-list from %s (your own entries stay)\n' "$rel"
  else
    printf '  stripped the radio hooks + seeded allow-list from %s (your own entries stay)\n' "$rel"
  fi
  return 1
}
