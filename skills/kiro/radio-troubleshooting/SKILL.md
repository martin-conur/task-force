---
name: radio-troubleshooting
description: Diagnose a radio (task-force PM/worker messaging) failure. Load it when `radio send` prints anything but `delivered` or `queued — … is busy` / `is awaiting`: `WARNING — no session for`, `wake failed`, `looks dead`; when `task-done` says `no tab id captured` or `Not closing zellij tab`; when a hook `timed out after 30s`; or when a role never woke, idles on unread mail, vanished from `sessions/`, or reports land `from: unknown`.
---

# Radio troubleshooting

The symptom → cause → check table for radio, the log greps that tell its
failure modes apart, where undelivered mail goes, and how radio keeps, recovers
and cleans up sessions. The workflow doc's
`### Radio troubleshooting` rule says when to load this.

<!-- region:radio-troubleshooting-body -->
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
<!-- endregion:radio-troubleshooting-body -->

When the wake itself fails there is nothing behind it. Kiro has no Stop drain
and no prompt-hook summary (#221), only the backlog report at a fresh register.
Mid-session the zellij keystroke is the only push path, and what actually makes
delivery happen is each agent's own
standing `radio check` at the top of every turn. A queued message with no wake
is expected on kiro rather than a failure; it surfaces on the recipient's next
turn. Tell a kiro role apart by its `AGENT=` line
(`grep AGENT ~/.task-force/radio/sessions/<role>.info`).

Auto-submit is the default here and independent of the permission model,
which stays `-a/--trust-all` (#206). It only makes a wake that *lands*
complete itself; nothing backs up a wake that never lands, so the standing
`radio check` above still carries delivery.

<!-- region:radio-internals -->
## How radio keeps, recovers and cleans up sessions

The workflow doc keeps only what each role sends. This is how radio keeps a role
addressable, for when that breaks.

**What the hooks do.** A fresh register (claude's `SessionStart`, kiro's
`agentSpawn`) prints a summary of any inbox that queued while the role was
offline, and that stdout reaches the model, so the backlog surfaces on the
role's very first turn. The re-registers a `/compact` or `/clear` triggers in the
same process are not fresh starts. On claude, the `Stop` hook (`radio
stop-hook`) blocks a stop while mail is unread, so the agent drains it; a
message that lands during that forced drain turn earns one more block of its own
(#197), because `BLOCKED_IDS=` records which ids each block was about, and an
agent that ignores the same ids twice is allowed to stop. `UserPromptSubmit`
(`radio prompt-hook`) injects the `[radio] N unread message(s): …` line. kiro
has neither of those two yet (#221).

**Literal-`pm` adoption (#182, #210).** Since #165 nothing registers as the bare
`pm`, so its inbox is write-only. A fresh `pm-<reponame>` with no live `pm`
session migrates that backlog into its own inbox, each message stamped with an
`adopted-from:` header, and flags it as adopted in the same summary. Only mail
whose `from:` names this repo — `worker-<reponame>-<slug>`,
`reviewer-<reponame>-pr<N>`, `pm-<reponame>` — is adopted; another repo's stays
in `mailbox/pm/inbox` for its own PM, and the log counts what was left behind.
Mail no name can attribute (`from: unknown`) is adopted first-come, and the log
says so.

**A resumed session registers nothing (#229).** The hook does fire on a resume —
verified against all four sources, `startup` / `resume` / `compact` / `clear` —
but a resume is a new process, and the identity env was a command prefix on the
one `task-work` launched (`bash -ic "TASK_FORCE_ROLE=… ZELLIJ_TAB=… claude …"`),
living in no shell. The hook runs with an empty environment, the unquoted
`--role $TASK_FORCE_ROLE` collapses to nothing, and register no-ops, logging
`register: no-op`. `/compact` and `/clear` keep the process, so their
re-registers really happen.

So `radio` **derives the role from disk** instead of acting anonymously. In a
worktree, `<worktree-base>/.<slug>.info` plus the main repo name rebuild
`worker-<reponame>-<slug>` (or `reviewer-<reponame>-pr<N>`, whose tab slug is
`review-pr<N>`) exactly as `task-work` / `task-reviewer` built them. In a main
checkout the repo name gives `pm-<reponame>`, only when that role has radio
state on disk, so a plain session in the repo root never claims the PM's
address; and no candidate is claimed while its session file carries a fresh
heartbeat. `check` / `read` / `ack` / `send` announce a recovered role on stderr
and **refuse loudly** when nothing is derivable (`recover-role:` in the log).
Hook entrypoints stay silent (#93).

Recovery does not register, because a register whose tab lookup misses writes an
empty `TAB_ID`, which is worse than no session at all. The lookup is by tab
name, and the only place it is guaranteed to resolve is the role's own tab. Run
the repair **there**, in the agent's own pane (claude's `!` prefix): register
also records `$ZELLIJ_PANE_ID` as the pane wakes go to (#336), and from any other
pane it keeps the pane already on file and logs `is not the agent's pane`:

```bash
radio register --role <role> --tab <tabname> \
  --repo "$(git rev-parse --show-toplevel)" --agent <claude|kiro> --loadout <loadout>
```

It needs no `$TASK_FORCE_ROLE`, says on stderr whether the role came back
wakeable (warning when `TAB_ID` ended up empty), and keeps the role's
auto-submit setting (#246). That repairs a **resumed** session, whose tab ids
are still the live server's. After a zellij **restart** every tab was
renumbered, and `<worktree-base>/.<slug>.info` — the record `task-done` closes
the tab by — still names the old id, which may now belong to another worker's
tab. Use `task-recreate-worker`, which rewrites it (#218). A hand `register`
that resolves the tab live from zellij also rewrites a stale sidecar `TAB_ID`
(#260), and `task-done` closes a tab only while it still bears its slug.

**The session file is a soft cache (#188).** Three sidecars sit beside it —
`<role>.loadout`, `<role>.agent` and `<role>.auto-submit` (#246) — holding what
a re-seed cannot read out of the `.info` file it replaces. They survive
`unregister`, `task-done`'s `--manual` one included, and only a genuine
`register` overwrites them. `task-done --remove-worktree` removes its own role's
set (#375), and `radio gc` reclaims those of any role with no session file. So a
wipe followed by a `busy` / `ready` self-heal keeps the real `LOADOUT` / `AGENT`
instead of `unknown` / `claude`, and recovers `TAB_ID` from the task-work-owned
`<worktree-base>/.<slug>.info` when the zellij lookup misses. An empty `TAB_ID`
makes a role unwakeable — `radio send` then queues with no wake attempt — and is
written only when there is no binding anywhere (non-zellij, CI), which the log
says distinctly.

**Auto-submit is tri-state at register.** `TASK_FORCE_AUTO_SUBMIT=1` is on, any
other non-empty value is an explicit off (launchers say `0`), and **unset**
restores what the sidecar recorded. Every launcher states its choice, so only a
hand `radio register` from a plain shell inherits. A runtime `radio auto-submit
on|off` (#385) rewrites the session file and the sidecar and outranks the launch
setting on every re-register: `on` holds through a `/compact`, a `/clear` and a
fresh PM start until its expiry or an `off`; an `off` gives way to a fresh
launch that states its own setting. An expiry is stored as
`AUTO_SUBMIT_UNTIL=`, and the first send after it types LF again, logs
`auto-submit: expired role=…` and clears the setting.

**Cleanup.** A tab that died, or a session resumed without re-registering,
leaves its session file's `LAST_HEARTBEAT` stale. `radio orphans` lists every
session over an hour stale; delete those
(`rm ~/.task-force/radio/sessions/<role>.info`) or leave them for the next
legitimate `radio register` to overwrite. `radio unregister` on its own is not
a cleanup command (#198): with no `SessionEnd` payload naming a real exit on
stdin it refuses on stderr, whatever shape that stdin has. `--manual` tears the
session down, which is what `task-done` does. A fresh register runs a quiet
`radio gc` (14-day default, #169): it dead-letters a gone role's aged mail and
reclaims the mailbox (above), expires old `processed/` messages on live roles,
and rotates the top-level `log` once it passes ~1MB, so no cron is needed.
`radio gc --dry-run` previews a sweep, and `radio gc --max-age-days N` sets the
window. `task-done --remove-worktree` also sweeps its own role's mailbox.

**`$TASK_FORCE_HOME`** (default `~/.task-force`) holds all of radio's state:
sessions, mailboxes, the log. Point it at a scratch directory to probe or test
without touching live roles. `task-work`, `task-reviewer` and
`task-recreate-worker` pass a set value into the tab they open, because a new
zellij tab starts from the zellij server's environment and not yours (#262);
`task-pm` runs in place and inherits it. When it is unset nothing is passed, and
the default applies.
<!-- endregion:radio-internals -->

**kiro's hooks.** They live in the `hooks` field of each `.kiro/agents/*.json`,
which is where kiro-cli reads them. Before #218 they were written to
`.kiro/hooks/`, the Kiro *IDE*'s directory, so none of them ran: no role
registered, and every `radio send` to a kiro role returned `no session … message
queued`. On an older install, re-run `task-init`; nothing self-applies.
`postToolUse` runs `radio heartbeat` on every tool call, which refreshes the
heartbeat and nothing else (#322). There is no session-end trigger (`stop`
fires per turn, not on session close), so a tab closed without `task-done`
leaves its session file still advertising `STATE=idle`, and senders keep aiming
wakes at a tab that is gone. `task-done` unregisters on the worker happy path;
for everything else, run `radio orphans` as routine housekeeping here, not as a
crash-only step.
