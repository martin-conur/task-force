# Assembles one repo object of the task-monitor snapshot (#273). Run by
# bin/task-monitor-snapshot with `jq -n -f`; see that file for the inputs, and
# docs/task-monitor-schema.md for the output.
#
# Everything here is a join over data bin/task-monitor-snapshot already read:
# no I/O, no forge, so --local and full runs assemble identically.

def nonempty: if . == null or . == "" then null else . end;

# A PR title with the item's label in front of it (#299). On jira the commit
# and PR-title convention is `<KEY>: …`, and the board prints the label before
# the title, so the row would read `ML-450 ML-450: …`. Drop a leading
# `ML-450`, `[ML-450]` or `ml-450` and the `:` / `-` / `—` / space after it.
# Only a whole label counts (`ML-4500` is not `ML-450`), and a title that is
# nothing but the label stays as it is. Not `$label`: jq 1.6 reserves it.
def strip_label($lbl):
  if . == null or $lbl == null or $lbl == "" then . else
    (ascii_downcase) as $t | ($lbl | ascii_downcase) as $l
    | (if ($t | startswith("[" + $l + "]")) then .[($l | length) + 2:]
       elif ($t | startswith($l)) then .[($l | length):] | (if . == "" or test("^[\\s:—-]") then . else null end)
       else null end) as $rest
    | if $rest == null then . else
        ($rest | sub("^[\\s:—-]+"; "")) as $r | if $r == "" then . else $r end
      end
  end;

# Whether a radio role belongs to repo <r>. Role names are task-force's own:
# pm-<repo>, worker-<repo>-<slug>, reviewer-<repo>-pr<N>.
def role_of($r):
  . == ("pm-" + $r)
  or startswith("worker-" + $r + "-")
  or startswith("reviewer-" + $r + "-");

# The intents that move a PR through review, and the subset that settles a
# review: a review-complete-* is waiting on the PM until one of the PM's own
# answers follows it.
def review_intents:
  ["review-requested", "re-review-requested", "changes-requested",
   "review-complete-clean", "review-complete-with-findings", "approved-and-merged"];
def decision_intents:
  ["review-complete-clean", "review-complete-with-findings", "changes-requested", "approved-and-merged"];
def among($set): . as $x | $set | index([$x]) != null;

def session_obj($S; $role):
  $S[$role] as $s
  | if $s == null then null else
      {role: $role, state: ($s.STATE | nonempty), last_heartbeat: ($s.LAST_HEARTBEAT | nonempty),
       tab: ($s.TAB | nonempty), tab_id: ($s.TAB_ID | nonempty),
       zellij_session: ($s.ZELLIJ_SESSION | nonempty), agent: ($s.AGENT | nonempty)}
    end;

# Message order. created_at has one-second resolution, and a radio id does NOT
# break the tie: after the timestamp it carries the sender and a random suffix,
# so two messages sent in the same second sort by chance. `seq` is the message's
# position among the radio log's `send id=` lines, which radio appends in send
# order; a message the log no longer holds (it keeps its last ~512KB) sorts
# after any that it does in that second, then by id.
def msg_order: [.created_at, (.seq // 1e18), .id];

# A heartbeat older than `radio orphans`' threshold (1h) means the tab is gone:
# a crashed tab leaves STATE=awaiting behind forever (bin/radio, cmd_send).
def fresh($now): (. // "") as $hb
  | $hb != "" and (($now | fromdateiso8601) - ($hb | fromdateiso8601) < 3600);

def status($pr; $last_review; $has_reviewer):
  if $pr == null then "implementing"
  elif $pr.state == "MERGED" then "merged"
  elif $pr.state == "CLOSED" then "closed"
  else ($last_review.intent // null) as $i
    | if $i == null or $i == "review-requested" then
        (if $has_reviewer then "under-review" else "pr-open" end)
      elif $i == "re-review-requested" then "re-review"
      elif $i == "changes-requested" then "changes-requested"
      elif ($i | startswith("review-complete-")) then "waiting-merge"
      elif $i == "approved-and-merged" then "merged"
      else "pr-open" end
  end;

($sessions[0] // {}) as $S
| ("pm-" + $name) as $pm_role
| [$names[] | select(startswith($name + "-"))] as $longer
# The longest repo name wins: `worker-task-force-x` is task-force's, not task's.
| def mine: role_of($name) and ([. as $role | $longer[] as $l | $role | role_of($l)] | any | not);

[$messages[] | select(((.from // "") | mine) or ((.to // "") | mine))]
  | sort_by(msg_order) as $msgs

# Is PR <n> (a string) still open? Only the forge can say. With no answer yet —
# a repo whose first full run has not happened — nothing counts as open: every
# review a mailbox still remembers would otherwise light the repo up at once,
# and a light that fires for anything but a real signal is #272's anti-goal.
| def pr_open($n):
    $open_prs != null and ([$open_prs[] | .number | tostring] | index([$n]) != null);

# Reviewers, from their sidecars and their sessions alike: a reviewer whose
# session is gone but whose worktree remains is still attached, and vice versa.
( [ ($reviewer_infos[] | .pr),
    ($S | keys[] | select(startswith("reviewer-" + $name + "-pr")) | select(mine)
        | ltrimstr("reviewer-" + $name + "-pr")) ]
  | unique
  # `pr` is a number in the document (#307); the string `$n` stays the key a
  # reviewer is matched to its item by, against `$prn` below.
  | map(. as $n | ("reviewer-" + $name + "-pr" + $n) as $role
        | {key: $n, pr: ($n | tonumber? // null), role: $role, session: session_obj($S; $role)}) ) as $reviewers

| [ $inflight[]
    | ("worker-" + $name + "-" + .slug) as $wrole
    | .item.label as $item_label
    # No PR found by head branch: fall back to the PR the worker named in its
    # own review-requested, so a renamed branch still shows its review state.
    | (.pr // ([$msgs[] | select(.from == $wrole and .pr != null)] | last
               | if . == null then null else
                   {number: (.pr | tonumber? // null), url: null, title: null, state: null,
                    is_draft: false, head: null, summary: null, merged_at: null, merge_sha: null}
                 end)) as $pr
    | ($pr.number | if . == null then null else tostring end) as $prn
    | [$reviewers[] | select(.key == $prn) | del(.key)] as $revs
    | ([$msgs[] | select($prn != null and .pr == $prn) | select(.intent | among(review_intents))] | last) as $last_review
    | ([$msgs[] | select(.from == $wrole or .to == $wrole or ($prn != null and .pr == $prn))] | last) as $last
    | { slug, ref, branch, base, worktree,
        label: .item.label, number: .item.number, url: .item.url,
        title: (if ($pr.title // null) != null then ($pr.title | strip_label($item_label)) else .item.title end),
        description: (($pr.summary // null) // .item.description),
        item: .item,
        pr: $pr,
        status: status($pr; $last_review; ($revs | length > 0)),
        last_intent: (if $last == null then null else
                        {intent: $last.intent, from: $last.from, to: $last.to, pr: ($last.pr | tonumber? // null), at: $last.created_at} end),
        session: session_obj($S; $wrole),
        tab_id: .tab_id,
        reviewers: $revs } ] as $in_flight

| ([$in_flight[] | .ref, .item.ref | select(. != null)]) as $if_refs
| ([$in_flight[] | .number | select(. != null)]) as $if_numbers
| ([$in_flight[] | .url | select(. != null)]) as $if_urls
| [ $next[]
    | select((.ref | among($if_refs)) | not)
    | select(.number == null or ((.number | among($if_numbers)) | not))
    | select(.url == null or ((.url | among($if_urls)) | not)) ]
  | (if $next_source == "queue" then . else .[:$next_limit] end) as $next_items

# --- attention: exactly three signals (#272). Nothing else lights a repo.
| ($S[$pm_role].ALIAS | nonempty) as $alias_of
# An alias owns no inbox: radio's alias hop delivers its mail into the
# primary's, and `register-alias` folds in anything that queued before. So the
# primary's own inbox already holds the alias's mail, and the alias repo
# reports 0 with alias_of set — that is the whole of "--also counts toward the
# primary".
| (if $alias_of != null then 0 else
     [$messages[] | select(.box == "inbox" and .mailbox == $pm_role)] | length
   end) as $unread
| ([$msgs[] | select(.pr != null) | select(.intent | among(decision_intents))]
   | group_by(.pr)
   | map(sort_by(msg_order) | last)
   | map(select(.intent | startswith("review-complete-")) | .pr)
   | map(select(pr_open(.)))) as $waiting_prs
| ([$S | to_entries[]
    | select(.key | startswith("worker-")) | select(.key | mine)
    | select(.value.STATE == "awaiting" and (.value.LAST_HEARTBEAT | fresh($now)))
    | {role: .key, slug: (.key | ltrimstr("worker-" + $name + "-")),
       last_heartbeat: (.value.LAST_HEARTBEAT | nonempty)}]) as $awaiting
| ( (if $unread > 0 then [{kind: "unread-inbox", count: $unread, text: "✉ \($unread) unread"}] else [] end)
  + (if ($waiting_prs | length) > 0 then
       [{kind: "review-waiting-merge", prs: ($waiting_prs | map(tonumber? // empty)),
         text: "\($waiting_prs | length) review\(if ($waiting_prs | length) > 1 then "s" else "" end) waiting merge"}]
     else [] end)
  + (if ($awaiting | length) > 0 then
       [{kind: "worker-awaiting", workers: $awaiting,
         text: "❓ \($awaiting | map(.slug) | join(", ")) \(if ($awaiting | length) > 1 then "are" else "is" end) asking"}]
     else [] end) ) as $signals

| {
    name: $name,
    root: $root,
    # Where task-work puts this repo's worktrees and their `.<slug>.info`
    # sidecars, so the front end can watch for a new one without re-deriving
    # task-work's path rule.
    worktree_base: $worktree_base,
    loadout: ($impl | nonempty),
    tracker: ($tracker | nonempty),
    agent: ($agent | nonempty),
    pm: ((session_obj($S; $pm_role) // {role: $pm_role, state: null, last_heartbeat: null, tab: null,
                                       tab_id: null, zellij_session: null, agent: null})
         + {alias_of: $alias_of, unread: $unread}),
    # `available`: the forge has answered for this repo at least once. A repo
    # with no GitHub remote never has, and would otherwise read as permanently
    # stale; `stale` is only meaningful for a repo whose forge does answer.
    forge: {available: (($fetched_at | nonempty) != null),
            fetched_at: ($fetched_at | nonempty),
            stale: (($fetched_at | nonempty) != null and $forge_ok != 1)},
    in_flight: $in_flight,
    # Sidecars whose worktree is gone (#286): never in flight, listed so a
    # cleanup can act on them.
    orphans: $orphans,
    next: {source: (if ($next_items | length) == 0 then "none" else $next_source end), items: $next_items},
    done: {window_hours: 24, min_items: 10,
           items: [$done_items[] | .label as $l | .title |= strip_label($l)]},
    attention: {active: ($signals | length > 0), signals: $signals},
    # The previous PM's note (#301), written by `task-monitor-queue handoff
    # write` and kept until the next one replaces it.
    handoff: ($handoff[0] // null)
  }
