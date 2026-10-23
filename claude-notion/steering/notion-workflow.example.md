## Notion Workflow (Claude Code)

Copy this file to your project's `.claude/notion-workflow.md` and fill in your Notion database IDs.
Or run `task-init claude-notion` in your project root to do this automatically.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/notion-workflow.md
```

### Notion MCP (Claude Code)

This workflow requires the Notion MCP server configured in Claude Code. Verify with:

```bash
claude mcp list
```

You should see a `notion` entry. If not, add it:

```bash
claude mcp add --transport http notion https://mcp.notion.com/mcp
```

### Notion Database IDs

<!-- Replace each placeholder with the real ID, or pass them to task-init:
       task-init claude-notion --tasks <id> --projects <id> --board <id>
     Run `task-init claude-notion --help-ids` for step-by-step discovery instructions.

     What each ID looks like:
       collection://...  — opaque string from the Notion MCP (data-source URL)
       board page ID     — UUID like 8a1b2c3d-e4f5-6789-abcd-ef0123456789

     How to find them (requires Notion MCP active in Claude Code):
       1. Run: claude
       2. Ask: "Help me find my Notion database IDs"
       3. Claude will list your boards and extract the IDs from the MCP response
-->

- **Tasks**: `collection://<YOUR_TASKS_DATA_SOURCE_ID>`
- **Projects**: `collection://<YOUR_PROJECTS_DATA_SOURCE_ID>`
- **Board page**: `<YOUR_BOARD_PAGE_ID>`

### Task Lifecycle

Not Started → In Progress → In Review → Done (or Archived)

- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review` (leave blank or omit if your Notion database has no In Review option — the worker will keep the task at `In Progress` through review)
- **Status when done**: `Done`

The worker reads these three values and updates the task's Status property as it moves through the lifecycle: to "starting work" before implementing, to "in review" after opening the PR, and to "done" only after the PM signals `approved-and-merged` via radio.

### Task Properties

Customize these to match your Notion database schema:
- **Task name** (title), **Status**, **Priority**
- **Project** (relation), **Tags** (multi-select)
- **Git commit** (URL — set to PR or commit link after done)

### Commit Convention

Use the task name as prefix: `<Task name>: <description>`

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes <Notion page URL>` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

`task-work <slug> [notion-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`). Refused when `REF` lacks the radio hooks `HEAD` carries for the agent (#304): a worktree forked from it would start an agent that never registers. Merge the base into `REF` first
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); permission mode only, mutually exclusive with `--plan`
- `--auto-submit` — radio auto-submit: an incoming wake submits itself instead of waiting in the prompt box for an Enter. **The default** on every launch, `--plan` included, since nobody types in a worker's tab (#254); the flag only makes a launch line explicit
- `--no-auto-submit` — keep the Enter gate on radio wakes. Use it for a worker you mean to step into and steer by hand: a wake would otherwise submit whatever is half-typed in its box
- `--focus` — switch to the new tab. By default focus stays on the tab you ran `task-work` from, so the PM can dispatch without being pulled away (#254)
- `--agent <claude|kiro>` — launch this one worker on the other installed assistant, leaving the repo's active one alone (#293). Both loadouts must be installed (`task-config add assistant`, below). `task-pm`, `task-reviewer` and `task-recreate-worker` take it too, and `task-recreate-worker` without it relaunches on the assistant `task-work` recorded for that worker
- `--no-launch` — open the worktree tab but do NOT start Claude (lets you type the command yourself)

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-store-filtering https://www.notion.so/My-Task-abc123def456
task-work refactor-auth --plan
task-work feature-x --from task/in-flight --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)

If the worktree is already gone — a `gh pr merge --delete-branch` removes it along
with the local branch (#271) — `task-done` still cleans up what is left: radio
session, mailbox, sidecar, git's worktree registration and the tab. Run it from the
vanished directory, or from the main checkout in the worker's own tab (it reads the
worktree from `$TASK_FORCE_ROLE`). The PM keeps it from happening at all by deleting
only the remote branch after a merge: `git push origin --delete task/<slug>`.

`task-done` also warns about, and lists, any agent processes still running in
the worktree it removes (#305): an agent from an earlier tab that closed
without taking it along. It never stops them; that is the PM's or your call.
Run from the worker's own tab, the worker itself is not listed, since its whole
process tree goes with the tab. Run from anywhere else, the PM's tab included, a
worker that is still up is listed too, and is not necessarily stray. The warning is also logged, because that tab closes and takes it
along: `grep 'stray-procs:' ~/.task-force/radio/log`.

`task-recreate-worker <slug> [options]` — recover a worker whose tab died but whose worktree survived (#230)

A machine restart (or a killed zellij server) takes out every tab on the box and
leaves the work itself untouched. What survives: the worktree and its branch,
`task-work`'s `<worktree-base>/.<slug>.info` sidecar, radio's `<role>.loadout` /
`<role>.agent` sidecars, and the role's mailbox with its undelivered mail. What
does not: the zellij tab, the radio session file, and `$TASK_FORCE_ROLE`. Until
this command there was no way back in — `task-work` refuses on the existing
branch by design (#38) and `task-done` is the opposite operation — so recovery
meant a hand-rolled tab and a session radio could not address.

So this re-binds what survived rather than rebuilding it. It opens a fresh tab on
the existing worktree and launches the agent with the same role env `task-work`
injects, which is the whole point: `SessionStart` registers the role, and the
backlog that queued while it was offline is in front of the agent on its first
turn. It never creates, reuses or removes a worktree — if the worktree is gone,
that is new work, and it refuses and names `task-work`.

- `--resume` — resume the previous session instead of starting fresh; claude-only.
  It recovers the session id from the `SessionEnd` payload radio logged for *this
  worktree*, and falls back to Claude's own picker — saying so — when no id can be
  established beyond doubt. Worth it when there is uncommitted exploration to
  keep. Fresh is the default and the safer one: the register-time backlog drain
  (#168) means a fresh agent opens with its queued handoff already surfaced.
- `--auto` — radio auto-submit; on claude it also launches in auto permission
  mode, on kiro it governs auto-submit only (#206). Unlike `task-work`, whose
  default is already on, this command defaults to the auto-submit setting radio
  recorded for the role, so `--auto` still changes something here on both agents.
- `--auto-submit` / `--no-auto-submit` — set radio auto-submit alone. With none
  of these three the rebuilt role keeps the setting radio recorded for it
  before it died — its `<role>.auto-submit` sidecar (#246).
- `--focus` — switch to the new tab. By default focus stays on the tab you ran
  it from, as with `task-work` (#254).
- `--session <name>` — open the tab in zellij session `<name>` instead of the
  one it runs in, refusing one that is not running: it never creates a session.
  task-monitor's `R` passes the repo's session (#291).
- `--no-launch` — open the tab, start nothing; the role stays unregistered.
- `--force` — proceed although a session still looks live.
  It does not get past agent processes still running in the worktree (#305).
- `--kill-stale` — stop the agent processes still running in the worktree
  (TERM, then KILL after 5s) after a `[y/N]` on the terminal, then recover.
- `--yes` — skip `--kill-stale`'s confirmation. With no terminal, `--kill-stale`
  needs it, and refuses without it having signalled anything.

It refuses when the role still looks live: a zellij tab of that name is open, or
the session file's heartbeat is newer than an hour (it asks `radio orphans`
rather than re-deriving the threshold). The first hour after a reboot looks
exactly like a live session, which is what `--force` is for — read the refusal
first, it names which of the two signals fired.

It also refuses while **agent processes are still running in the worktree**
(#305). A closed tab does not reliably take its agent with it: three kiro
workers' processes (`kiro-cli-chat chat`, the bun `tui.js` front end,
`kiro-cli-chat acp`) once outlived their tabs by two days, idle only because the
credits had run out, in worktrees this command was starting new agents in. The
tab and the heartbeat cannot see them, so it asks the kernel: every agent
process (the `claude` or `kiro-cli*` binary, a bun or node launcher running one,
a shell `-c` wrapper that runs one), plus its children, with a cwd inside the
worktree. It judges by what runs, so `less docs/claude` is not an agent. The refusal lists
pid, start time and command. `--force` does not get past it; `--kill-stale`
stops them first, re-checking each pid's start time just before the signal so a
recycled pid is left alone. Whether a process is still running is decided by
scanning again, not by `kill -0`, so one that survives the KILL or refuses the
signal (EPERM) stops the recovery. `TASK_FORCE_NO_PROC_SCAN=1` turns the scan off.

The sidecar's `TAB_ID` is **stripped before the tab is spawned** and rewritten
afterwards, never carried over: zellij's server restarted, so that id is stale by
definition, and `radio register` adopts it from that file when its own name
lookup misses (#218). Stripping it first means a register that beats us to the
write finds nothing to adopt and resolves the new tab by name instead.

It refuses a worktree with no radio hooks for the agent it is about to
launch (#304): `.claude/settings.json` for claude, `.kiro/agents/worker.json`
(or the global one) for kiro, each carrying radio's `register` hook. A worktree
holds what was committed when it was forked, so one cut before
`task-config add assistant` has none for the newer assistant, and an agent
started there runs and never registers. The refusal names the fix,
`git -C <worktree> merge <base>` with the base from the sidecar, or says the
base does not carry the hooks either.

And it prints `Recovered` only once the register has landed: after the launch
it waits up to 30s (`TASK_RECREATE_WORKER_REGISTER_WAIT`) for the role's
session file to show a register newer than the launch, by the expected
`AGENT`, with a `TAB_ID`. Otherwise it warns that the agent started but has not
registered, with the likely causes (a startup prompt waiting in the tab, an
agent that exited), and the "surfaced N queued message(s)" line is not printed.
It still exits 0: the tab and the agent are up.

```bash
task-recreate-worker issue-223           # fresh session; tab, role and mail rebound
task-recreate-worker issue-223 --auto    # hands-off: auto-submit (and auto permission mode on claude)
task-recreate-worker add-auth --resume   # resume the old session (id recovered, else picker)
```

`task-config show` / `task-config set` — which loadout this repo is on, and how to switch it (#219)

`task-config show` prints the assistant, the tracker, that tracker's settings and
the paths carrying them. Unlike every other task-force command it never refuses —
it *describes and signals*: a repo with **no** loadout, a repo with **two**, and an
`--impl` pinning a loadout that is not configured here are all printed in full and
all exit non-zero, so a script can still branch. A confusing repo is exactly when
you reach for this command, so refusing to print would defeat it.

```bash
task-config show
task-config set assistant kiro      # same tracker, swap the assistant
task-config set tracker local       # same assistant, swap the tracker
task-config set loadout claude-gh   # swap both at once
```

A `set` detects the current loadout, carries the tracker settings off its
workflow doc, removes that loadout's artifacts, then delegates the install to
`<new-loadout>/bin/task-init --force`. It never writes an artifact itself.
`--dry-run` prints the plan and changes nothing; a TTY run confirms first, and
`--yes` skips the prompt. In an ambiguous repo, `--impl <name>` says which
loadout to replace. A **`set`** whose `--impl` (or `$AW_IMPL`) names a loadout that
is **not** configured in this repo is refused rather than believed: before #227 the
pinned name was taken at face value and the target installed *beside* the untouched
old loadout, producing the very two-loadout state it exists to prevent. `show` never
refuses, so it annotates and signals instead —
`loadout   : kiro-gh  (NOT configured here — pinned via --impl / $AW_IMPL)`, exit 1 —
because with no doc to read, its `tracker` line would otherwise say
`unset — fill in <path>` and invite you to edit a file that does not exist.

Removal takes out **only** task-init's own entries. Your own `CLAUDE.md` sections
survive with just the `@.claude/notion-workflow.md` import line gone; your own hooks
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

**Both assistants, one active (#293).** claude's files live under `.claude/` and
kiro's under `.kiro/`, so the two loadouts on one tracker can be installed side by
side and committed once. Which one runs is then a local choice, not a commit:

```bash
task-config add assistant kiro   # install the other one beside this, settings carried
task-config use kiro             # the active assistant: local git config, no tracked file
task-config sync                 # make the two docs' tracker settings agree again
task-config remove assistant kiro  # drop one again: the mirror of add, the kept one goes active
```

`add` keeps the assistant you are on active, so nothing changes until you `use`
the other. Both change only the main checkout: a live worktree keeps the files
it was forked with, so `add` and `use` end with a warning listing every worker
worktree that has no radio hooks for the new assistant, each with its
`git -C <worktree> merge <base>` (#304). A warning only; `task-recreate-worker`
is what refuses. The choice lives in `git config task-force.assistant`, which linked
worktrees share. Detection reads `--impl` > `$AW_IMPL` > a launcher's `--agent` >
the active assistant > a single match, and the active assistant only resolves two
loadouts on **one** tracker: two trackers stay refused. With both installed and
none active, every dispatcher refuses and names `task-config use`. `show` marks the
active loadout and flags **drift**, a tracker setting the two workflow docs disagree
on. `sync` resolves it: the active assistant's doc wins, or `--from <assistant>`
picks the other one, and only the other doc is re-rendered. On a dual repo,
`set assistant A` is refused and changes nothing, `--yes` or not (#303): A is
already installed, so the switch is `use A` and dropping the other is
`remove assistant <other>`, which previews its deletions and confirms on a TTY.
`set loadout` onto the same tracker is refused the same way; onto another tracker
it replaces both, and `set tracker` is refused with the two steps that do it.
`show` prints the switch in one line: `task-config use <other>`, or
`task-work … --agent <other>` for one launch.
`task-remove` removes both and clears the setting. jira cannot be dual until a
kiro-jira loadout exists (#92).

On **this** loadout the carried settings are the three Notion database IDs:
`task-init` takes them as `--tasks` / `--projects` / `--board` (#225), so a
`claude-notion ↔ kiro-notion` switch passes them forward and you never re-paste
them. `--tasks` / `--projects` accept the `collection://<id>` that
`task-config show` prints, or the bare id.

`task-remove` — take task-force back out of this repo (#220)

The same removal walk a `task-config set` performs, with no install after it. Two
situations want it: the project is done and the workflow config is dead weight, or
you are about to open a PR against a repo that does **not** use task-force, where the
diff would otherwise carry `.claude/commands/`, a `.claude/settings.json` hook merge,
the `@.claude/notion-workflow.md` import line in `CLAUDE.md` and a workflow doc
nobody upstream asked for.

```bash
task-remove --dry-run              # the plan, changing nothing
task-remove --yes                  # no prompt (a TTY run previews, then asks)
task-remove --purge --dry-run      # what the override would additionally take
```

It takes out what a switch takes out — same keep-bias, same `<doc>.bak`, your own
`CLAUDE.md` sections and `settings.json` entries untouched — plus one artifact a
switch has no business touching: the `commit-msg` ci-guard hook `task-work` installs,
restoring a pre-existing hook the chain-install preserved as `commit-msg.local`. Only
a hook carrying task-force's own marker is removed. With no `--impl` it removes
**every** loadout detected in the repo, because leaving one behind is the multi-match
state every dispatcher refuses on; an `--impl` / `$AW_IMPL` naming a loadout that is
not configured here is refused rather than reported as removed (#227). It does
**not** touch the `~/.local/bin` symlinks
or the shell-rc `PATH` line — that is the *global* install, shared by every repo on
this machine — nor live worktrees or `~/.task-force` radio state, which
`task-done --remove-worktree` owns.

`--purge` deletes what the default keeps and reports: a role file that differs from
the copy the loadout ships (which fires on a merely **stale** install too, not only
on a real customization), the `<doc>.bak`, and the `tasks/` backlog. It does not
widen removal to files that are only partly ours — `CLAUDE.md` still loses only its
import line. Run without it first and read the list; the run points at `--purge` only
when there is something it would actually take. That ordering is the safety argument.

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

`task-monitor-snapshot` — the board as JSON: in flight, next, done, and whether this repo needs you (#273)

It prints one JSON document (`"schema": 1`, documented in task-force's
`docs/task-monitor-schema.md`) and is the data layer of task-monitor. Every
value comes from disk, the tracker or the forge, and no model is asked to write
or summarise any of it.

- **In flight** is every worktree whose `.<slug>.info` sidecar exists, joined to
  its radio session, its PR and the latest review intent. The worktree must
  still be live (its directory exists and `git worktree list` has it): a
  sidecar left behind by a removal that bypassed `task-done` is listed under
  `orphans` instead (#286).
- **Next** is the PM's queue, else the tracker's backlog (gh project items in
  none of the three statuses, or the local `tasks/` files). There is none on
  jira or notion.
- **Done** is the merged PRs that delivered an item in the last 24 hours, or
  the last 10, whichever is more.
- **Attention** fires on exactly three signals: an unread PM inbox, a finished
  review on a still-open PR that the PM has not answered, and a worker in
  `awaiting`. The `awaiting` signal is claude-only: kiro-cli (checked on
  2.32.0) has no hook that fires while it waits on the user (#278).

```bash
task-monitor-snapshot --json            # this repo
task-monitor-snapshot --all             # every repo radio knows about
task-monitor-snapshot --local           # no forge calls: disk + the last full run's cache
```

`task-monitor` — the board, live, in the terminal (#276)

The ratatui front end over that JSON. It opens on the repo view (In flight /
Next / Done) inside a repo, and on the all-repos overview (`a`, or `--all`)
outside one: one row per repo with its attention light, the signal in words,
and the zellij session it runs in, and under it one line per agent: the PM,
each in-flight worker and the reviewers nested under their item, each with its
agent, state icon and status (#287). `← you` marks the agent behind a signal:
the PM for unread mail or a review waiting on merge, the asking worker for
`awaiting`. A change under radio's state or a worktree
sidecar refreshes it from disk at once (`--local`); forge state refreshes every
45s (`--poll SECS`). A failed or slow refresh never blanks the screen: the last
good snapshot stays up, marked `stale`. Keys: `↑↓` move, `⏎` expand (a done
item's full PR body, scrollable) or enter a repo, `o` open the PR or issue, `t`
jump to the item's tab (the worker's, or the PM's for a queued or done item; on
the overview, the selected agent's), `!` show only the agents that need you,
`a` toggle the overview, `q` quit. `t` goes to a tab only while the tab at the
recorded id still bears the item's name, the check `task-done` makes before
closing one (#260). A tab in another zellij session is checked the same way,
then reached with `zellij action switch-session <session> --tab-position`: the
client moves and the monitor keeps running in its own session, so come back
through zellij's session manager. A failed check switches nothing and says why
(#287). When a worker's tab is gone, `t` says `tab gone · R to recreate`, and
`R` on that worker runs `task-recreate-worker <slug> --session <session>` from
the repo's main checkout with its loadout, then goes to the new tab the way `t`
does (#291). The session is the repo's (its PM's), not the monitor's; one that
is not running is refused, never created. Only `R` recreates, since a fresh
agent costs tokens and parked work is often parked on purpose, and its
refusals (a live tab, a fresh heartbeat) land in the status line. Reviewers
are not recreated. It holds no
task-force logic: every value is a snapshot field. A loadout's
`install.sh` builds and links it when `cargo` is on PATH, and skips it with one
line when not (#277). Its Next section is the queue the
PM writes with `task-monitor-queue`, below, else the tracker's backlog.

`task-monitor-queue` — the PM's short-term queue, the board's **Next** (#275)

The PM writes it when it and the user agree on what comes next. Each call
answers with one line, and the PM never reads it back: that is its whole board
cost. `task-work` takes the ref it dispatches off the queue itself, so nobody
has to `rm` a dispatched item.

```bash
task-monitor-queue set <ref>... [--note <ref>=<text>] [--title <ref>=<text>]   # replace, in order
task-monitor-queue add <ref>...                                                # append
task-monitor-queue rm <ref>...                                                 # drop
task-monitor-queue clear                                                       # empty
task-monitor-queue                                                             # show it
```

Refs are compared by their last path segment, ignoring a URL's query string
and fragment, so `267`, `#267` and an issue URL ending in `/issues/267` are one
item. `set` keeps the note of a ref that stays queued; `--note <ref>=` clears
it. `--note` splits on the first `=`, so a ref that contains `=` cannot take a
note.

`--title <ref>=<text>` gives a queued item its short name (#306), for trackers
the shell cannot read: on jira and notion a queued row has no title of its own.
The PM passes the name it already knows from the conversation, never fetching
anything to find it, and leaves `--title` off when it knows none. It follows
`--note`'s rules: `set` and `add`, repeatable, kept across a `set`, cleared by
`--title <ref>=`. The board uses it only where the tracker has no real title,
so gh and local keep their own. With none, a Notion page reads
`notion:…589b5b1c` and a Jira browse URL its key; `o` still opens the URL.

### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker prompts shell out to
`radio send` at every documented handoff point:

| From    | When                            | Command                                                                |
|---------|---------------------------------|------------------------------------------------------------------------|
| Planner | spec written into the task page | `radio send --to pm --intent spec-ready --issue <task-slug>`           |
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
place it is guaranteed to is the role's own tab. Run this **there**:

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
the current zellij tab to `pm-<reponame>`, registers that repo-scoped role via
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

Workers are the other way round: `task-work` launches them auto-submitting and
leaves focus on your tab, because the PM's tab is where you work and nobody
types in a worker's. The one exception is a worker you step into to steer by
hand — launch that one with `--no-auto-submit`.

### Reviewer role (single-shot, self-cleaning)

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> <notion-spec-url>` from any spare tab (add
`Bash(task-reviewer *)` to your project's `.claude/settings.json`
`permissions.allow` so the PM dispatches hands-off without a permission
prompt). It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet 5.5 (`claude-sonnet-5-5`; pre-set `ANTHROPIC_MODEL`
to override), cross-checks
the PR against the Notion spec page (PR-body auto-detect is GitHub-only, so pass
the URL explicitly — without it the review is diff-only), runs the `code-review`
skill on the diff, posts **one** thorough PR comment via
`gh pr comment --body-file -` carrying its full analysis + verdict, and radios
PM back with
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

The session file is a soft cache, not the source of truth (#188). Three tiny
sidecars sit beside it — `<role>.loadout`, `<role>.agent` and `<role>.auto-submit`
(#246) — holding the values a re-seed cannot read out of the `.info` file it
is replacing, and they deliberately **survive `unregister`**, `task-done`'s
`--manual` one included.
Only a genuine `register` overwrites them, and `radio gc` reclaims them once
the role has no session file left at all. So when a wipe is followed by a
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
| `radio check` sitting unsubmitted in a prompt box | The wake was delivered but not submitted: that role's session file has no `AUTO_SUBMIT=1`, so the wake ended with LF instead of CR (#189). Press Enter to finish this one. On a **PM** that is the default since #254 — the box is yours, and a submitting wake would send whatever you had half-typed; relaunch with `task-pm --auto-submit` only if the PM is meant to run unattended. On a **worker** it is not the default: it was launched with `--no-auto-submit`, or registered before #254 without `--auto` / `--auto-submit`. Relaunch it with plain `task-work` (or `task-recreate-worker --auto-submit`) to stop it recurring. The flag is read off the **recipient's** file, after any `--also` alias hop. |
| A role keeps vanishing from `sessions/` | Session flapping — something fires a session-end wipe on an intra-session event and takes `TAB_ID` with it. Compare `grep -c 'unregister role='`, `'unregister: proceeding'` and `'unregister: skipping'` in the log: post-#187 `skipping` should carry the bulk of the traffic, and `role=` should be close to `proceeding` plus however many `--manual` calls were made. A gap has two causes, and `--manual` is the likelier: it short-circuits the block that emits *both* other lines, so it writes only `role=`, and anything calling it in a loop inflates that counter alone — a test suite that has not isolated `$TASK_FORCE_HOME` will do exactly this against your live role. Otherwise an **old `radio` binary** is on `PATH`, since every non-`--manual` call now logs one or the other; `PATH`'s `radio` is a symlink into a checkout, so run `ls -l "$(command -v radio)"` and confirm that tree is current. |
| `radio unregister` did nothing | Expected since #198, not a bug. With no payload naming a real exit it refuses, printing `refusing to wipe <role> … re-run with --manual` on stderr and logging a `skipping` line. Pass `--manual` if you meant to tear the session down. |
| PM merged but the worker never cleaned up | The `approved-and-merged` ping arrived after that worker had exited, so it was never delivered. Since #201 gc archives such mail instead of keeping a mailbox nobody will open alive forever — look in `~/.task-force/radio/dead-letter/<role>/`, and `grep 'gc: dead-lettered' ~/.task-force/radio/log` for everything it has archived. The message is intact with its id and frontmatter; only the worktree needs cleaning by hand. |
| A role idles on a message sitting in its own inbox | Fixed in #197. `BLOCKED_IDS=` in the session file records which ids the last stop-hook block was about, so a message arriving mid-drain earns its own continuation. In the log, `arrived during the drain turn` is a correct re-block; `no new message since the block` is the loop-breaker firing because the same ids were ignored twice. |
| `radio check` says nothing while mail is in the inbox, or a report lands `from: unknown` | The session has no `$TASK_FORCE_ROLE`: it never registered, which is what every resumed session looks like (the env was a command prefix on the original process, not an export). Fixed in #229 — `check` / `read` / `ack` / `send` now recover the role from disk or refuse loudly, and `radio register --role … --tab …` works without the env var. `grep 'recover-role:' ~/.task-force/radio/log` shows what was recovered or refused, and `grep 'register: no-op' ~/.task-force/radio/log` a hook that fired with an empty environment. |
| `task-done` says `no tab id captured` and leaves the tab open | The tab's id was never recorded at launch. Before #242 that capture failed silently; now `task-work` (and `task-reviewer` / `task-recreate-worker`) says so on stderr the moment it happens and logs why — `no-zellij-bin`, `not-in-zellij`, `no-jq`, `list-tabs-empty`, `race`, or `no-match` together with the tab names zellij reported. `task-done`'s skip line now also says which source was empty. `grep 'tab-id:' ~/.task-force/radio/log` — one line per missed capture, with the slug and the reason. A sidecar written before the capture existed (#117) has no `TAB_ID=` at all. Close the tab by hand; an unscoped `close-tab` closes whichever tab is focused (#107). |
| `task-done` says `Not closing zellij tab id=N: it is now '<name>'` and leaves the tab open | The sidecar's `TAB_ID` is stale: zellij restarted since it was captured, and the id now belongs to another tab. Before #260 `task-done` closed it anyway, killing whichever worker held it. A resume in place keeps the old id; `task-recreate-worker` rewrites it. `grep 'tab-close:' ~/.task-force/radio/log` names the tab that holds the id now. Close your own tab by hand; after a restart, recover workers with `task-recreate-worker` (or re-run `radio register --tab …` from the tab, which since #260 also rewrites a stale sidecar id). |
| A launch left you on the new worker's tab instead of your own | zellij opens a tab asynchronously and always focuses it, so the launcher's snap-back `go-to-tab` can land before the new tab has finished opening (#311). The launcher now re-checks for about 1.5s and issues `go-to-tab` again until your tab is active; it gives up after that and never fails the launch. `grep 'tab-focus:' ~/.task-force/radio/log` — `snap-back needed N go-to-tab(s)` is a race that was corrected, `snap-back failed after N go-to-tab(s)` one that was not, with the position that kept focus. More frequent on a loaded machine. `--focus` skips all of this. |

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
