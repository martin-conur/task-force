#!/usr/bin/env bash
# Reproduce the context-diet baseline (#396, epic #395): starting context per
# role, tokens per issue, review beats per PR and radio incidents, over the
# last N merged PRs. Prints the markdown table docs/context-diet-baseline.md
# records. Run it again after the epic's items land, over the next N, and
# compare.
#
# Reads only local state and the forge, never writes:
#   - Claude Code transcripts, $CLAUDE_PROJECTS (default ~/.claude/projects),
#     one directory per working directory with every '/' and '.' a '-'.
#     A worker lives in <repo>-worktrees/<slug>, a reviewer in
#     <repo>-worktrees/review-pr<N>, the PM in the main checkout.
#   - radio's PM mailbox and log under $TASK_FORCE_HOME (default ~/.task-force).
#   - gh, for the merged PRs and the reviewer's verdict comments.
#
# Usage:
#   tools/context-diet-baseline.sh [--count N] [--prs 372,373,...]
#                                  [--repo OWNER/NAME] [--main-root DIR]
#
# --prs pins the window, so a rerun prints the same table; without it the
# window is the last --count (default 10) merged PRs.
#
# Tokens are per API call: input + cache_creation + cache_read + output,
# deduplicated by message id (Claude Code writes one line per content block,
# each carrying the same usage). Starting context is the first main-chain
# call's input + cache_creation + cache_read.

set -euo pipefail

COUNT=10
PRS=""
REPO=""
MAIN_ROOT=""
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
TF_HOME="${TASK_FORCE_HOME:-$HOME/.task-force}"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --prs) PRS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --main-root) MAIN_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "context-diet-baseline: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for bin in gh jq git; do
  command -v "$bin" >/dev/null || { echo "context-diet-baseline: needs $bin on PATH" >&2; exit 1; }
done

if [[ -z "$MAIN_ROOT" ]]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  MAIN_ROOT=$(dirname "$common")
fi
REPO_NAME=$(basename "$MAIN_ROOT")
WORKTREE_BASE="$(dirname "$MAIN_ROOT")/${REPO_NAME}-worktrees"
[[ -n "$REPO" ]] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# Claude Code's project directory for a working directory.
project_dir() { printf '%s/%s' "$CLAUDE_PROJECTS" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }

# One TSV line per top-level session in a project directory:
#   role  total_tokens  start_context  first_ts  incidents
# role is the slash command the session was started with (planner, worker,
# reviewer, pm), else "-". Tokens include the session's subagent transcripts.
# incidents counts `radio send` calls whose outcome line is a WARNING (no
# session, looks dead) or a failed wake; a command that only mentions
# `radio send` (a commit body, a grep of bin/radio) does not count.
session_rows() {
  local dir=$1 f sid
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.jsonl; do
    [[ -e "$f" ]] || continue
    sid=$(basename "$f" .jsonl)
    local subs=()
    [[ -d "$dir/$sid/subagents" ]] && while IFS= read -r s; do subs+=("$s"); done \
      < <(find "$dir/$sid/subagents" -name '*.jsonl' -type f)
    {
      jq -c --arg main 1 '. + {_main: $main}' "$f"
      [[ ${#subs[@]} -eq 0 ]] || jq -c '. + {_main: "0"}' "${subs[@]}"
    } | jq -rs '
      def tok: (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
             + (.cache_read_input_tokens // 0);
      def text: if type == "string" then .
                elif type == "array" then map(.text? // (.content? | if type == "string" then . elif type == "array" then (map(.text? // "") | join("")) else "" end)) | join("")
                else "" end;
      (map(select(.type == "assistant" and .message.usage != null and .message.id != null
                     and .message.model != "<synthetic>"))
        | unique_by(.message.id)) as $calls
      | ([.[] | select(._main == "1" and .type == "user") | .message.content | text
          | scan("<command-name>/(pm|planner|worker|reviewer)</command-name>")[0]] | first // "-") as $role
      | ($calls | map(.message.usage | tok + (.output_tokens // 0)) | add // 0) as $total
      | ($calls | map(select(._main == "1" and (.isSidechain | not))) | sort_by(.timestamp) | first) as $first
      | ([.[] | select(._main == "1") | .message.content? | arrays | .[]
          | select(.type == "tool_use" and ((.input.command? // "") | tostring | split("\n") | (first // "")
                   | test("^(cd [^;&]*[;&]+ *)?radio send "))) | .id]) as $sends
      | ([.[] | select(._main == "1") | .message.content? | arrays | .[]
          | select(.type == "tool_result" and (.tool_use_id as $i | $sends | index($i)))
          | .content | text | select(test("(^|\n)radio: (WARNING|queued .*wake failed)"))] | length) as $inc
      | [$role, $total, ($first.message.usage | tok // 0), ($first.timestamp // "-"), $inc] | @tsv'
  done
}

# Sum a column of session_rows output, optionally only for one role.
sum_col() { awk -F'\t' -v c="$1" -v r="${2:-}" 'r == "" || $1 == r { s += $c } END { print s + 0 }'; }
# Earliest session's start context for a role ("" = any role).
start_ctx() { awk -F'\t' -v r="${1:-}" '(r == "" || $1 == r) && $4 != "-" { print $4 "\t" $3 }' | sort | head -1 | cut -f2; }

fmt_k() { awk -v n="${1:-}" 'BEGIN { if (n == "" || n == 0) print "–"; else if (n >= 1e6) printf "%.1fM\n", n / 1e6; else printf "%.1fK\n", n / 1e3 }'; }

median() { sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) print ""; else if (NR % 2) print a[(NR + 1) / 2]; else print int((a[NR / 2] + a[NR / 2 + 1]) / 2) }'; }

# ---- the window -------------------------------------------------------------
fields=number,headRefName,createdAt,mergedAt,closingIssuesReferences
if [[ -n "$PRS" ]]; then
  pr_json=$(for n in ${PRS//,/ }; do gh pr view "$n" --repo "$REPO" --json "$fields"; done | jq -s .)
else
  pr_json=$(gh pr list --repo "$REPO" --state merged --limit $((COUNT * 3)) --json "$fields")
fi
pr_json=$(jq --argjson n "$COUNT" --arg pinned "$PRS" \
  'sort_by(.mergedAt) | reverse | if $pinned == "" then .[:$n] else . end' <<<"$pr_json")
[[ $(jq length <<<"$pr_json") -gt 0 ]] || { echo "context-diet-baseline: no merged PRs in $REPO" >&2; exit 1; }

win_start=$(jq -r 'map(.createdAt) | min' <<<"$pr_json")
win_end=$(jq -r 'map(.mergedAt) | max' <<<"$pr_json")
pr_list=$(jq -r 'sort_by(.number) | map(.number | tostring) | join(",")' <<<"$pr_json")

PM_MAIL="$TF_HOME/radio/mailbox/pm-$REPO_NAME/processed"
RADIO_LOG="$TF_HOME/radio/log"

# Worker -> PM review beats for a PR in radio's processed PM mailbox:
# "<review-requested>\t<re-review-requested>". gc expires processed/ after
# 14 days, so this sees a window only while it is recent.
review_beats() {
  local pr=$1 req=0 rereq=0 f intent
  if [[ -d "$PM_MAIL" ]]; then
    for f in "$PM_MAIL"/*-from-worker-*.md; do
      [[ -e "$f" ]] || continue
      grep -qx "pr: $pr" "$f" || continue
      intent=$(sed -n 's/^intent: //p' "$f" | head -1)
      case "$intent" in
        review-requested) req=$((req + 1)) ;;
        re-review-requested) rereq=$((rereq + 1)) ;;
      esac
    done
  fi
  printf '%s\t%s\n' "$req" "$rereq"
}

# Reviewer verdicts posted on the PR (durable, unlike the mailbox).
verdicts() {
  gh pr view "$1" --repo "$REPO" --json comments \
    --jq '[.comments[] | select(.body | test("reviewed [0-9a-f]{40}"))] | length'
}

# ---- per issue --------------------------------------------------------------
echo "## Tokens per issue and review beats"
echo
echo "Window: PRs $pr_list, ${win_start%T*} to ${win_end%T*} ($REPO)."
echo
echo "| Issue | PR | Merged | Worker | Reviewer | Planner | Total | Worker start | Reviewer start | Review req / re-req | Verdicts | Incidents |"
echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

all_rows=""
tot_sum=0
while IFS=$'\t' read -r pr head merged issues; do
  slug=${head#task/}
  wrows=$(session_rows "$(project_dir "$WORKTREE_BASE/$slug")")
  rrows=$(session_rows "$(project_dir "$WORKTREE_BASE/review-pr$pr")")
  # In a worker's worktree, a session started with /planner is the planner's
  # (task-work --plan); every other session there is the worker's.
  planner_tok=$(sum_col 2 planner <<<"$wrows")
  worker_tok=$(( $(sum_col 2 <<<"$wrows") - planner_tok ))
  reviewer_tok=$(sum_col 2 <<<"$rrows")
  total=$((worker_tok + reviewer_tok + planner_tok))
  tot_sum=$((tot_sum + total))
  wstart=$(grep -v '^planner' <<<"$wrows" | start_ctx || true)
  rstart=$(start_ctx <<<"$rrows" || true)
  incidents=$(( $(sum_col 5 <<<"$wrows") + $(sum_col 5 <<<"$rrows") ))
  IFS=$'\t' read -r req rereq < <(review_beats "$pr")
  all_rows+="$(awk -F'\t' -v OFS='\t' 'NF { if ($1 != "planner") $1 = "worker"; print }' <<<"$wrows")"$'\n'
  all_rows+="$(awk -F'\t' -v OFS='\t' 'NF { $1 = "reviewer"; print }' <<<"$rrows")"$'\n'
  printf '| %s | #%s | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %s |\n' \
    "${issues:-–}" "$pr" "${merged%T*}" "$(fmt_k "$worker_tok")" "$(fmt_k "$reviewer_tok")" \
    "$(fmt_k "$planner_tok")" "$(fmt_k "$total")" "$(fmt_k "$wstart")" "$(fmt_k "$rstart")" \
    "$req" "$rereq" "$(verdicts "$pr")" "$incidents"
done < <(jq -r '.[] | [.number, .headRefName, .mergedAt, ([.closingIssuesReferences[].number | "#\(.)"] | join(", "))] | @tsv' <<<"$pr_json")

n_prs=$(jq length <<<"$pr_json")
echo
echo "Mean tokens per issue: $(fmt_k $((tot_sum / n_prs))) over $n_prs PRs."

# ---- starting context per role ----------------------------------------------
echo
echo "## Starting context per role"
echo
echo "| Role | Sessions | Median | Min | Max |"
echo "|---|---:|---:|---:|---:|"
role_line() {
  local role=$1 vals
  vals=$(cat)
  if [[ -z "$vals" ]]; then
    printf '| %s | 0 | – | – | – |\n' "$role"
    return
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$role" "$(wc -l <<<"$vals" | tr -d ' ')" \
    "$(fmt_k "$(median <<<"$vals")")" "$(fmt_k "$(sort -n <<<"$vals" | head -1)")" \
    "$(fmt_k "$(sort -n <<<"$vals" | tail -1)")"
}
# The PM's sessions live in the main checkout: those started inside the window,
# else the last one started before its end.
pm_rows=$(session_rows "$(project_dir "$MAIN_ROOT")" | awk -F'\t' '$1 == "pm"')
pm_in=$(awk -F'\t' -v s="$win_start" -v e="$win_end" '$4 >= s && $4 <= e' <<<"$pm_rows")
[[ -n "$pm_in" ]] || pm_in=$(awk -F'\t' -v e="$win_end" '$4 <= e' <<<"$pm_rows" | sort -t$'\t' -k4 | tail -1)
awk -F'\t' 'NF { print $3 }' <<<"$pm_in" | role_line pm
for role in planner worker reviewer; do
  awk -F'\t' -v r="$role" '$1 == r && $3 > 0 { print $3 }' <<<"$all_rows" | role_line "$role"
done

# ---- radio incidents ----------------------------------------------------------
echo
echo "## Radio incidents"
echo
echo "\`radio send\` results in the window's worker and reviewer transcripts naming WARNING, wake failed or looks dead: $(sum_col 5 <<<"$all_rows")."
if [[ -f "$RADIO_LOG" ]]; then
  log_first=$(head -1 "$RADIO_LOG" | cut -d' ' -f1)
  log_hits=$(awk -v s="$win_start" -v e="$win_end" '$1 >= s && $1 <= e' "$RADIO_LOG" \
    | grep -cE 'WARNING|wake failed|looks dead' || true)
  if [[ "$log_first" > "$win_end" ]]; then
    echo "radio log: starts $log_first, after the window closed (gc rotation keeps only the tail); it cannot see the window."
  elif [[ "$log_first" > "$win_start" ]]; then
    echo "radio log: starts $log_first, after the window opened; it covers only part of the window ($log_hits matching lines)."
  else
    echo "radio log lines in the window naming WARNING, wake failed or looks dead: $log_hits."
  fi
else
  echo "radio log: none at $RADIO_LOG."
fi
