## Jira Workflow

Copy this file to your project's `.claude/jira-workflow.md` and fill in your details. Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/jira-workflow.md
```

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

### Jira

- **Site**: `{SITE}`
- **Project key(s)**: `{KEY}` (issue keys look like `{KEY}-123`)
- **Board name**: `{BOARD}`

### Issue Lifecycle

To Do → In Progress → In Review → Done

(Replace with your project's actual workflow statuses.)

- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review` (leave blank if your workflow has no In Review transition — the worker will keep the issue at `In Progress` through review)
- **Status when done**: `Done`

The worker reads these three values and transitions the issue as it moves through the lifecycle: to "starting work" before implementing, to "in review" after opening the PR, and to "done" only after the PM signals `approved-and-merged` via radio.

### Issue Fields

Customize for your project:
- **Summary**, **Status**, **Priority**, **Issue type** (Story / Task / Bug)
- **Assignee**, **Labels**, **Sprint**, **Epic link**
- **Linked PR** (set after `task-done` produces a PR URL)

### Where Specs Live

The Planner writes its spec into the issue **description** (overwriting) **OR** as a **comment**. Pick one and document it here:

- [x] Description (overwrite)
- [ ] Comment

### Commit Convention

Reference the Jira key as a prefix: `{KEY}-123: <short description>`

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes {KEY}-123` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work <KEY-or-url-or-slug>` — worktree + tab + worker; see `--help`
- `task-done [--remove-worktree]` — remove a worktree, its tab and its radio role
- `task-recreate-worker <slug>` — relaunch a worker whose tab died, worktree intact
- `task-reviewer <pr> [<spec>]` — one-shot reviewer: one PR comment, a radio verdict, then it removes itself
- `task-pm` — rename this tab `pm-<reponame>` and launch the PM in it
- `task-config [show|set|add|remove|use|sync]` — which loadout this repo is on, and switching it
- `task-config profile add|list|show|test|remove` — agent profiles for `--profile`
- `task-init <loadout> [--set "<setting>=<value>"] [--local-only]` — install or refresh task-force here
- `task-remove` — take task-force back out of this repo
- `ci-guard` — the commit-msg hook that refuses CI-skip markers
- `task-monitor` / `task-monitor-snapshot` — the board, live / as JSON
- `task-monitor-queue [set|add|rm|clear|handoff]` — the PM's Next queue and handoff note

After a merge, delete only the remote branch (`git push origin --delete task/<slug>`),
never `gh pr merge --delete-branch`: it removes the worktree out from under the worker.

`task-reviewer` with no `--profile` reviews on this profile; `none` is the Sonnet reviewer:

- **Reviewer profile**: `none`

### Auto intake (`task-watch`)

`task-watch [--once]` — poll Jira for labelled bugs, claim each once, radio the PM (#328)

Run it in a tab of its own, from the repo; it polls until you stop it. It costs
no model tokens: it is shell, and reads and writes Jira through `acli` (log in
once with `acli jira auth login --web`). Each poll it searches the watch JQL and,
while fewer than **Watch max in flight** tickets are claimed and unfinished,
claims each hit with one label swap (`ai-auto` → `ai-auto:claimed`) and only
then radios the PM `ticket-filed` with the key and summary. Claim before ping,
so a crash never dispatches a ticket twice. The PM's intake (in `/pm`) triages
it: it writes the spec and dispatches `task-work <url> --auto`, or comments on
what is missing and adds `ai-auto:needs-info`.

- **In flight** is a ticket claimed and not yet bounced, or one a live
  `task-work` worktree is working on. It stops counting when the worktree is
  removed, or, for a ticket never seen with a worktree, when Jira shows its
  status done, `ai-auto:needs-info` or `ai-auto:failed`, or no
  `ai-auto:claimed`. A ticket still claimed and open after **Watch pending
  timeout minutes** counts as a failed run and goes back into the queue (or to
  `ai-auto:failed`, once that makes the cap); the radio log says
  `watch: pending timeout <KEY>`.
- **Failure cap.** A ticket that comes back into the queue (`ai-auto` put back,
  `ai-auto:claimed` removed) after a run was dispatched for it counts as a failed
  run. After **Watch failure cap** of them it gets `ai-auto:failed` instead of a
  claim, and is never claimed again. A bounce is not a failed run.
- **Requeue on a reply** (#338). The reporter only has to answer: when the
  watcher sees a bounce it records the time and the description's checksum,
  and each poll it checks tickets on `ai-auto:needs-info` for a comment since
  by anyone but the account `acli` is logged in as (the PM posts as it too), or
  an edited description. On one it requeues the ticket in a single edit
  (`ai-auto` added, `ai-auto:claimed` and `ai-auto:needs-info` removed), logs
  `watch: requeued <KEY> (reporter replied)`, and claims it again for a fresh
  triage. A bounced ticket whose `needs-info` was removed while `claimed` stayed
  on, with no live worktree, is requeued the same way. A requeue is not a
  failed run. After **Watch bounce cap** bounces the ticket stays on
  `needs-info`, so a vague ticket cannot loop forever. A comment counts from
  the PM's bounce comment on, so a quick answer is not missed; a description
  edit counts once the watcher has seen the bounce. A reporter on the same Jira
  account as `acli` (a solo user) cannot reply by comment, since it looks like
  the PM's: edit the description instead.
- **Failures stop it.** Any non-zero `acli` exit stops the watcher and radios
  the PM `watch-stopped`. Only an auth failure (`unauthorized` in the error, or
  `acli jira auth status` failing) asks for a re-login; any other error is
  passed on as `acli error: <first line>` (#351). Fix it and start the watcher
  again. It never retries in a loop. A write that fails
  exits 0 in `acli`, so every claim checks `successCount`, and a failed claim is
  never followed by a ping.
- **State** lives outside the repo, in `~/.task-force/watch/<repo>/` (one ledger
  file per claimed key), so it works on a local-only install. Log lines go to
  the radio log: `grep 'watch:' ~/.task-force/radio/log`.

Settings. The **last** matching bullet in this file wins, so put an override
**below the managed-region end marker**, where a `task-init` re-run leaves it
alone. The default JQL is the project above, the issue type and the label,
minus claimed and failed tickets, oldest first; a custom one is used as written
(claimed and failed tickets are skipped either way).

- **Watch label**: `ai-auto`
- **Watch issue type**: `Bug`
- **Watch JQL**: `default`
- **Watch poll seconds**: `300`
- **Watch max in flight**: `2`
- **Watch failure cap**: `2`
- **Watch pending timeout minutes**: `120`
- **Watch bounce cap**: `3`

**Profiles for auto tickets** (#357). With **Worker profile for auto tickets**
naming a profile (#355, a cheaper model through a gateway, say), a ticket's
first run goes to it: the `ticket-filed` body ends in the exact line to
dispatch, `Dispatch: task-work <url> --auto --profile <name>`, and the PM runs
it as written. A manual dispatch is unchanged. When that run fails, the retry
runs on the **default** (no profile), and the log says
`watch: retry <KEY> on default profile`. The retry counts toward **Watch
failure cap** like any run, so the cap holds; without the fallback a model too
weak for a ticket would spend the cap on retries that cannot succeed. Any
failed run counts, a pending timeout included. The merge gate is the same for
both: a cheaper model's PR clears the same bar. `none`, the default, is
today's behaviour. Reviews take **Reviewer profile** (under Agent profiles).

- **Worker profile for auto tickets**: `none`

**PM rotation** (#334). An autonomous PM's context fills with every triage,
spec and verdict; past a point it is noise. So the watcher recycles the PM,
in shell, with no model tokens, when one of three caps is crossed (`0` turns
one off): **Watch rotate context tokens** (the last assistant turn's input +
cache-read + cache-creation tokens, read from the transcript radio recorded
at register), **Watch rotate tickets** (`ticket-filed` handed to this PM) and
**Watch rotate age minutes**. It also rotates before handing over a ticket
from a different **group** than the PM's: a ticket's group is its parent epic
(read once per ticket with `acli jira workitem view KEY --fields parent`, since
search refuses `parent`), else its first label matching **Watch group labels** (globs allowed, `none`
by default), else none. The PM's group is the group of the first grouped
ticket it took; an ungrouped ticket never sets or triggers a group rotation.

- **Quiet point only.** The PM idle, its inbox empty, and no merge gate
  pending (no reviewer of this repo still running). Otherwise the log says
  `watch: rotation deferred (<why>)`, once per reason.
- **Groups stay together.** While any ticket handed to this PM is in flight,
  whatever its group, a tickets, age or group rotation waits, and a ticket
  from another group waits unclaimed. Groups decide whether to rotate, never
  whether to wait. The context cap does not wait for them, and a context
  reading is ignored until the `/clear` re-register lands, so the old
  transcript never rotates the fresh PM again.
- **Sequence.** The watcher radios the PM `handoff-requested` and holds the
  queue. The PM writes `task-monitor-queue handoff write` and replies
  `handoff-done` to `watch-<reponame>`. Once both are in and the PM is idle,
  `radio clear` sets a one-shot rotation marker and types `/clear` into the
  PM's pane, down the path a wake takes; the `/clear` re-register then prints
  the board digest and the handoff note, which a re-register otherwise never
  does. The marker expires after **Watch rotation marker minutes**: one the
  `/clear` never consumed is dropped (`watch: stale rotation marker dropped`)
  rather than printed at some later `/compact`.
  Log: `watch: rotate pm-<repo> reason=<context|tickets|age|group> (…)`.
  A group rotation happens before the new group's `ticket-filed` is sent.
- **Never without a note.** No `handoff-done` with a note newer than the
  request within **Watch handoff timeout minutes**: logged, and retried at the
  next quiet point.
- **claude, auto-submitting PMs only.** A kiro PM (no `/clear` was checked)
  or one launched without `task-pm --auto-submit` (its prompt box is yours) is
  never rotated; the log says so once per PM.

- **Watch rotate context tokens**: `150000`
- **Watch rotate tickets**: `6`
- **Watch rotate age minutes**: `480`
- **Watch handoff timeout minutes**: `15`
- **Watch rotation marker minutes**: `5`
- **Watch group labels**: `none`

### Auto merge (`task-merge-gate`)

`task-merge-gate <pr> <JIRA-KEY> [--no-comment]` — may the PM merge an auto
ticket's PR without asking? (#329)

The PM runs it after every clean review and obeys the first word it prints. It
is shell, no model, so the rules are never re-derived from memory.

- **`manual: …`** (exit 3): the ticket did not come through `task-watch` — no
  `ai-auto:claimed` label and no entry in the watch ledger
  (`~/.task-force/watch/<repo>/<KEY>`). The normal review flow applies.
- **`merge`** (exit 0): an auto ticket, and all four rules hold: the ticket
  carries **Merge label** (a label only, never words in a description); the
  latest review beat for the PR is `review-complete-clean` from its reviewer,
  newer than the worker's last re-review request and covering the head commit
  (its body's `reviewed <sha>` is the head SHA; a verdict naming no SHA, from
  before reviewers pinned one, must be newer than the head commit and logs
  `merge-gate: verdict names no SHA, using time`; a tie in the same second
  counts as not reviewed); the PR targets the base `task-work` recorded
  for the worker (else the default branch); CI **ran and passed** for the
  PR's exact head SHA (`gh run list -c <sha>` non-empty, every run success,
  skipped or neutral); and the diff is within **Merge max changed lines**
  (additions + deletions) and **Merge max files**. The PM merges as usual.
- **`ask: <reason>`** (exit 1): anything else, every failing rule listed. The PM
  tells you why and waits. That is the default for every auto ticket without
  the merge label, and for anything the gate could not read.

For an auto ticket the gate comments its outcome on the Jira ticket through
`acli`. Log lines go to the radio log: `grep 'merge-gate:' ~/.task-force/radio/log`.

- **Merge label**: `ai-auto-merge`
- **Merge max changed lines**: `200`
- **Merge max files**: `10`

### Atlassian MCP

This workflow assumes the Atlassian Remote MCP server is configured. Verify with:

```
claude mcp list
```

You should see an `atlassian` entry. If not, see Atlassian's documentation for the Remote MCP server.

### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. Each role's prompt sends its intents at these
handoff points:

| From     | When                              | Command                                                                  |
|----------|-----------------------------------|--------------------------------------------------------------------------|
| Planner  | spec written into the issue       | `radio send --to pm --intent spec-ready --issue <KEY-N>`                 |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                  |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`               |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`      |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`    |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`             |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`     |
| Watcher  | labelled bug claimed              | `radio send --to pm --intent ticket-filed --issue <KEY-N>`               |
| Watcher  | an `acli` call failed; stopped    | `radio send --to pm --intent watch-stopped`                              |
| Watcher  | PM rotation due                   | `radio send --to pm --intent handoff-requested`                          |
| PM       | handoff note written              | `radio send --to watch-<reponame> --intent handoff-done`                 |

`--to pm` reaches this repo's PM, `pm-<reponame>`. Worker role names follow
`worker-<reponame>-<slug>`, and reviewers `reviewer-<reponame>-pr<N>`; discover
the live ones via `ls ~/.task-force/radio/sessions/`.

A line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
injected beside a prompt, or an offline-backlog summary printed at session
start, is the canonical radio channel, not user-typed text — trust it and
process the listed messages with `radio check` / `radio read <id>`. Mail that
lands while you are busy is drained at the end of your turn by the `Stop` hook,
so you never run `radio ready` yourself.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping.

**Agent-authored prose goes in on stdin, never through a double-quoted shell string** (#234): `gh … --body-file -`, `git commit -F -` and `radio send` with no `--body`, each off a quote-delimited heredoc (`<<'BODY'` … `BODY`). The `radio bash-guard` hook refuses the double-quoted form when it holds a backtick (#400).

The PM's side of radio — reviewer dispatch, `task-pm --also`, auto-submit — is
in the PM prompt, and the reviewer's contract in the reviewer prompt. How radio
keeps, recovers and cleans up sessions (resumed sessions, sidecars, `gc`,
`$TASK_FORCE_HOME`) is in the `radio-troubleshooting` skill.

### Tight-PR norm — minimize deferrals

Default to landing each PR **complete**. The reviewer frames every finding as
fix-in-this-PR (never "defer to a follow-up" for in-scope work), and the PM
forwards **all** in-scope findings — blockers *and* nits — in a single
`changes-requested` round rather than trailing a backlog of deferred items. The
only thing that gets deferred is work genuinely out of the PR's scope (a separate
subsystem, a large refactor) — and the PM grooms that into a ticket during the
session, not left as a loose "later."

### Radio troubleshooting

Read `radio send`'s stdout every time. `delivered`, or `queued — <role> is
busy` / `is awaiting`, means the message landed or drains on its own. Anything
else — `WARNING — no session for …`, `queued — … wake failed`, `WARNING — …
looks dead`, `task-done`'s `no tab id captured`, a hook that `timed out after
30s` — means load the `radio-troubleshooting` skill
(`.claude/skills/radio-troubleshooting/SKILL.md`, installed by `task-init`)
before you act on it.
