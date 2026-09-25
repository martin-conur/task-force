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

### Shell Commands

`task-work <JIRA-KEY-or-url-or-slug> [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work {KEY}-42
task-work https://{SITE}.atlassian.net/browse/{KEY}-42
task-work refactor-auth --plan
task-work {KEY}-99 --from task/{KEY}-46 --base main --auto   # stack on an in-flight branch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)

### Atlassian MCP

This workflow assumes the Atlassian Remote MCP server is configured. Verify with:

```
claude mcp list
```

You should see an `atlassian` entry. If not, see Atlassian's documentation for the Remote MCP server.

`ci-guard` — the commit-msg guard `task-work` installs (#194)

Every `task-work` run installs a `commit-msg` git hook that refuses a commit
message containing a literal CI-skip marker — `[skip ci]`, `[ci skip]`,
`[no ci]`, `[skip actions]`, `[actions skip]`. GitHub honours those **anywhere
in the message**, not just the subject line, so an agent that merely *quotes*
one while describing another commit suppresses its own workflow run. The
failure leaves no artifact: no run is queued, so the PR shows no failing checks
because it shows no checks, and "CI green" gets reported in good faith off an
empty list. It happened twice in one hour before the guard existed, the second
time to an agent that was correctly *explaining* the first.

Git shares one hooks directory across a repo's worktrees, so the hook covers
every commit in the repo, not just the worktree it was installed from. A
pre-existing `commit-msg` hook is never clobbered: it is preserved as
`commit-msg.local` and chained. Installation is idempotent.

```bash
ci-guard check [<rev|range>]   # scan committed messages (default: HEAD)
ci-guard scan <file>|-         # scan a message file or stdin
ci-guard install-hook [<dir>]  # (re)install the hook by hand
```

Writing *about* a marker is the legitimate case the guard has to accommodate —
break it (`skip-ci`) or drop the brackets. `git commit --no-verify` bypasses
the hook for a deliberate skip, and `TASK_FORCE_NO_CI_GUARD=1` disables the
guard entirely.

The companion habit: verifying CI means confirming a run **exists and passed**
for the exact SHA. "Passing" and "never built" look identical in `gh pr view`.

```bash
gh run list -c "$(git rev-parse HEAD)" --limit 1 --json databaseId --jq 'length'
# 0 => no run for this commit; "green" is not a claim you can make
```

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

When a worker's turn ends, the `Stop` hook runs `radio stop-hook`
automatically: with an empty inbox it marks the role idle; if messages queued
up while the worker was busy, it blocks the stop (staying busy) so the agent
drains them immediately — you don't need to invoke it manually. A message that
lands *during* that forced drain turn earns one more block of its own (#197):
the hook records the message ids each block was about and compares the inbox
against that set, so a genuinely new arrival still gets a continuation while an
agent that ignores the same ids twice is still allowed to stop. Before this,
the second `Stop` gave up on the flag alone and the new message sat unread —
terminal for an idle `--auto` worker nobody was going to prompt again.

Likewise, every submitted prompt runs `radio prompt-hook` (the
`UserPromptSubmit` hook): if the inbox has unread messages, a line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
is injected into the agent's context alongside the prompt. That line is the
canonical radio channel, not user-typed text — trust it and process the
listed messages with `radio check` / `radio read <id>`.

Finally, `SessionStart` fires `radio register`; on a *fresh* start (not the
re-registers that `/compact`, `/clear`, and resume trigger) it also prints a
summary of any inbox that queued while the role was offline — reports whose
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

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping. Worker role names
follow `worker-<reponame>-<slug>`; discover the live one via
`ls ~/.task-force/radio/sessions/`.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm-<reponame>`, registers that repo-scoped role via
the `SessionStart` hook, and starts the PM agent in-place. The per-repo role
(#165) lets PMs in two repos coexist without clobbering each other's mailbox;
workers reach it by sending `--to pm`, which radio resolves to this repo's
`pm-<reponame>` via the injected `$TASK_FORCE_PM_ROLE` or the sender's own identity. To oversee
several repos from one PM tab, pass `task-pm --also <other-repo>` (repeatable):
it writes an alias radio session so `pm-<other>` routes into this one inbox.

Radio wakes addressed to a PM **auto-submit** (#189): the wake types
`radio check` into the PM's prompt box and presses Enter for it, so a worker's
report is drained without a keypress. Before this, every PM-bound wake sat
unsubmitted in the input box while the sender was told `delivered` — the PM
being the most-addressed role, that was the most-felt delivery defect in the
system. Pass `task-pm --no-auto-submit` to keep the old human gate (the wake
types `radio check` and waits for your Enter); worth it if you type long
prompts into the PM box, since an incoming wake would otherwise submit whatever
is half-typed there. `--also` aliases inherit the primary PM's setting.

### Reviewer role (single-shot, self-cleaning)

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> <JIRA-KEY>` from any spare tab (add
`Bash(task-reviewer *)` to your project's `.claude/settings.json`
`permissions.allow` so the PM dispatches hands-off without a permission
prompt). It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet (cheaper than the PM's Opus default), cross-checks
the PR against the Jira spec issue (PR-body auto-detect is GitHub-only, so pass
the key explicitly — without it the review is diff-only), runs the `code-review`
skill on the diff, posts **one** thorough PR comment via `gh pr comment`
carrying its full analysis + verdict, and radios PM back with
`review-complete-clean` or `review-complete-with-findings`. Then it
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

The session file is a soft cache, not the source of truth (#188). Two tiny
sidecars sit beside it — `<role>.loadout` and `<role>.agent` — holding the
values a re-seed cannot read out of the `.info` file it is replacing, and they
deliberately **survive `unregister`**, `task-done`'s `--manual` one included.
Only a genuine `register` overwrites them, and `radio gc` reclaims them once
the role has no session file left at all. So when a wipe is followed by a
`busy` / `ready` self-heal, the rebuilt session keeps the real `LOADOUT` /
`AGENT` instead of `unknown` / `claude`, and it recovers `TAB_ID` from the
task-work-owned `<worktree-base>/.<slug>.info` when the zellij name lookup
misses. An empty `TAB_ID` — the state that makes a role permanently unwakeable,
since `radio send` then queues with no wake attempt — is now written only when
there is genuinely no binding anywhere (non-zellij / CI paths), and the log
says so distinctly.

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
| `radio check` sitting unsubmitted in a prompt box | The wake was delivered but not submitted: that role's session file has no `AUTO_SUBMIT=1`, so the wake ended with LF instead of CR (#189). Press Enter to finish this one. To stop it recurring, relaunch the PM with plain `task-pm` (auto-submit is the default; `--no-auto-submit` is the opt-out) or the worker with `task-work --auto`. The flag is read off the **recipient's** file, after any `--also` alias hop. |
| A role keeps vanishing from `sessions/` | Session flapping — something fires a session-end wipe on an intra-session event and takes `TAB_ID` with it. Compare `grep -c 'unregister role='`, `'unregister: proceeding'` and `'unregister: skipping'` in the log: post-#187 `skipping` should carry the bulk of the traffic, and `role=` should be close to `proceeding` plus however many `--manual` calls were made. A gap has two causes, and `--manual` is the likelier: it short-circuits the block that emits *both* other lines, so it writes only `role=`, and anything calling it in a loop inflates that counter alone — a test suite that has not isolated `$TASK_FORCE_HOME` will do exactly this against your live role. Otherwise an **old `radio` binary** is on `PATH`, since every non-`--manual` call now logs one or the other; `PATH`'s `radio` is a symlink into a checkout, so run `ls -l "$(command -v radio)"` and confirm that tree is current. |
| `radio unregister` did nothing | Expected since #198, not a bug. With no payload naming a real exit it refuses, printing `refusing to wipe <role> … re-run with --manual` on stderr and logging a `skipping` line. Pass `--manual` if you meant to tear the session down. |
| PM merged but the worker never cleaned up | The `approved-and-merged` ping arrived after that worker had exited, so it was never delivered. Since #201 gc archives such mail instead of keeping a mailbox nobody will open alive forever — look in `~/.task-force/radio/dead-letter/<role>/`, and `grep 'gc: dead-lettered' ~/.task-force/radio/log` for everything it has archived. The message is intact with its id and frontmatter; only the worktree needs cleaning by hand. |
| A role idles on a message sitting in its own inbox | Fixed in #197. `BLOCKED_IDS=` in the session file records which ids the last stop-hook block was about, so a message arriving mid-drain earns its own continuation. In the log, `arrived during the drain turn` is a correct re-block; `no new message since the block` is the loop-breaker firing because the same ids were ignored twice. |

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
