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
role transition runs through it. The PM / planner / worker prompts shell out to
`radio send` at every documented handoff point:

| From    | When                            | Command                                                                |
|---------|---------------------------------|------------------------------------------------------------------------|
| Planner | spec written into the issue     | `radio send --to pm --intent spec-ready --issue <KEY-N>`               |
| Worker  | PR opened                       | `radio send --to pm --intent review-requested --pr <N>`                |
| Worker  | new commits pushed after review | `radio send --to pm --intent re-review-requested --pr <N>`             |
| PM      | review requested changes        | `radio send --to <worker-role> --intent changes-requested --pr <N>`    |
| PM      | PR merged                       | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`  |
| Watcher | labelled bug claimed            | `radio send --to pm --intent ticket-filed --issue <KEY-N>`             |
| Watcher | an `acli` call failed; stopped  | `radio send --to pm --intent watch-stopped`                            |
| Watcher | PM rotation due                 | `radio send --to pm --intent handoff-requested`                        |
| PM      | handoff note written            | `radio send --to watch-<reponame> --intent handoff-done`               |

When a worker's turn ends, the `Stop` hook runs `radio stop-hook`
automatically: with an empty inbox it marks the role idle; if messages queued
up while the worker was busy, it blocks the stop (staying busy) so the agent
drains them immediately — you don't need to invoke it manually. A message that
lands *during* that forced drain turn earns one more block of its own (#197):
the hook records the message ids each block was about and compares the inbox
against that set, so a genuinely new arrival still gets a continuation while an
agent that ignores the same ids twice is still allowed to stop. Before this,
the second `Stop` gave up on the flag alone and the new message sat unread —
terminal for an idle auto-submitting worker nobody was going to prompt again.

Likewise, every submitted prompt runs `radio prompt-hook` (the
`UserPromptSubmit` hook): if the inbox has unread messages, a line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
is injected into the agent's context alongside the prompt. That line is the
canonical radio channel, not user-typed text — trust it and process the
listed messages with `radio check` / `radio read <id>`.

Finally, `SessionStart` fires `radio register`; on a *fresh* start (not the
re-registers that `/compact` and `/clear` trigger in the same process) it also
prints a summary of any inbox that queued while the role was offline — reports whose
send-time wake found no session file and no-op'd. `SessionStart` stdout is
injected into the model's context, so that backlog surfaces on the role's very
first turn, not just after the next human prompt: the offline→online companion
to the stop-hook flush (busy case) and prompt-hook injection (idle case). On
that fresh start a repo-scoped `pm-<reponame>` also **adopts** any orphaned
literal-`pm` backlog: post-#165 nothing registers as the bare `pm`, so its
inbox is write-only, and a fresh PM with no live `pm` session migrates those
messages into its own inbox (each stamped with an `adopted-from:` provenance
header) and surfaces them in the same summary, flagged as adopted — a one-time
backfill (#182), and one scoped to **this** repo: a message is adopted only
when its `from:` names this repo — `worker-<reponame>-<slug>`,
`reviewer-<reponame>-pr<N>`, `pm-<reponame>` — so another repo's report stays in
`mailbox/pm/inbox` for its own PM instead of being claimed by whichever PM
booted first, and `radio`'s log records the count left behind. Mail no name can
attribute (`from: unknown`, sent before the role env existed) is still adopted
first-come, and the log says so rather than staying silent (#210). Empty
inbox prints nothing. (This beat works on kiro too — its `agentSpawn` hook is
the same entrypoint, and kiro injects hook stdout as well. The long-standing
claim that it does not came from hooks that were never running at all: they were
written to `.kiro/hooks/`, which kiro-cli does not read. Fixed in #218; what kiro
still lacks — a prompt-hook inbox summary and a Stop drain — is #221.)

A **resumed session registers nothing**, and that is not the hook's fault
(#229). `SessionStart` does fire on a resume — verified against all four
sources, `startup` / `resume` / `compact` / `clear` — but a resume is a *new
process*, while the identity env is a command prefix on the one `task-work`
launched (`bash -ic "TASK_FORCE_ROLE=… ZELLIJ_TAB=… claude …"`), living in no
shell and recoverable from nowhere. `/compact` and `/clear` keep the same
process, so their re-registers really do happen; a resume fires the hook with an
empty environment, the unquoted `--role $TASK_FORCE_ROLE` collapses to nothing,
and register no-ops — now with a log line, because "the hook never fired" and
"the hook fired and register no-opped" used to leave identical (empty) traces.

So `radio` **derives the role from disk** instead of acting anonymously. In a
worktree, `<worktree-base>/.<slug>.info` plus the main repo name rebuild
`worker-<reponame>-<slug>` (or `reviewer-<reponame>-pr<N>`, whose tab slug is
`review-pr<N>`) exactly as `task-work` / `task-reviewer` built them — the same
file #188 recovers `TAB_ID` from. In a main checkout the repo name gives
`pm-<reponame>`, gated on that role having radio state on disk, so a plain
`claude` session in the repo root never claims the PM's address; and no
candidate is claimed while its session file carries a *fresh* heartbeat, since
only a process that has the role env can write one. `check` / `read` / `ack` /
`send` announce the recovered role on stderr, and **refuse loudly** when nothing
is derivable: a roleless `send` used to write `from: unknown` into the
machine-wide literal-`pm` inbox that #210 makes adoptable first-come, and a
roleless `check` used to exit 0 in silence with mail sitting in the inbox. Hook
entrypoints keep #93's silence — recovery never leaks into them.

Recovery does not register, because a register whose tab lookup misses writes an
empty `TAB_ID`, and that is worse than no session at all. The lookup is by tab
*name* within the zellij session, so it can resolve from elsewhere — but the only
place it is guaranteed to is the role's own tab. Run this **there**, in the
agent's own pane: register also records `$ZELLIJ_PANE_ID` as the pane wakes go
to (#336), and typed in a shell pane beside the agent it would name the shell.
So a repair records its pane only when it runs beneath the agent (claude's `!`
prefix); from any other pane it keeps the pane already on file and logs
`is not the agent's pane`:

```bash
radio register --role <role> --tab <tabname> \
  --repo "$(git rev-parse --show-toplevel)" --agent claude --loadout <loadout>
```

It works with no `$TASK_FORCE_ROLE` since #229 — before that the dispatcher
discarded the call before ever reading `--role`, so the documented way out of a
roleless session was itself a silent no-op — and it now says on stderr whether
the role came back wakeable, warning explicitly when `TAB_ID` ended up empty.
It also keeps the role's radio auto-submit setting: the shell you repair from
has no `TASK_FORCE_AUTO_SUBMIT`, and an unset value means "as recorded" (#246).

That is the repair for a **resumed** session, whose tab ids are still the live
server's. After a zellij **restart** use `task-recreate-worker` instead: the
restart renumbered every tab, and `task-work`'s `<worktree-base>/.<slug>.info`
sidecar — the record `task-done` closes the tab by — still names the old id,
which by then may belong to another worker's tab. `task-recreate-worker` is the
command that strips and rewrites it (#218). Since #260 a hand `register` that
resolves the tab live from zellij also rewrites a stale sidecar `TAB_ID`, and
`task-done` closes a tab only when the tab at that id still bears its slug
(`⏸️ <slug>` / `▶️ <slug>` included) — on a mismatch it leaves the tab open and
logs `tab-close: id N is now <name>, not <slug>`, rather than closing an
unrelated worker's tab as it did before.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping.

**Agent-authored prose goes in on stdin, never through a double-quoted shell
string** (#234). Inside `"…"` the shell command-substitutes every backticked
token, so a review quoting `pwd -P` posts that command's *output*, and a
backticked identifier naming no command — `$WORKTREE_DIR`, `_helper()` — posts
as **nothing at all**, deleting the finding's subject with no sign a word is
gone. Reviews, specs and commit bodies here are backtick-dense, so the rule is
absolute: feed `gh` its body with `--body-file -`, `radio send` its body on
stdin, and `git commit` its message with `-F -`, all from a **quote-delimited**
heredoc (`<<'BODY'` … `BODY`, never `<<BODY`).
Single-quoting `-b '…'` is not a fix — prose contains apostrophes, and the
first one ends the string. It also means every backticked token in a review is
*executed* in the reviewer's worktree, and review prose routinely quotes `rm`,
`git reset` and `gh pr merge` while discussing a diff. The reviewer's PR comment
is the failure that named this: its tab self-destructs by design, so a mangled
comment is an unrecoverable loss of the analysis.

Worker role names follow `worker-<reponame>-<slug>`; discover the live one via
`ls ~/.task-force/radio/sessions/`.

All of radio's state (sessions, mailboxes, the log) lives under
`$TASK_FORCE_HOME`, which defaults to `~/.task-force`. Point it at a scratch
directory to probe or test without touching live roles. `task-work`,
`task-reviewer` and `task-recreate-worker` pass a set `TASK_FORCE_HOME` into the
tab they open, because a new zellij tab starts from the zellij server's
environment and not yours. Without that, a scratch-home probe would register in
the real `~/.task-force` (#262). `task-pm` runs in place, so it inherits the
variable without help. When it is unset, nothing is passed and the default applies.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the zellij tab it runs in (by id, never whichever tab has focus, #358) to `pm-<reponame>`, registers that repo-scoped role via
the `SessionStart` hook, and starts the PM agent in-place. The per-repo role
(#165) lets PMs in two repos coexist without clobbering each other's mailbox;
workers reach it by sending `--to pm`, which radio resolves to this repo's
`pm-<reponame>` via the injected `$TASK_FORCE_PM_ROLE` or the sender's own identity. To oversee
several repos from one PM tab, pass `task-pm --also <other-repo>` (repeatable):
it writes an alias radio session so `pm-<other>` routes into this one inbox.

Radio wakes addressed to a PM do **not** auto-submit by default (#254): the wake
types `radio check` into the PM's prompt box and waits for your Enter. That box
is the one you type in, and a submitting wake would send whatever is half-typed
there. Pass `task-pm --auto-submit` for a PM left to run unattended — the wake
then presses Enter for it, so a worker's report drains without a keypress (#189
made that the default; #254 reversed it). Either way nothing is lost: the
`UserPromptSubmit` hook puts the unread summary in front of the PM at your next
prompt. `--also` aliases inherit the primary
PM's setting.

To switch a **running** PM without relaunching it (#385), the PM or you runs
`radio auto-submit on|off|status`, on the caller's own role: `! radio
auto-submit on` from the claude prompt or the kiro one (kiro-cli 3.x takes
`!command` too), or the PM through its own shell tool. It rewrites
`AUTO_SUBMIT` in the session file and the sidecar, so the next wake follows it,
and it outranks the launch setting on every re-register: `on` holds through a
`/compact`, a `/clear` and a fresh PM start until its expiry or an `off`; an
`off` gives way to a fresh launch that states its own setting. `on --for 8h`
or `--until 07:30` (an ISO time works too; `Z` for UTC) sets an expiry, stored
as `AUTO_SUBMIT_UNTIL=`: the first send after it types LF again, logs
`auto-submit: expired role=…` and clears the setting. `--note <text>` (`--note
-` reads stdin) is the away mandate, such as "finish #377 and #384, review but
don't merge". While auto-submit is on, every `radio check` opens with it as
`[away]` lines, and so does every register of the role, so it stays in front
of the PM after a `/compact`, a `/clear` or a rotation. The wake itself stays
the literal `radio check`. Conditions in the note are instructions to the PM,
not radio logic: the PM judges them and runs `radio auto-submit off` itself.
The PM prompt says to turn it on when you say you are away, honour the note on
each wake and turn it off when its conditions are met or you are back.
task-monitor shows `auto-submit` and its expiry beside the PM.

Workers are the other way round: `task-work` launches them auto-submitting and
leaves focus on your tab, because the PM's tab is where you work and nobody
types in a worker's. The one exception is a worker you step into to steer by
hand — launch that one with `--no-auto-submit`.

### Reviewer role (single-shot, self-cleaning)

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> <JIRA-KEY>` from any spare tab (add
`Bash(task-reviewer *)` to your project's `.claude/settings.json`
`permissions.allow` so the PM dispatches hands-off without a permission
prompt). It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet 5.5 (`claude-sonnet-5-5`; pre-set `ANTHROPIC_MODEL`
to override), cross-checks
the PR against the Jira spec issue (PR-body auto-detect is GitHub-only, so pass
the key explicitly — without it the review is diff-only), runs the `code-review`
skill on the diff, posts **one** thorough PR comment via
`gh pr comment --body-file -` carrying its full analysis + verdict, and radios
PM back with
`review-complete-clean` or `review-complete-with-findings`. It pins the PR's
head SHA before reading the diff and names it, as `reviewed <sha>`, in the
comment's verdict line and as the first line of the radio body, which is what
`task-merge-gate` binds a clean review to; if the head moved during the review
the verdict is never clean (#348). Then it
**auto-destructs**: `task-done --remove-worktree` removes its worktree and
closes its tab. It does NOT idle waiting to be closed, and there is no manual
cleanup left for anyone. The analysis lives in the PR comment, not the tab —
re-read a review any time with `gh pr view <N> --comments`. PM still owns the
merge decision — the reviewer never approves, merges, or mutates status — and
reads the verdict on its next `radio check`.

The one exception to self-destruct is a failed radio delivery: when the verdict
never reached PM (`WARNING — no session for pm-…`, or queued with a failed
wake), the reviewer holds its tab open to say so, because that outcome is the
one thing its PR comment does not record. A reviewer tab you still see is a
reviewer that could not reach PM.

### Tight-PR norm — minimize deferrals

Default to landing each PR **complete**. The reviewer frames every finding as
fix-in-this-PR (never "defer to a follow-up" for in-scope work), and the PM
forwards **all** in-scope findings — blockers *and* nits — in a single
`changes-requested` round rather than trailing a backlog of deferred items. The
only thing that gets deferred is work genuinely out of the PR's scope (a separate
subsystem, a large refactor) — and the PM grooms that into a ticket during the
session, not left as a loose "later."

If a worker tab dies unexpectedly (or Claude resumes a session without
re-firing `SessionStart`), the session file's `LAST_HEARTBEAT` will go stale.
Run `radio orphans` to list any session whose heartbeat is older than 1 hour —
those entries are safe to delete (`rm ~/.task-force/radio/sessions/<role>.info`)
or leave for the next legitimate `radio register` to overwrite.

`radio unregister` on its own is **not** a cleanup command (#198). With no
`SessionEnd` payload naming a real exit on stdin it refuses and says so on
stderr, whatever shape that stdin has — a terminal used to bypass the guard
and wipe the session silently. Pass `--manual` when you mean to tear the
session down; that is what `task-done` does, and it still works from any
stdin shape.

The session file is a soft cache, not the source of truth (#188). Three tiny
sidecars sit beside it — `<role>.loadout`, `<role>.agent` and `<role>.auto-submit`
(#246) — holding the values a re-seed cannot read out of the `.info` file it
is replacing, and they deliberately **survive `unregister`**, `task-done`'s
`--manual` one included.
Only a genuine `register` overwrites them. `task-done --remove-worktree`
removes its own role's set, since that role is retired for good (#375), and
`radio gc` reclaims any others of a role with no session file: with its
mailbox when it reclaims one, else once they are older than the cutoff. So when a wipe is followed by a
`busy` / `ready` self-heal, the rebuilt session keeps the real `LOADOUT` /
`AGENT` instead of `unknown` / `claude`, and it recovers `TAB_ID` from the
task-work-owned `<worktree-base>/.<slug>.info` when the zellij name lookup
misses. An empty `TAB_ID` — the state that makes a role permanently unwakeable,
since `radio send` then queues with no wake attempt — is now written only when
there is genuinely no binding anywhere (non-zellij / CI paths), and the log
says so distinctly.

The auto-submit sidecar is what lets a hand repair keep `AUTO_SUBMIT` (#246).
`register` reads `TASK_FORCE_AUTO_SUBMIT` as tri-state: `1` is on, any other
non-empty value is an explicit off (launchers say `0`), and **unset** restores
whatever the sidecar recorded. Every launcher states its choice, so only a
session nobody launched with an opinion inherits — which is exactly a
`radio register --role …` typed from a plain shell. Before this, that repair
brought a role back without `AUTO_SUBMIT`, and every wake to it needed an Enter
for the rest of its life.

The mailbox and log self-prune (#169): a fresh `SessionStart` register runs a
quiet `radio gc` (14-day default) that deletes dead roles' mailboxes (no session
file + newest inbox/processed entry older than the cutoff), expires old
`processed/` messages on live roles, and rotates the top-level `log` once it
passes ~1MB — so no cron is needed. Preview a sweep with `radio gc --dry-run`,
or force one with a custom window via `radio gc --max-age-days N`. `task-done --remove-worktree` also sweeps its own role's mailbox on cleanup.

### Radio troubleshooting

Read `radio send`'s stdout every time. `delivered`, or `queued — <role> is
busy` / `is awaiting`, means the message landed or drains on its own. Anything
else — `WARNING — no session for …`, `queued — … wake failed`, `WARNING — …
looks dead`, `task-done`'s `no tab id captured`, a hook that `timed out after
30s` — means load the `radio-troubleshooting` skill
(`.claude/skills/radio-troubleshooting/SKILL.md`, installed by `task-init`)
before you act on it.
