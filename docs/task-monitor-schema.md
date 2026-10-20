# task-monitor snapshot schema (version 1)

`task-monitor-snapshot --json` prints one JSON document describing what is in
flight, next and done in a repo, plus the attention signals that say whether the
repo needs you (#273, epic #272). It is the contract between the bash collector
and the ratatui front end. A full example, taken from this repo, is in
[`task-monitor-schema.example.json`](task-monitor-schema.example.json).

Every value is read deterministically: from radio's on-disk state, task-work's
worktree sidecars, the tracker, and the forge (`gh`). Nothing is written or
summarised by a model.

```
task-monitor-snapshot [--json] [--all] [--local] [--repo DIR]
```

| flag | effect |
|---|---|
| `--json` | the output format. It is the only one, and the flag is accepted for clarity |
| `--all` | every repo a radio session file names (`REPO=`, resolved to its main checkout), plus the current one |
| `--local` | no forge calls. Reads disk only and merges with the last full run's cache |
| `--repo DIR` | describe the repo containing `DIR` instead of `$PWD` |

It exits non-zero only on bad arguments, outside a repo without `--all`, or when
every repo failed. A failure in one repo leaves that repo out and says so on
stderr. The front end keeps its last good snapshot on a non-zero exit.

## Compatibility

`schema` is bumped only for a change that breaks a reader: a field removed,
renamed or retyped. New fields can appear within version 1, so a reader must
ignore fields it does not know.

## Top level

| field | type | meaning |
|---|---|---|
| `schema` | number | `1` |
| `generated_at` | ISO-8601 UTC | when this document was produced |
| `mode` | `"full"` \| `"local"` | `local` when run with `--local` |
| `repos` | array of repo | the current repo first, then the others by path |

## Repo

| field | type | meaning |
|---|---|---|
| `name` | string | the main repo's name, sanitized to radio's role charset (`task-force`) |
| `root` | path | the main checkout |
| `loadout` | string \| null | `claude-gh` …, from the repo's one workflow doc, else from its PM session's `LOADOUT=` |
| `tracker`, `agent` | string \| null | the loadout's two halves |
| `pm` | object | the PM session (see below) |
| `forge` | object | `fetched_at`: the last time the forge answered, or null. `stale`: true when this run did not hear from the forge (always under `--local`) and shows the last result instead |
| `in_flight` | array | one entry per worktree sidecar |
| `next` | object | `source` (`queue` \| `tracker` \| `none`) and `items` |
| `done` | object | `window_hours` (24), `min_items` (10) and `items` |
| `attention` | object | `active` and `signals` |

### `pm`

`role`, `state` (`idle` \| `busy` \| `awaiting` \| null), `since` (the session's
`LAST_HEARTBEAT`, which every state change rewrites), `tab`, `tab_id`,
`zellij_session`, `agent`: all from `radio/sessions/pm-<name>.info`, null when
there is no session. Then:

- `alias_of`: the primary PM's role when this repo's PM is a `task-pm --also`
  alias, else null.
- `unread`: messages in the PM's `inbox/`. An alias's inbox counts toward its
  primary, so an aliased repo reports `0`.

### Item fields

Every item has these, whatever the tracker, so the front end never has to ask
which tracker made it:

| field | meaning |
|---|---|
| `ref` | what the tracker names the item by: an issue URL or number, a Jira key, a Notion URL, a task file |
| `label` | what a list shows: `#267`, `PROJ-42`, a local task id. Null when there is nothing short |
| `number` | the issue number or numeric task id, else null |
| `title` | one line |
| `description` | one plain paragraph, or null |
| `url` | what `o` opens, or null |

How `title` and `description` are found:

| | gh / local | jira / notion |
|---|---|---|
| before a PR exists | issue title and the first prose paragraph of the body (gh via `gh issue view`; local from the `tasks/` file's frontmatter `title` and body) | the ref and the worker slug, `PROJ-42 · kiro-config`. The shell cannot read these trackers |
| once a PR exists | the PR title, and its `## Summary` | the same |

The "first prose paragraph" skips headings, HTML comments, fences and rules. A
list item starts a paragraph of its own. A PR with no `## Summary` uses the
first paragraph after its `Closes #N` line, then its first paragraph.

### `in_flight[]`

An item is in flight while its `<worktree-base>/.<slug>.info` sidecar exists.
A fresh heartbeat is not required, so a resumed or roleless session is still in
flight. Reviewer sidecars (`PR_NUMBER=`) are not items; they attach to the item
whose PR they review.

The item fields above, plus:

| field | meaning |
|---|---|
| `slug`, `branch`, `base`, `worktree`, `tab_id` | from the sidecar; `branch` is `task/<slug>` |
| `item` | the tracker's own item object, before any PR overrides `title` / `description` |
| `pr` | `{number, url, title, state, is_draft, head, summary, merged_at, merge_sha}`, found by the `task/<slug>` head branch on every tracker, else null. If no PR has that head, the PR the worker named in its own radio messages is used |
| `status` | see below |
| `last_intent` | the latest radio message to or from this worker, or about its PR: `{intent, from, to, pr, at}` |
| `session` | the worker's radio session: `{role, state, since, tab, tab_id, zellij_session, agent}`, or null |
| `reviewers` | `[{pr, role, session}]` |

`status` comes from the PR's state plus the latest review intent exchanged about
that PR:

| status | when |
|---|---|
| `implementing` | no PR yet |
| `pr-open` | a PR, and no review intent yet (or only `review-requested`) |
| `under-review` | as `pr-open`, with a reviewer attached |
| `changes-requested` | the PM's last word was `changes-requested` |
| `re-review` | the worker's last word was `re-review-requested` |
| `waiting-merge` | a `review-complete-*` is the latest |
| `merged` | the PR is merged, or the PM sent `approved-and-merged`. The worktree has not been cleaned up yet |
| `closed` | the PR was closed unmerged |

### `next`

`items[]` are item objects plus `note` (string or null).

- `source: "queue"`: the PM's queue, in its order. It is read from
  `${TASK_FORCE_HOME}/monitor/<name>/queue`, one ref per line, with an optional
  tab-separated note and `#` comments. The command that writes this file is
  #272's sub-issue 3, which owns the format.
- `source: "tracker"`: the queue is empty, so the tracker's fallback is used.
  - **gh**: open project items whose status is none of the three in the workflow
    doc (starting work, in review, done), compared case-insensitively. They are
    limited to this repo's issues, in the order `gh project item-list` returns,
    top 10.
  - **local**: the `tasks/` backlog by numeric id, skipping `in-progress` and
    `done`.
  - **jira / notion**: there is no fallback, so the source is `none`.
- `source: "none"`: nothing to show.

Items already in flight are left out either way.

### `done`

Merged PRs that deliver an item, newest first. That means the last 24 hours or
the last 10, whichever is more. A PR delivers an item through `Closes #N` (or
`Fixes` / `Resolves`) on gh, and through its `task/<slug>` head branch on every
tracker. Other merged PRs are left out.

The item fields, where `title` is the PR title and `description` its summary,
plus `summary`, `body` (the full PR body, for the expanded view), `pr`
(`{number, url, title, state, is_draft, head, merged_at, merge_sha}`),
`merged_at` and `merge_sha`.

Merged PRs never change, so each is fetched once and cached for good, under
`${TASK_FORCE_HOME}/monitor/<name>/prs/<N>.json`.

### `attention`

Exactly three signals. Nothing else lights a repo.

| `kind` | fires when | extra fields |
|---|---|---|
| `unread-inbox` | the PM's inbox is not empty. `--also` alias inboxes count toward the primary | `count` |
| `review-waiting-merge` | the latest decision about a PR is a `review-complete-clean` or `review-complete-with-findings`, with no later `changes-requested` or `approved-and-merged`, and the forge lists the PR as open | `prs` |
| `worker-awaiting` | a worker session of the repo is in `awaiting`, the state behind the tab's `❓` | `workers: [{role, slug, since}]` |

Each signal has a `text` in words, such as `✉ 2 unread`, `1 review waiting
merge` or `❓ issue-5 is asking`. `active` is true when there is any signal.

A PR counts as open only when the forge says so. A repo with no full run yet
therefore shows no `review-waiting-merge`, rather than lighting up for every
review its mailboxes remember. The review timeline is rebuilt from message
frontmatter (`intent:`, `pr:`) in every mailbox, `processed/` and `dead-letter/`
included. The radio log cannot be used for this, because its `send` lines carry
no `pr=`.

`worker-awaiting` is claude-only for now. Only the claude loadouts wire
`radio awaiting`, and #272's sub-issue 6 looks into a kiro equivalent.

A role belongs to the longest repo name it starts with, so
`worker-task-force-x` is `task-force`'s even when a repo named `task` exists.

## The cache

Everything the forge said is kept in `${TASK_FORCE_HOME}/monitor/<name>/`:

- `forge.json`: the open PR list, the merged-PR index, item descriptions by
  ref, and the Todo fallback. A full run replaces only the parts the forge
  answered.
- `prs/<N>.json`: one per merged PR.

`--local` reads these files and writes nothing. It never calls `gh`: the
collector shadows `gh` with a function that fails, so every forge read takes its
cache path.

## Tracker hooks

Per-tracker behaviour is three hooks in `lib/trackers/`, with `_default.sh`
bodies. `tests/loadout_modules.bats` checks that every hook resolves for every
loadout.

| hook | default | overridden by |
|---|---|---|
| `aw_tracker_item_describe <ref> <slug> <root>` | `ref · slug` | gh (`gh issue view`), local (the task file), jira (a browse URL shortened to its key) |
| `aw_tracker_pr_item <head> <body>` | the `task/<slug>` head branch | gh (`Closes #N` first), jira (the key in upper case) |
| `aw_tracker_next_fallback <root> <doc> <limit>` | nothing | gh (project items), local (`tasks/`) |

A hook that reaches the forge returns non-zero when the forge does not answer.
That is how the collector tells "nothing to show" from "could not ask". On the
second, it uses the cache.
