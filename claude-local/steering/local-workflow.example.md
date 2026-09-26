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
status: todo            # todo | in-progress | done
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
It has three sections: Todo / In Progress / Done.

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

### Shell Commands

`task-work tasks/NNN-slug.md [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`
- `--no-launch` — open the worktree tab but do NOT start Claude

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work tasks/001-add-login-flow.md
task-work tasks/042-refactor-auth.md --base develop --plan
task-work tasks/050-stacked-feature.md --from task/042-refactor-auth --auto
task-work tasks/007-spike-idea.md --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)

`task-board` — regenerate `tasks/_board.md` from `tasks/*.md` frontmatter +
`.git/task-force/state.json`. Idempotent; safe to run anytime. Like `task-work`
/ `task-done`, it is a root dispatcher that resolves the loadout per-repo
(#215) — on a repo tracked in GitHub / Jira / Notion it refuses with a message
naming that loadout, because there are no local task files to render a board
from. `--repo PATH` picks the repo, and the dispatcher detects from that path
rather than from `$PWD`.

`task-config show` / `task-config set` — which loadout this repo is on, and how to switch it (#219)

`task-config show` prints the assistant, the tracker, that tracker's settings and
the paths carrying them. Unlike every other task-force command it never refuses:
a repo with **no** loadout and a repo with **two** are both *described* (each
still exits non-zero), because a confusing repo is exactly when you reach for it.

```bash
task-config show
task-config set assistant kiro      # same tracker, swap the assistant
task-config set tracker gh          # same assistant, swap the tracker
task-config set loadout claude-gh   # swap both at once
```

A `set` detects the current loadout, carries the tracker settings off its
workflow doc, removes that loadout's artifacts, then delegates the install to
`<new-loadout>/bin/task-init --force`. It never writes an artifact itself.
`--dry-run` prints the plan and changes nothing; a TTY run confirms first, and
`--yes` skips the prompt. In an ambiguous repo, `--impl <name>` says which
loadout to replace.

Removal takes out **only** task-init's own entries. Your own `CLAUDE.md` sections
survive with just the `@.claude/local-workflow.md` import line gone; your own hooks
and allow-list entries in `.claude/settings.json` survive with just the
radio-owned ones gone; a `.claude/commands/<role>.md` you have edited is **kept**
rather than deleted, because task-init's `keep` policy means that file may be
yours; on the local loadouts the `tasks/` scaffolding goes but **your backlog does
not** (the run says how many files it kept); and a directory is reclaimed only
once removal has actually emptied it. The workflow doc itself has to go — it is
the detection key — but repo-specific sections below the managed-region end
marker are copied to `<doc>.bak` first.

Settings carry across a `set assistant` — claude and kiro render the same
template shape per tracker — and cannot across a `set tracker`, because different
trackers share no fields at all, so `task-init` prompts for the new ones exactly
as on a first install. `kiro-jira` is refused by name: the assistant × tracker
grid has exactly one hole (#92).

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
`task-reviewer <pr-url-or-number> <task-slug>` from any spare tab (add
`Bash(task-reviewer *)` to your project's `.claude/settings.json`
`permissions.allow` so the PM dispatches hands-off without a permission
prompt). It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet (cheaper than the PM's Opus default), cross-checks
the PR against the local task file (PR-body auto-detect is GitHub-only, so pass
the slug explicitly — without it the review is diff-only), runs the `code-review`
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
