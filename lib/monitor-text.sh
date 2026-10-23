#!/usr/bin/env bash
# Plain-text extraction for the task-monitor snapshot (#273).
#
# This file is meant to be sourced, not executed.
#
# Every function here reads markdown on stdin and prints one line: the
# paragraph's lines joined by single spaces, trimmed. Line-oriented awk on
# purpose. The bodies are issue and PR bodies, which run to kilobytes of UTF-8,
# and a bash `${var//pat/rep}` over a string that size is what hung task-remove
# under /bin/bash 3.2 (#266).
#
# Exports:
#   tm_first_paragraph      -> the first prose paragraph of a markdown body
#   tm_pr_summary           -> a PR body's `## Summary`, else the first prose
#                              paragraph after its `Closes #N` / `Closes PROJ-42`
#                              line, else its first prose paragraph
#   tm_strip_frontmatter    -> the body with a leading `---` … `---` block removed

# What counts as prose: not a heading, not an HTML comment, not a fence, not a
# horizontal rule. A paragraph ends at a blank line or at the next non-prose line.
_TM_AWK_COMMON='
  function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
  function skip(l) {
    return (l ~ /^#/ || l ~ /^<!--/ || l ~ /^```/ || l ~ /^(---|\*\*\*|___)$/)
  }
  # With prose=1 a paragraph that is only a link, "Label: <url>" or a "Closes …"
  # line is dropped and the search goes on (#299): a jira PR body opens with
  # "JIRA: <url>", which says nothing about the change.
  function link(p) { return (p ~ /^<?https?:\/\/[^ \t]+>?$/ || p ~ /^\[[^()]+\]\(https?:\/\/[^ \t)]+\)$/) }
  function junk(p,   q) {
    q = p; sub(/^[^ \t:]+([ \t]+[^ \t:]+)*:[ \t]+/, "", q)
    return (link(p) || link(q) ||
            tolower(p) ~ /^(close[sd]?|fix(e[sd])?|resolve[sd]?):?[ \t]+[^ \t]+$/)
  }
  function emit() {
    if (out == "") return
    if (prose && junk(out)) { out = ""; return }
    print out; done = 1
  }
  # A list item starts a block of its own, so a body that opens with a list
  # yields its first item rather than the whole list run together.
  function item(l) { return (l ~ /^([-*+]|[0-9]+[.)])[ \t]/) }
  function unmark(l) { sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", l); return l }
'

tm_first_paragraph() { _tm_first_paragraph 0; }

# The same, skipping link-only and `Closes …`-only paragraphs: for a PR body
# with no `## Summary`. Prints nothing when no paragraph has real prose.
tm_first_prose() { _tm_first_paragraph 1; }

_tm_first_paragraph() {
  awk -v prose="$1" "$_TM_AWK_COMMON"'
    done { next }
    { l = trim($0) }
    l == "" { emit(); next }
    skip(l) { emit(); next }
    item(l) { emit(); if (done) next; l = unmark(l) }
    { out = (out == "" ? l : out " " l) }
    END { if (!done) emit() }
  '
}

tm_strip_frontmatter() {
  awk '
    NR == 1 && $0 ~ /^---[ \t\r]*$/ { infm = 1; next }
    infm && $0 ~ /^---[ \t\r]*$/    { infm = 0; next }
    !infm { print }
  '
}

# The worker prompts ask for `## Summary` first in every PR body (#272 sub-issue
# 2): two or three plain sentences for the user. Older PRs have none, and on
# this repo their first paragraph is the `Closes #N` line itself, which is why
# the fallback starts after it rather than at the top. A jira PR closes a key or
# a browse URL rather than `#N` (#299).
tm_pr_summary() {
  local body summary
  body=$(cat)
  summary=$(printf '%s\n' "$body" | awk "$_TM_AWK_COMMON"'
    done { next }
    { l = trim($0) }
    !insec && tolower(l) ~ /^##[ \t]+summary[ \t]*$/ { insec = 1; next }
    !insec { next }
    l ~ /^#/ { emit(); exit }
    l == "" { if (out != "") { emit() } ; next }
    skip(l) { next }
    item(l) { emit(); if (done) next; l = unmark(l) }
    { out = (out == "" ? l : out " " l) }
    END { if (!done) emit() }
  ')
  if [[ -z "$summary" ]]; then
    summary=$(printf '%s\n' "$body" | awk '
      found { print; next }
      tolower($0) ~ /(close[sd]?|fix(e[sd])?|resolve[sd]?):?[ \t]+([^ \t]*#[0-9]+|[^ \t]*\/browse\/[a-z][a-z0-9_]*-[0-9]+|[a-z][a-z0-9_]*-[0-9]+([^a-z0-9_-]|$))/ { found = 1 }
    ' | tm_first_prose)
  fi
  if [[ -z "$summary" ]]; then
    summary=$(printf '%s\n' "$body" | tm_first_prose)
  fi
  printf '%s\n' "$summary"
}
