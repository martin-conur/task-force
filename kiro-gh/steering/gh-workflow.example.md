## GitHub Projects Workflow (Kiro)

Copy this file to your project's `.kiro/steering/gh-workflow.md` and fill in your details.
Or run `task-init kiro-gh` in your project root to do this automatically.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

### GitHub CLI (`gh`)

This workflow uses the [`gh` CLI](https://cli.github.com) for issue / project / PR I/O. Verify you're authenticated:

```bash
gh auth status
```

If not, run `gh auth login` (needs `repo` + `project` scopes). The bundled PM / planner / worker agents shell out to `gh` directly via `execute_bash`. Mutations stay confirmation-gated; with `--trust-all` on `task-work`, every `gh` call is auto-approved.

#### Optional: GitHub MCP for richer Projects v2 mutations

`gh project item-edit` covers the common single-select / number / text mutations. If you frequently mutate iteration fields or want a higher-level Projects v2 API, add the GitHub MCP to each agent's `mcpServers` block (the bundled agents ship without it; add it back if you want it):

```json
"mcpServers": {
  "github": { "command": "npx", "args": ["-y", "@github/github-mcp-server"] }
}
```

Only when the MCP add-on is enabled: set `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment before running Kiro, and add `@github` to each agent's `tools` (and `allowedTools` to skip the confirmation). Without the add-on, no PAT is needed — `gh auth` covers it.

### GitHub Repository

- **Owner**: `{OWNER}` (GitHub user or org name)
- **Repo**: `{REPO}` (repository name)
- **Project number**: `{PROJECT}` (from the project URL: github.com/users/{OWNER}/projects/N or github.com/orgs/{OWNER}/projects/N)

### Task Lifecycle

Todo → In Progress → In Review → Done

- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review` (leave blank or omit if your project has no In Review column — the worker will keep the issue at `In Progress` through review)
- **Status when done**: `Done`

The worker reads these three values and updates the project item's Status field as it moves through the lifecycle: to "starting work" before implementing, to "in review" after opening the PR, and to "done" only after the PM signals `approved-and-merged` via radio.

### Task Properties

- **Title** (issue title), **Status** (project single-select field), **Priority** (project field)
- **Git commit** (URL — set to PR link after done)

### Commit Convention

Use the issue title as prefix: `<Issue title>: <short description>`

### Shell Commands

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker agent

- `-m, --model MODEL` — pick a specific kiro model
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs without per-tool confirmation
- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `--no-launch` — open the worktree tab but do NOT start kiro
- `--auto` — opt this worker into radio's auto-submit wake-up: an incoming ping submits itself instead of sitting in the prompt box until someone presses Enter. Auto-submit **only** — the permission model stays `-a/--trust-all` (#206)

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/{OWNER}/{REPO}/issues/42"
task-work https://github.com/{OWNER}/{REPO}/issues/42
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work issue-99 --from task/issue-46 --base main         # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)

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
- `--auto` — radio auto-submit plus keeping focus on the tab you ran it from;
  on claude it also launches in auto permission mode, on kiro it governs
  auto-submit only, exactly as `task-work --auto` does on each (#206).
- `--no-launch` — open the tab, start nothing; the role stays unregistered.
- `--force` — proceed although a session still looks live.

It refuses when the role still looks live: a zellij tab of that name is open, or
the session file's heartbeat is newer than an hour (it asks `radio orphans`
rather than re-deriving the threshold). The first hour after a reboot looks
exactly like a live session, which is what `--force` is for — read the refusal
first, it names which of the two signals fired.

The sidecar's `TAB_ID` is **stripped before the tab is spawned** and rewritten
afterwards, never carried over: zellij's server restarted, so that id is stale by
definition, and `radio register` adopts it from that file when its own name
lookup misses (#218). Stripping it first means a register that beats us to the
write finds nothing to adopt and resolves the new tab by name instead.

```bash
task-recreate-worker issue-223           # fresh session; tab, role and mail rebound
task-recreate-worker issue-223 --auto    # hands-off; focus stays where you are
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
task-config set assistant claude      # same tracker, swap the assistant
task-config set tracker local         # same assistant, swap the tracker
task-config set loadout kiro-notion   # swap both at once
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

Removal takes out **only** task-init's own entries. An agent config is deleted
only once its radio hooks are stripped and what remains still matches the copy
the loadout ships — a `.kiro/agents/<role>.json` you have **edited** keeps your
edits and loses just our hooks, because task-init's `keep` policy means it merges
those hooks into a file that may be yours (#218/#222). Any inert pre-#218
`.kiro/hooks/radio-*.json` goes; an agent or hook of your own beside them is never
touched, and keeps its directory. On the local loadouts the `tasks/` scaffolding
goes but **your backlog does not** (the run says how many files it kept), and a
directory is reclaimed only once removal has actually emptied it. The workflow doc
itself has to go — it is the detection key — but repo-specific sections below the
managed-region end marker are copied to `<doc>.bak` first.

Settings carry across a `set assistant` — claude and kiro render the same
template shape per tracker — and cannot across a `set tracker`, because different
trackers share no fields at all, so `task-init` prompts for the new ones exactly
as on a first install. `kiro-jira` is refused by name: the assistant × tracker
grid has exactly one hole (#92).

`task-remove` — take task-force back out of this repo (#220)

The same removal walk a `task-config set` performs, with no install after it. Two
situations want it: the project is done and the workflow config is dead weight, or
you are about to open a PR against a repo that does **not** use task-force, where the
diff would otherwise carry `.kiro/agents/`, any inert `.kiro/hooks/radio-*.json` and
a `.kiro/steering/gh-workflow.md` nobody upstream asked for.

```bash
task-remove --dry-run              # the plan, changing nothing
task-remove --yes                  # no prompt (a TTY run previews, then asks)
task-remove --purge --dry-run      # what the override would additionally take
```

It takes out what a switch takes out — same keep-bias, same `<doc>.bak`, an agent
config of yours kept with only its radio hooks stripped — plus one artifact a switch
has no business touching: the `commit-msg` ci-guard hook `task-work` installs,
restoring a pre-existing hook the chain-install preserved as `commit-msg.local`. Only
a hook carrying task-force's own marker is removed. With no `--impl` it removes
**every** loadout detected in the repo, because leaving one behind is the multi-match
state every dispatcher refuses on; an `--impl` / `$AW_IMPL` naming a loadout that is
not configured here is refused rather than reported as removed (#227). It does
**not** touch the `~/.local/bin` symlinks
or the shell-rc `PATH` line — that is the *global* install, shared by every repo on
this machine — nor live worktrees or `~/.task-force` radio state, which
`task-done --remove-worktree` owns.

`--purge` deletes what the default keeps and reports: an agent config that differs
from the copy the loadout ships once its radio hooks are stripped (which fires on a
merely **stale** install too, not only on a real customization), the `<doc>.bak`, and
the `tasks/` backlog. It does not widen removal to files that are only partly ours.
Run without it first and read the list; the run points at `--purge` only when there
is something it would actually take. That ordering is the safety argument.

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
role transition runs through it. The PM / planner / worker agents shell out to
`radio send` at every documented handoff point:

| From     | When                              | Command                                                                          |
|----------|-----------------------------------|----------------------------------------------------------------------------------|
| Planner  | spec written into the issue       | `radio send --to pm --intent spec-ready --issue <N>`                             |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                          |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`                       |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`              |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`            |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`                     |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`             |

When a worker finishes its task and has nothing pending, the `radio ready` step
runs automatically via the `agentStop` hook — you don't need to invoke it
manually.

**Delivery here is pull-first — kiro agents mostly fetch rather than receive.**
The radio hooks live in the `hooks` field of each `.kiro/agents/*.json`, which is
where kiro-cli reads them. Before #218 they were written to `.kiro/hooks/`
instead — the Kiro *IDE*'s directory, which kiro-cli does not read — so none of
them ran at all: no role registered, and every `radio send` to a kiro role
returned `no session … message queued`. If you are on an older install, re-run
`task-init` to pick up the fix; nothing self-applies.

What you get now: `agentSpawn` registers the role, and its offline-backlog
summary **does** reach the model — kiro injects hook stdout (the long-standing
claim that it doesn't was an artifact of hooks that never ran). `userPromptSubmit`
is a plain `radio busy` with no inbox summary, and `stop` is a bare `radio ready`
with no block-and-drain, so a message that queues mid-session has no hook behind
it. Whether to wire those two up is #221, not a limitation.

So the agents still poll: every agent in `.kiro/agents/` carries a standing
instruction to run `radio check` at the start of each turn and `radio read <id>`
whatever it lists. If you are waiting on a handoff that seems not to have
arrived, prompt the recipient tab — its next turn starts with a check.

There is still no session-end trigger (`stop` fires per turn, not on session
close), so closing a tab leaves its session file behind still advertising
`STATE=idle`, and senders will keep trying to wake a tab that is gone.
`task-done` unregisters on the worker happy path; for everything else,
`radio orphans` is the cleanup step — see below.

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

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `agentSpawn` hook, and
starts the PM agent in-place.

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> [<issue-url-or-number>]` from any spare tab.
It spawns a fresh zellij tab + worktree on the PR's head ref, runs the kiro
`reviewer` agent, cross-checks the PR against the spec issue (passed as the
second arg, or auto-detected from the PR body's first `Closes #N` /
`Fixes #N` / `Resolves #N` line, case-insensitive), reviews the diff, posts a single thorough PR comment via
`gh pr comment --body-file -`, and radios PM back with `review-complete-clean` or
`review-complete-with-findings`. PM still owns the merge decision — the
reviewer never approves, merges, or mutates status. The reviewer tab stays
open showing the analysis; clean up with `task-done --remove-worktree` when
done.

If a worker tab dies unexpectedly, is closed without `task-done`, or kiro
resumes a session without re-firing the `agentSpawn` hook, the session file's
`LAST_HEARTBEAT` will go stale. Run `radio orphans` to list any session whose
heartbeat is older than 1 hour — those entries are safe to delete
(`rm ~/.task-force/radio/sessions/<role>.info`) or leave for the next
legitimate `radio register` to overwrite. Because there is no session-end hook
here, treat this as routine housekeeping rather than a crash-only step: a stale
session still reads as `STATE=idle` to senders, so radio will keep aiming wakes
at a tab that no longer exists.

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

A **resumed session registers nothing**, and that is not the hook's fault
(#229). claude's `SessionStart` does fire on a resume, and kiro's `agentSpawn` is the same entrypoint — verified against all four
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
  --repo "$(git rev-parse --show-toplevel)" --agent kiro --loadout <loadout>
```

It works with no `$TASK_FORCE_ROLE` since #229 — before that the dispatcher
discarded the call before ever reading `--role`, so the documented way out of a
roleless session was itself a silent no-op — and it now says on stderr whether
the role came back wakeable, warning explicitly when `TAB_ID` ended up empty.

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
| `radio check` sitting unsubmitted in a prompt box | The wake was delivered but not submitted: that role's session file has no `AUTO_SUBMIT=1`, so the wake ended with LF instead of CR (#189). Press Enter to finish this one. To stop it recurring, relaunch the PM with plain `task-pm` (auto-submit is the default; `--no-auto-submit` is the opt-out) or the worker with `task-work --auto` (#206; here that flag governs auto-submit only — the permission model stays `-a/--trust-all`). The flag is read off the **recipient's** file, after any `--also` alias hop. Auto-submit only makes a wake that *lands* complete itself; nothing backs up a wake that never lands, so the poll model below still carries delivery. |
| A role keeps vanishing from `sessions/` | Session flapping — something fires a session-end wipe on an intra-session event and takes `TAB_ID` with it. Compare `grep -c 'unregister role='`, `'unregister: proceeding'` and `'unregister: skipping'` in the log: post-#187 `skipping` should carry the bulk of the traffic, and `role=` should be close to `proceeding` plus however many `--manual` calls were made. A gap has two causes, and `--manual` is the likelier: it short-circuits the block that emits *both* other lines, so it writes only `role=`, and anything calling it in a loop inflates that counter alone — a test suite that has not isolated `$TASK_FORCE_HOME` will do exactly this against your live role. Otherwise an **old `radio` binary** is on `PATH`, since every non-`--manual` call now logs one or the other; `PATH`'s `radio` is a symlink into a checkout, so run `ls -l "$(command -v radio)"` and confirm that tree is current. |
| `radio unregister` did nothing | Expected since #198, not a bug. With no payload naming a real exit it refuses, printing `refusing to wipe <role> … re-run with --manual` on stderr and logging a `skipping` line. Pass `--manual` if you meant to tear the session down. |
| PM merged but the worker never cleaned up | The `approved-and-merged` ping arrived after that worker had exited, so it was never delivered. Since #201 gc archives such mail instead of keeping a mailbox nobody will open alive forever — look in `~/.task-force/radio/dead-letter/<role>/`, and `grep 'gc: dead-lettered' ~/.task-force/radio/log` for everything it has archived. The message is intact with its id and frontmatter; only the worktree needs cleaning by hand. |
| A role idles on a message sitting in its own inbox | Fixed in #197. `BLOCKED_IDS=` in the session file records which ids the last stop-hook block was about, so a message arriving mid-drain earns its own continuation. In the log, `arrived during the drain turn` is a correct re-block; `no new message since the block` is the loop-breaker firing because the same ids were ignored twice. |
| `radio check` says nothing while mail is in the inbox, or a report lands `from: unknown` | The session has no `$TASK_FORCE_ROLE`: it never registered, which is what every resumed session looks like (the env was a command prefix on the original process, not an export). Fixed in #229 — `check` / `read` / `ack` / `send` now recover the role from disk or refuse loudly, and `radio register --role … --tab …` works without the env var. `grep 'recover-role:' ~/.task-force/radio/log` shows what was recovered or refused, and `grep 'register: no-op' ~/.task-force/radio/log` a hook that fired with an empty environment. |
| `task-done` says `no tab id captured` and leaves the tab open | The tab's id was never recorded at launch. Before #242 that capture failed silently; now `task-work` (and `task-reviewer` / `task-recreate-worker`) says so on stderr the moment it happens and logs why — `not-in-zellij`, `no-jq`, `list-tabs-empty`, `race`, or `no-match` together with the tab names zellij reported. `task-done`'s skip line now also says which source was empty. `grep 'tab-id:' ~/.task-force/radio/log` — one line per missed capture, with the slug and the reason. A sidecar written before the capture existed (#117) has no `TAB_ID=` at all. Close the tab by hand; an unscoped `close-tab` closes whichever tab is focused (#107). |

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

When the wake itself fails there is nothing behind it. Kiro discards hook
output, so none of those backstops exist here — the zellij keystroke is the
only push path, and what actually makes delivery happen is each agent's own
standing `radio check` at the top of every turn. A queued message with no wake
is expected on kiro rather than a failure; it surfaces on the recipient's next
turn. Tell a kiro role apart by its `AGENT=` line
(`grep AGENT ~/.task-force/radio/sessions/<role>.info`).
