# The board digest a fresh PM start prints (#301): the first repo of a
# task-monitor snapshot (docs/task-monitor-schema.md) as plain text lines.
#
# Input: one snapshot document, and `--arg part board|handoff`. Output: raw
# lines, uncapped; tm_board_digest in lib/monitor-text.sh caps them. Attention
# comes first and Done last, so a cap cuts the oldest news, never the signal. Every value is a snapshot field:
# nothing here derives task-force state of its own.

def age($t; $now):
  if $t == null then null
  else (($now | fromdateiso8601) - ($t | fromdateiso8601)) as $s
  | if $s < 60 then "\($s | floor)s"
    elif $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h"
    else "\($s / 86400 | floor)d" end
  end;

def item_label: .label // .ref // "?";

# Lines are capped in number by the caller and in width here: a title or a
# summary sentence past <n> characters ends in an ellipsis.
def clip($n): if length > $n then .[0:$n - 1] + "…" else . end;

# The words task-monitor shows for a collector `status` (ui.rs status_words).
def status_words:
  {"implementing": "implementing", "pr-open": "open", "under-review": "under review",
   "changes-requested": "changes requested", "re-review": "re-review requested",
   "waiting-merge": "reviewed, waiting merge", "merged": "merged, not cleaned up",
   "closed": "closed unmerged"}[. // ""] // (. // "?");

def first_sentence:
  if . == null or . == "" then null
  else (capture("^(?<s>.*?[.!?])(\\s|$)") // {s: .}).s end;

.generated_at as $now
| .repos[0] as $r
| if $r == null then empty
  elif $part == "handoff" then
    # The previous PM's note (task-monitor-queue handoff write), with its age.
    ($r.handoff // empty)
    | "[handoff] Note from the previous PM"
      + ([.agent, .role] | map(select(. != null and . != "")) | if length > 0 then " (\(join(", ")))" else "" end)
      + (if .written_at then ", written \(age(.written_at; $now)) ago (\(.written_at))" else "" end) + ":",
      (.text | split("\n")[] | if . == "" then "" else "  " + . end)
  else
  "[board] \($r.name): what task-monitor knows, read from disk with no forge call"
    + (if $r.forge.fetched_at then " (PR state as of \(age($r.forge.fetched_at; $now)) ago)"
       else " (the forge has not been asked yet)" end) + ".",
    (if $r.attention.active then
       "Attention: " + ([$r.attention.signals[].text] | join(" · "))
     else empty end),
    (if ($r.in_flight | length) > 0 then
       "In flight (\($r.in_flight | length)):",
       ($r.in_flight[]
        | "  \(item_label) \(.title // .slug // "" | clip(90))"
          + (if .pr then " (PR #\(.pr.number // "?")\(if .pr.is_draft then ", draft" else "" end))" else "" end)
          + ": \(.status | status_words)")
     else "In flight: nothing." end),
    (if ($r.next.items | length) > 0 then
       "Next (\(if $r.next.source == "queue" then "PM queue" else "tracker backlog" end)):",
       ($r.next.items | to_entries[]
        | "  \(.key + 1). \(.value | item_label) \(.value.title // "" | clip(90))"
          + (if .value.note then ": \(.value.note | clip(120))" else "" end))
     else "Next: nothing queued." end),
    (if ($r.done.items | length) > 0 then
       "Done (the last \($r.done.window_hours // 24)h, or the last \($r.done.min_items // 10) if that is more):",
       ($r.done.items[]
        | "  \(item_label) \(.title // "" | clip(90))"
          + (if .pr.number then " (PR #\(.pr.number))" else "" end)
          + ((.description // .summary | first_sentence) as $s | if $s then ": \($s | clip(160))" else "" end))
     else "Done: nothing merged recently." end)
  end
