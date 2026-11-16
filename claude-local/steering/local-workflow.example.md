## Local Task Tracking Workflow (Claude Code)

This project uses **local markdown task tracking** — tasks live as files in
`tasks/`, committed alongside the code. No external tracker, no MCP. The board
view is auto-generated and Obsidian-friendly.

Copy this file to your project's `.claude/local-workflow.md`.
Or run `task-init claude-local` in your project root to do this automatically.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

Then reference it from `CLAUDE.md` at your project root so every Claude Code
session auto-loads it:

```
@.claude/local-workflow.md
```

### Task Storage

Tasks live at `<repo-root>/tasks/` — one `.md` per task, with YAML frontmatter:

```yaml
---
id: 001
title: Add login flow
status: todo            # todo | in-progress | in-review | done
priority: P1            # P0 | P1 | P2 | P3
tags: [auth, frontend]
created: 2026-05-15
branch: ""              # filled by task-work
pr: ""                  # filled by worker before task-done
---
```

Body sections: `## Problem`, `## Solution`, `## Files to Create/Modify`,
`## Verification` — same shape as the planner spec template.

Filename convention: `NNN-slug.md`, where `NNN` is the zero-padded task id and
`slug` is a kebab-case short title. The PM agent allocates the next id.

### Board View

`tasks/_board.md` is **auto-generated** by `task-board` — never hand-edit it.
It has four sections: Todo / In Progress / In Review / Done. Every open task is listed;
Done lists only the 10 newest (highest id first), then one
`+ N older done tasks` line (#294). `task-board --done-limit N` or
`TASK_BOARD_DONE_LIMIT=N` changes the cap.

The PM reads this file for the backlog — it runs `task-board`, then reads
`tasks/_board.md` — and opens a task file only when the work is about that
task. Reading the frontmatter of every `tasks/*.md` instead would cost context
in proportion to the backlog, done tasks included; the board costs the same at
10 tasks or 200.

Triggers that regenerate the board:
- `task-work tasks/NNN-slug.md` (after worktree creation)
- `task-done` (after cleanup)
- The PM agent, after any mutation to a task file

### Status Lifecycle

`todo` → `in-progress` → `in-review` → `done`

- **Status when starting work**: `in-progress` (worker bumps on first commit)
- **Status when in review**: `in-review` (worker bumps after opening the PR; leave blank if your project skips this state and the worker will keep it at `in-progress` through review)
- **Status when done**: `done` (worker bumps only after the PM signals `approved-and-merged` via radio — not before)

Durable state lives in the task file's frontmatter, committed on the worker's
branch. Live in-progress state lives in `.git/task-force/state.json`
(gitignored, per-clone) — written by `task-work` and removed by `task-done`.

### Task Properties

- **Title** (in frontmatter), **Status**, **Priority**, **Tags**, **Created date**
- **Branch** (set by `task-work`)
- **PR** (URL — set by the worker after `gh pr create`)

### Commit Convention

Use the task title as prefix: `<Task title>: <short description>`

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes tasks/NNN-slug.md` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work tasks/NNN-slug.md` — worktree + tab + worker; see `--help`
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
- `task-board` — regenerate `tasks/_board.md` from the task files

After a merge, delete only the remote branch (`git push origin --delete task/<slug>`),
never `gh pr merge --delete-branch`: it removes the worktree out from under the worker.

`task-reviewer` with no `--profile` reviews on this profile; `none` is the Sonnet reviewer:

- **Reviewer profile**: `none`

### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker prompts shell out to
`radio send` at every documented handoff point:

| From    | When                            | Command                                                                |
|---------|---------------------------------|------------------------------------------------------------------------|
| Planner | spec written into the task file | `radio send --to pm --intent spec-ready --issue <NNN>`                 |
| Worker  | PR opened                       | `radio send --to pm --intent review-requested --pr <N>`                |
| Worker  | new commits pushed after review | `radio send --to pm --intent re-review-requested --pr <N>`             |
| PM      | review requested changes        | `radio send --to <worker-role> --intent changes-requested --pr <N>`    |
| PM      | PR merged                       | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`  |

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
`task-reviewer <pr-url-or-number> <task-slug>` from any spare tab (add
`Bash(task-reviewer *)` to your project's `.claude/settings.json`
`permissions.allow` so the PM dispatches hands-off without a permission
prompt). It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet 5.5 (`claude-sonnet-5-5`; pre-set `ANTHROPIC_MODEL`
to override), cross-checks
the PR against the local task file (PR-body auto-detect is GitHub-only, so pass
the slug explicitly — without it the review is diff-only), runs the `code-review`
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

### When radio misbehaves

Every radio failure found so far has been a **notification** failure, not a
lost message: a session file wiped out from under a live role, a wake that
typed text nobody submitted, a stop-hook that let an unread message sit. The
mail itself is never deleted — it waits in
`~/.task-force/radio/mailbox/<role>/inbox/` until someone reads it. So when
radio looks broken, start at the log (`~/.task-force/radio/log`), not at the
mailbox.

| Symptom | Cause and check |
|---------|-----------------|
| Pinged a role, nothing happened | Re-read the sender's own outcome line — only `delivered` means a keystroke landed; every other line names its own reason. Then `ls ~/.task-force/radio/sessions/` (is the role there, spelled exactly?) and `radio orphans` (a >1h-stale heartbeat means the tab is gone). In the recipient's own tab, `radio check` tells you whether the message arrived and simply wasn't acted on. |
| A wake typed `radio check` into a shell, `task-watch` or `task-monitor` pane beside the agent | The wake went to the tab's focused pane, not the agent's (#336). `register` records the agent's pane as `PANE_ID=` off `$ZELLIJ_PANE_ID`, and `send` writes there while zellij still lists it as a terminal pane on the role's tab; otherwise it falls back to the focused pane. Each `send: woke` log line ends in `(src=recorded)` or `(src=focused)`, and `recorded PANE_ID=… falling back` says a recorded pane went stale. A session registered before #336 has no `PANE_ID` until its next register: a `/clear` in the agent, or the hand `radio register` above, run in the agent's pane. |
| `radio check` sitting unsubmitted in a prompt box | The wake was delivered but not submitted: that role's session file has no `AUTO_SUBMIT=1`, so the wake ended with LF instead of CR (#189). Press Enter to finish this one. On a **PM** that is the default since #254 — the box is yours, and a submitting wake would send whatever you had half-typed; relaunch with `task-pm --auto-submit` only if the PM is meant to run unattended, or switch the running one with `radio auto-submit on` (#385). A PM that auto-submitted until some hour and now waits again had an expiry: `radio auto-submit status` says `expired`, and `grep 'auto-submit: expired' ~/.task-force/radio/log` gives the time. On a **worker** it is not the default: it was launched with `--no-auto-submit`, or registered before #254 without `--auto` / `--auto-submit`. Relaunch it with plain `task-work` (or `task-recreate-worker --auto-submit`) to stop it recurring. The flag is read off the **recipient's** file, after any `--also` alias hop. |
| A role keeps vanishing from `sessions/` | Session flapping — something fires a session-end wipe on an intra-session event and takes `TAB_ID` with it. Compare `grep -c 'unregister role='`, `'unregister: proceeding'` and `'unregister: skipping'` in the log: post-#187 `skipping` should carry the bulk of the traffic, and `role=` should be close to `proceeding` plus however many `--manual` calls were made. A gap has two causes, and `--manual` is the likelier: it short-circuits the block that emits *both* other lines, so it writes only `role=`, and anything calling it in a loop inflates that counter alone — a test suite that has not isolated `$TASK_FORCE_HOME` will do exactly this against your live role. Otherwise an **old `radio` binary** is on `PATH`, since every non-`--manual` call now logs one or the other; `PATH`'s `radio` is a symlink into a checkout, so run `ls -l "$(command -v radio)"` and confirm that tree is current. |
| `radio unregister` did nothing | Expected since #198, not a bug. With no payload naming a real exit it refuses, printing `refusing to wipe <role> … re-run with --manual` on stderr and logging a `skipping` line. Pass `--manual` if you meant to tear the session down. |
| PM merged but the worker never cleaned up | The `approved-and-merged` ping arrived after that worker had exited, so it was never delivered. Since #201 gc archives such mail instead of keeping a mailbox nobody will open alive forever — look in `~/.task-force/radio/dead-letter/<role>/`, and `grep 'gc: dead-lettered' ~/.task-force/radio/log` for everything it has archived. The message is intact with its id and frontmatter; only the worktree needs cleaning by hand. |
| A role idles on a message sitting in its own inbox | Fixed in #197. `BLOCKED_IDS=` in the session file records which ids the last stop-hook block was about, so a message arriving mid-drain earns its own continuation. In the log, `arrived during the drain turn` is a correct re-block; `no new message since the block` is the loop-breaker firing because the same ids were ignored twice. |
| `radio check` says nothing while mail is in the inbox, or a report lands `from: unknown` | The session has no `$TASK_FORCE_ROLE`: it never registered, which is what every resumed session looks like (the env was a command prefix on the original process, not an export). Fixed in #229 — `check` / `read` / `ack` / `send` now recover the role from disk or refuse loudly, and `radio register --role … --tab …` works without the env var. `grep 'recover-role:' ~/.task-force/radio/log` shows what was recovered or refused, and `grep 'register: no-op' ~/.task-force/radio/log` a hook that fired with an empty environment. |
| `task-done` says `no tab id captured` and leaves the tab open | The tab's id was never recorded at launch. Before #242 that capture failed silently; now `task-work` (and `task-reviewer` / `task-recreate-worker`) says so on stderr the moment it happens and logs why — `no-zellij-bin`, `not-in-zellij`, `no-jq`, `list-tabs-empty`, `race`, or `no-match` together with the tab names zellij reported. `task-done`'s skip line now also says which source was empty. `grep 'tab-id:' ~/.task-force/radio/log` — one line per missed capture, with the slug and the reason. A sidecar written before the capture existed (#117) has no `TAB_ID=` at all. Close the tab by hand; an unscoped `close-tab` closes whichever tab is focused (#107). |
| `task-done` says `Not closing zellij tab id=N: it is now '<name>'` and leaves the tab open | The sidecar's `TAB_ID` is stale: zellij restarted since it was captured, and the id now belongs to another tab. Before #260 `task-done` closed it anyway, killing whichever worker held it. A resume in place keeps the old id; `task-recreate-worker` rewrites it. `grep 'tab-close:' ~/.task-force/radio/log` names the tab that holds the id now. Close your own tab by hand; after a restart, recover workers with `task-recreate-worker` (or re-run `radio register --tab …` from the tab, which since #260 also rewrites a stale sidecar id). |
| A launch left you on the new worker's tab instead of your own | zellij opens a tab asynchronously and always focuses it, so the launcher's snap-back `go-to-tab` can land before the new tab has finished opening (#311). The launcher now re-checks for about 1.5s and issues `go-to-tab` again until your tab is active; it gives up after that and never fails the launch. `grep 'tab-focus:' ~/.task-force/radio/log` — `snap-back needed N go-to-tab(s)` is a race that was corrected, `snap-back failed after N go-to-tab(s)` one that was not, with the position that kept focus, and `new tab never appeared` a launch whose tab zellij never listed within that time. Since #343 the check waits for the new tab to be listed and wants your tab active twice in a row, so an early answer from zellij no longer ends it before the new tab steals focus. More frequent on a loaded machine. Since #384 it also looks once more about a second after your tab settles (`AW_TAB_FOCUS_LATE`, 0 skips it), so a steal landing after both checks is caught too: `late_steal=1` on the `snap-back needed` line. And every exit that leaves focus in doubt now logs: `list-tabs unusable after N check(s)` is a tab list that answered nothing usable, which used to end the check silently and leave no `tab-focus:` line at all. Look for a `zellij-timeout:` line beside it. `--focus` skips all of this. |
| A hook timed out after 30s (`UserPromptSubmit hook [radio prompt-hook] timed out after 30s — output discarded`), or a launch lost focus with no `tab-focus:` line | A zellij server that stalls, busy opening a tab or loaded with agents across sessions, used to hold every radio call that talked to it, and Claude Code kills a hook at 30s with its output (#384). Since #384 every zellij call radio and the snap-back make is bounded by `TASK_FORCE_ZELLIJ_TIMEOUT` seconds (default 3). The first that runs out logs `zellij-timeout: <action> <secs>s role=<role>` (`caller=snap-back slug=<slug>` from a launch), and the rest of that radio run skips zellij. The state write, the heartbeat and prompt-hook's unread summary never wait on zellij; what is lost is the tab repaint, or the wake, which queues as on any failed wake. `grep 'zellij-timeout:' ~/.task-force/radio/log`, and time `zellij action list-tabs --json` while it recurs. A few lines are a busy moment; many in a row are a zellij server worth restarting (then `task-recreate-worker`). |
| A kiro role's heartbeat froze at its register, and `send` says `looks dead` while its tab is open | kiro-cli's V3 engine stopped firing the agent's hooks (#370). It hot-reloads `.kiro/agents/<agent>.json` when the file changes, and a reload that finds task-init's object-shaped `hooks` drops every hook for the rest of the session, even once the universal file is back (probed on kiro-cli 3.1.0). The usual way in is a `git stash`, `checkout` or `reset` that puts the committed object-shaped copy back over the one kiro rewrote at launch. kiro's own log shows it: `grep -c ContextualHookInvoked ~/.kiro/logs/<start>-<pid>/kiro.log` stops growing at that reload. `send` now wakes a kiro role that looks dead while the tab at its `TAB_ID` still bears its name, and logs `but its tab is still open — kiro, waking anyway`; claude is unchanged. For good, commit the configs in universal shape: `kiro-cli agent upgrade .kiro/agents`, commit, then `git merge <base>` in each live worktree. The kiro launchers warn on V3 while a config is still object-shaped. A hook that runs with no `$TASK_FORCE_ROLE` now logs `hook-noop: <entrypoint>`, at most hourly. |
| A kiro role stays `busy` after its turn ended on an error, and `send` queues behind it | A kiro turn whose request fails at the API fires `userPromptSubmit` and never `stop` (#322). Probed on kiro-cli 3.1.0 with the network cut: kiro retried for 1m41s, printed `A network error occurred` and went back to its prompt, so `radio busy` ran and `radio ready` never will. A usage limit did the same in #278's probe. Every tool call now runs `radio heartbeat` (the `postToolUse` hook), so a kiro `busy` that no hook has touched for `TASK_FORCE_KIRO_BUSY_STALE_SECS` (default 600) is taken for that dead turn. `send` wakes it when the tab at its `TAB_ID` still bears its name, and logs `no hook for <N>s) but its tab is still open — kiro, waking anyway`. task-monitor shows it as `▶? busy?`. The wake's `radio check` starts a new turn, and that turn's `stop` clears the state. Claude is unchanged. An agent launched before `task-init` was re-run has no `postToolUse` hook, so a long turn of its own can be woken mid-turn. |
| An agent's processes are still running after its tab closed | A tab close never reaches kiro's backend, which runs in a session of its own (#388): the V3 engine's `acp-server.js` outlived `close-tab`, a closed pane and a killed session on kiro-cli 3.1.0. Since #388 a kiro worker or reviewer runs under `bin/agent-supervise`, which stops the worktree's agent processes once the agent has exited, and logs each: `grep 'reap:' ~/.task-force/radio/log`. `reap: nothing left` is a close with nothing to stop, `reap: failed` one it could not finish, `reap: skipped` a launch outside a linked worktree. No `reap:` line for the slug means the tab predates #388, the agent is claude, or the supervisor itself was killed (a SIGKILL stops nothing). Then `task-recreate-worker <slug>` lists the pids and `--kill-stale` stops them; `task-done` lists them and logs `stray-procs:`. |

The log is the only place several of these states are distinguishable at all.
It is shared by every repo and role on the machine, so read timestamps rather
than raw counts — and a field missing from an old line means an older binary
wrote it, not that the value was unset:

```bash
L=~/.task-force/radio/log
grep -c 'send id=' "$L"; grep -c 'send: woke' "$L"   # sent vs. actually woken
grep -oE 'is busy|is awaiting|looks dead|no session for|has no TAB_ID|tab id unresolved|no writable pane|write-chars failed' "$L" | sort | uniq -c | sort -rn
grep -oE 'skipping \(empty payload on [a-z-]+ stdin' "$L" | sort | uniq -c
grep -oE 'tab_id_src=[a-z-]+' "$L" | sort | uniq -c   # `none` = role is unwakeable
grep -oE '\(src=[a-z]+\)' "$L" | sort | uniq -c   # `focused` = no usable PANE_ID (#336)
grep -c 'no tab binding for' "$L"; grep -c 'loadout=unknown' "$L"
```

Undelivered mail is never deleted. The message is written to the inbox
**before** any wake is attempted, so every outcome other than `delivered`
means "on disk, waiting" rather than "gone". `radio gc` expires only
`processed/`; it never touches a live role's `inbox/` at any age, nor a dead
role's while that mail is still inside the cutoff — the role may yet come back.

What it no longer does is protect a mailbox forever (#201). Mail addressed to a
role that has **exited** is never delivered and never read, so once a role is
gone — no session file, or a >1h-stale heartbeat — and its mail has aged past
the cutoff, gc moves that mail to `~/.task-force/radio/dead-letter/<role>/`,
id and frontmatter intact, and reclaims the emptied mailbox. That is an
archive, not a delete: nothing unread is ever `rm`'d, and the archive has no
TTL of its own. It is where a merge ping that outlived its worker ends up —
usually the reason a worktree was left behind. A fresh PM register reports the
count it finds, once. So there are two places to look:

```bash
ls ~/.task-force/radio/mailbox/<role>/inbox/  # waiting — the role may still read it
ls ~/.task-force/radio/dead-letter/           # never delivered — the role is gone
grep -c 'gc: dead-lettered' ~/.task-force/radio/log
radio gc --dry-run   # what a sweep would archive and reclaim, without doing either
```

When the wake itself fails, the backstops still apply: the `Stop` hook makes
the agent drain a queued message at the end of its current turn, the
`UserPromptSubmit` hook puts the unread summary in front of it at the next
prompt, and a fresh `SessionStart` register reports whatever queued while the
role was offline. A failed wake is a latency problem here, not a lost message.
