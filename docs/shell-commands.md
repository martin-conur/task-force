# Shell commands: background and history

Until #397 every workflow doc carried this whole reference, about 37 KB that
every PM, planner, worker and reviewer session loaded and almost none of them
needed. The workflow docs now keep one index line per command. Each command's
`--help` is the reference for what it does and which flags it takes; this file
keeps the long form: why each behaviour is there, the incidents behind it, and
the log lines that tell one failure from another.

It is written for the claude-gh loadout. Where another loadout differs, the
difference is in [Loadout differences](#loadout-differences) at the end. The
`@.claude/<tracker>-workflow.md` and `.kiro/steering/<tracker>-workflow.md`
paths below stand for the loadout's own workflow doc.


## task-work

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`). Refused when `REF` lacks the radio hooks `HEAD` carries for the agent (#304): a worktree forked from it would start an agent that never registers. Merge the base into `REF` first
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); permission mode only, mutually exclusive with `--plan`
- `--auto-submit` — radio auto-submit: an incoming wake submits itself instead of waiting in the prompt box for an Enter. **The default** on every launch, `--plan` included, since nobody types in a worker's tab (#254); the flag only makes a launch line explicit
- `--no-auto-submit` — keep the Enter gate on radio wakes. Use it for a worker you mean to step into and steer by hand: a wake would otherwise submit whatever is half-typed in its box
- `--focus` — switch to the new tab. By default focus stays on the tab you ran `task-work` from, so the PM can dispatch without being pulled away (#254)
- `--agent <claude|kiro>` — launch this one worker on the other installed assistant, leaving the repo's active one alone (#293). Both loadouts must be installed (`task-config add assistant`, below). `task-pm`, `task-reviewer` and `task-recreate-worker` take it too, and `task-recreate-worker` without it relaunches on the assistant `task-work` recorded for that worker
- `--profile <name>` — launch the agent with an agent profile from `~/.task-force/profiles.toml`: a gateway's base URL, model pins, and the variable its key is read from (#355, below). `task-pm`, `task-reviewer` and `task-recreate-worker` take it too. Claude-only
- `--no-launch` — open the worktree tab but do NOT start Claude
- `--no-task` — launch with no task ref on purpose. Without it a bare slug is refused, since the worker would start with no spec (#371). `--no-launch` and `--plan` need no ref and no flag: one starts nothing, the other runs the planner that writes the spec

The slug argument is checked before anything is created (#371): one that holds whitespace, `://` or a GitHub / Notion / Jira URL this tracker does not read is refused. So `"<slug> <url>"` passed as one argument, which an unquoted variable in a zsh loop does, names the split (`did you mean: task-work <slug> <url>?`) instead of becoming a 50-character slug with no spec. A slug over 50 characters is still truncated, now with a warning.

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/owner/repo/issues/42"
task-work https://github.com/owner/repo/issues/42
task-work refactor-auth --plan
task-work https://github.com/owner/repo/issues/99 --from task/issue-46 --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
task-work spike-idea --no-task                  # deliberately no spec
```

## task-done

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
without taking it along. It never stops them itself; that is the PM's or your
call. On a kiro worker or reviewer the tab's own supervisor does it once the tab
has closed (#388, below), so what is left to list is a claude agent, a tab
launched before #388, or a process the supervisor could not stop.
Run from the worker's own tab, the worker itself is not listed, since its whole
process tree goes with the tab. Run from anywhere else, the PM's tab included, a
worker that is still up is listed too, and is not necessarily stray. The warning is also logged, because that tab closes and takes it
along: `grep 'stray-procs:' ~/.task-force/radio/log`.

The radio state `task-done` takes down (session, mailbox, sidecars) belongs to
the **worktree's own role** and no other (#377): `worker-<repo>-<slug>`, or
`reviewer-<repo>-pr<N>` for `review-pr<N>`. Run from the PM's tab after a `cd`
into a worker's worktree, or from a resumed session with no `$TASK_FORCE_ROLE`
(#232), it derives that role from the worktree's `.<slug>.info`, says so on
stderr and leaves the caller's own role alone. It refuses a derived role whose
session file names another worktree, or that is still alive: agent processes
are running in the worktree, by the same scan as the warning above (the
caller's own agent is never counted). With `TASK_FORCE_NO_PROC_SCAN=1` it falls
back to the heartbeat, refusing one under an hour old (`radio orphans` does not
list it). With no `.<slug>.info` to derive from, it says so and points at
`radio orphans`. The worktree and the tab go either way. Each decision is
logged: `grep 'task-done-role:' ~/.task-force/radio/log`.

## Agent profiles (`--profile`)

**Agent profiles** — `--profile <name>` on `task-work`, `task-reviewer`, `task-recreate-worker` and `task-pm` (#355)

A profile runs Claude Code through an Anthropic-compatible gateway (an open model on Fireworks, say). It lives in `$TASK_FORCE_HOME/profiles.toml` (default `~/.task-force/profiles.toml`), one table per profile. This is the worked example from the #354 spike (`docs/agent-profiles-spike.md`):

```toml
[profiles.fireworks-glm]
agent   = "claude"
model   = "glm-latest"
env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }
key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }
# pin = { sonnet = "…", haiku = "…", opus = "…", subagent = "…" }   # each defaults to model
# max_context_tokens = 200000                                       # CLAUDE_CODE_MAX_CONTEXT_TOKENS
```

The launcher puts `env` on the tab's command line as given, pins `ANTHROPIC_DEFAULT_SONNET_MODEL`, `_HAIKU_`, `_OPUS_` and `CLAUDE_CODE_SUBAGENT_MODEL` to `model` unless `pin` names another (an unpinned Sonnet tier sends the auto-mode classifier to `claude-sonnet-5`), and sets `ANTHROPIC_MODEL` as well as `--model`, so on `task-reviewer` the profile's model wins over its Sonnet default. **The key is never on a command line or in a file.** The prefix carries `ANTHROPIC_API_KEY="${FIREWORKS_API_KEY:?…}"`, which the tab's `bash -ic` expands from your shell rc: export the variable there. Only `ANTHROPIC_API_KEY` is accepted. `ANTHROPIC_AUTH_TOKEN` is refused, because with it Claude Code also sent the machine's saved Anthropic Console key to the gateway (spike, section 6). A key in `env` is refused too.

Each launcher refuses, before it creates anything, an unknown profile, a profile with no `model` (required: every tier defaults to it), a profile whose `agent` is not the one being launched, a `key_env` variable that is unset or empty in your shell, and a file that does not parse (task-force reads a TOML subset: tables, one-line strings, integers, booleans, one-line inline tables). The profile's **name** is recorded as `PROFILE=` in the worker's `.<slug>.info` sidecar and in radio's `<role>.profile` sidecar and session file; `task-recreate-worker` relaunches on it unless `--profile` or `--no-profile` says otherwise, and task-monitor shows it beside the agent. Without `--profile` nothing changes.

**Default profile for reviews** (#357). `task-reviewer` with no `--profile` reviews on **Reviewer profile** when it names one, and says so when it launches; `--no-profile` skips it for one review. `none`, the default, is the Sonnet reviewer as before. Profiles are claude-only, so a kiro reviewer ignores it. Write it with `task-init --set "Reviewer profile=<name>"`, or below the managed-region end marker; the last bullet wins. A name that does not resolve refuses the review, as `--profile` would, and the refusal names the setting.

The workflow doc carries the bullet, `none` by default:

```
- **Reviewer profile**: `none`
```

Two things need a human or the gateway. The first auto-mode session through a gateway on a machine shows Claude Code's classifier billing notice and waits for `y`, which holds a hands-off worker once. And Claude Code's cost display and `modelUsage` miss the classifier's calls and misprice unknown models: check routing and cost on the gateway's side.

### task-config profile

**Writing and checking one** — `task-config profile add|list|show|test|remove` (#356)

You need not write the table by hand. `add` writes one, from a preset or from `--base-url`, and checks it with the same reader the launchers use before it writes anything, so it cannot write a profile a launch would refuse. `test` makes one short `claude -p` run through it, in a throwaway directory with no radio role, and reports auth, the model that answered, one tool call and the time taken; it exits non-zero with the gateway's error, or after 60s with no answer (`--timeout <secs>`, `$TASK_CONFIG_PROFILE_TEST_TIMEOUT`). Neither prints the key: `show` says only whether its variable is `set` or `unset`. `add --force` replaces a profile where it stands, and `add` and `remove` leave every other line and comment of the file as it was. Presets live in `lib/profile-presets.toml`: `fireworks` (the spike's base URL and `ENABLE_TOOL_SEARCH=true`, every tier on `--model`) and `anthropic`. OpenRouter and LiteLLM have none, because both document Claude Code only through `ANTHROPIC_AUTH_TOKEN`, which profiles refuse.

```bash
task-config profile add fireworks-glm --preset fireworks --model glm-latest --key-env FIREWORKS_API_KEY
task-config profile test fireworks-glm
task-config profile add my-gw --base-url https://gw.example/anthropic --model m --key-env GW_KEY --pin haiku=small
task-config profile list
task-config profile show fireworks-glm
task-config profile remove my-gw
```

## task-recreate-worker

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

**A kiro tab now takes its processes with it** (#388). kiro's backend runs in a
session of its own with no terminal, so a tab close, however it happens
(`close-tab`, a closed pane, `task-done`, a killed zellij session), HUPs the
front end and never reaches the backend. Probed on kiro-cli 3.1.0: the V3
engine's `…/kiro-cli/node … acp-server.js` outlived every one of those
closes, reparented to pid 1; V2's `kiro-cli acp` outlived it by a few
seconds. So `task-work`, `task-recreate-worker` and `task-reviewer` launch kiro
under `bin/agent-supervise`, which runs the agent as its child, survives the
HUP, and once the agent has exited stops the worktree's agent processes by this
same scan: TERM, then KILL, with the same start-time re-check. It logs each one:
`grep 'reap:' ~/.task-force/radio/log`. It reaps only in a linked worktree,
never a main checkout, so the PM is not supervised. `TASK_FORCE_NO_REAP=1` in
your shell turns it off. claude goes with its tab and is launched as before.
The scan also learned to see kiro's own `bun` and `node` under macOS's
`Application Support` path, whose space hid an orphaned backend from it.

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

## task-config

`task-config show` / `task-config set` — which loadout this repo is on, and how to switch it (#219)

`task-config show` prints the assistant, the tracker, that tracker's settings and
the paths carrying them. Unlike every other task-force command it never refuses —
it *describes and signals*: a repo with **no** loadout, a repo with **two**, and an
`--impl` pinning a loadout that is not configured here are all printed in full and
all exit non-zero, so a script can still branch. A confusing repo is exactly when
you reach for this command, so refusing to print would defeat it.

```bash
task-config show
task-config set assistant kiro          # same tracker, swap the assistant
task-config set tracker local           # same assistant, swap the tracker
task-config set loadout claude-notion   # swap both at once
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
survive with just the `@.claude/<tracker>-workflow.md` import line gone; your own hooks
and allow-list entries in `.claude/settings.json` survive with just the
radio-owned ones gone; a `.claude/commands/<role>.md` you have edited is **kept**
rather than deleted, because task-init's `keep` policy means that file may be
yours, and so is an edited `.claude/skills/<name>/SKILL.md` or
`.kiro/skills/<name>/SKILL.md` (#398); on the local loadouts the `tasks/` scaffolding goes but **your backlog does
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

## task-init --local-only

**Local-only install** — `task-init claude-<tracker> --local-only` (#327)

For a repo where nothing task-force-related may reach a branch. The same
artifacts are written untracked: hooks and the allow-list go to
`.claude/settings.local.json`, the import to `CLAUDE.local.md`, and every path
task-init writes is listed in a block of `.git/info/exclude`, which every
worktree shares and nothing commits. `git config task-force.install local-only`
records the mode, and every later `task-init` (a re-run, a `task-config set`)
honours it without the flag. `task-work`, `task-reviewer` and
`task-recreate-worker` copy the set from the main checkout into each worktree
before the agent starts, missing files only, and #304's hook check accepts a
`radio register` hook in `settings.local.json`. A worker's PR carries none of
it. `task-remove` takes it back out, exclude block and git config included.
claude only: kiro has no untracked hook location, so a kiro install is refused
on a local-only repo, and `--local-only` on a kiro loadout.

## task-init --set

**Any setting from the command line** — `task-init <loadout> --set "<setting>=<value>"` (#346)

Every setting bullet in a workflow doc (a list item that is a bold label, a colon and
a code span) can be written by `task-init`, so a config tool can own the values
instead of hand edits a `--force` would lose. `<setting>` is the bullet label as
written in the doc, such as `Status when done` or, on jira, `Watch poll seconds`,
matched case-insensitively and split on the first `=`. Repeatable. An empty value
restores the template default. A label this loadout's template does not carry is
refused with the list of valid ones, exit 2, before anything is written. Values
land inside the managed region: a re-run with the same `--set` gives the same
file, and a re-run without one keeps the value already there. The tracker flags
(`--owner` / `--repo` / `--project`, `--site` / `--key` / `--board`, `--tasks` /
`--projects` / `--board`) are shorthands for `--set` on their own bullet. An
existing doc is rewritten only with `--force` (or at a prompt), as for every
other value. It works with `--local-only`, and `task-config set` / `add
assistant` / `sync` carry every bullet that differs from the template default as
a `--set`. A bullet below the end marker is never touched, and still wins for
the readers that take the last one (`task-watch`, `task-merge-gate`).

```bash
# an external config tool, per repo, from its own records
task-init claude-jira --local-only --force --site https://<site>.atlassian.net --key OPS \
  --set "Status when in review=Code Review" --set "Watch poll seconds=120"
```

## task-remove

`task-remove` — take task-force back out of this repo (#220)

The same removal walk a `task-config set` performs, with no install after it. Two
situations want it: the project is done and the workflow config is dead weight, or
you are about to open a PR against a repo that does **not** use task-force, where the
diff would otherwise carry `.claude/commands/`, a `.claude/settings.json` hook merge,
the `@.claude/<tracker>-workflow.md` import line in `CLAUDE.md` and a workflow doc
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

## ci-guard

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

## task-monitor-snapshot

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

## task-monitor

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

## task-monitor-queue

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

## Handing the PM off (task-pm, task-monitor-queue handoff)

**Handing the PM off** (#301) — from claude to kiro and back, or to a fresh PM on
the same one. The address `pm-<reponame>` stays, so the inbox carries over; three
things carry the rest.

- **The board digest.** A fresh PM register (claude `SessionStart`, kiro
  `agentSpawn`) prints `task-monitor-snapshot --local --brief` under the
  offline-backlog summary: attention signals, in flight, the queue with its
  notes, and what merged in the last 24h with each PR summary's first sentence.
  It is read from disk with no forge call, capped at 40 lines, and never
  printed on a `/compact` or `/clear` re-register or for a worker.
  `TASK_FORCE_NO_PM_DIGEST=1` turns it off.
- **The handoff note.** Asked to hand off, the PM writes 5–10 lines on what the
  board cannot show (decisions, questions waiting on you, what is parked and
  why, what not to redo) to `$TASK_FORCE_HOME/monitor/<repo>/handoff.md`. The
  next fresh PM start prints it under the digest with its age; it stays until
  the next write replaces it, and task-monitor shows it collapsed as the repo
  view's last row.
- **One live PM.** `task-pm` refuses while this repo's PM session has a
  heartbeat under an hour old (`radio orphans` does not list it) and a tab that
  is not the current one, naming the agent in `<role>.agent`; `--force`
  overrides. A session live in *this* tab is the handoff itself (kiro has no
  exit hook) and goes through. Whenever it goes ahead over an earlier session
  file, `task-pm` retires it with `radio unregister --manual`, so the new
  register is fresh and prints the backlog and the digest.

```bash
task-monitor-queue handoff write <<'NOTE'    # replace the note, on stdin
task-monitor-queue handoff show              # print it
task-monitor-queue handoff clear             # remove it
```


## Loadout differences

### kiro (kiro-gh, kiro-local, kiro-notion)

`task-work` launches a worker *agent* (`kiro-cli chat --agent worker`), and its
flags differ from claude's in these ways:

- `-m, --model MODEL` — pick a specific kiro model; falls back to `$TASK_WORK_MODEL`, else `claude-opus-5.5`. Always passed as `--model`, which outranks your kiro `chat.defaultModel` setting (#259). `task-pm` launches the PM on the same default and honors `$TASK_WORK_MODEL` too. The kiro reviewer reads `$TASK_WORK_MODEL` too, ahead of its own `claude-sonnet-5.5` default, so a worker override exported in your shell also dispatches reviewers on that model (`claude-opus-5.5` costs 2.00x credits to Sonnet's 1.30x). Unset it, or pass `task-reviewer -m`, to keep reviewers on Sonnet
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs without per-tool confirmation. kiro-cli documents a trust-all confirmation at startup, and a prompt like that would hold the worker's first turn in a tab nobody types in. `task-work` warns when `chat.disableTrustAllConfirmation` is not set; if you dispatch with `-a`, set it once with `kiro-cli settings chat.disableTrustAllConfirmation true` (#157)
- `--no-launch` — open the worktree tab but do NOT start kiro
- `--no-task` — launch with no task ref on purpose. Without it a bare slug is refused, since the worker would start with no spec (#371). `--no-launch` needs no ref and no flag, since it starts nothing
- `--no-auto-submit` — keep the Enter gate on radio wakes. Radio auto-submit is **the default** (#254): an incoming ping submits itself instead of sitting in the prompt box until someone presses Enter, since nobody types in a worker's tab. Use this for a worker you mean to step into and steer by hand. `--auto-submit` states the default explicitly
- `--auto` — accepted for symmetry with claude, and a no-op here: the permission model stays `-a/--trust-all` (#206), and auto-submit is already on

There is no `--plan`: kiro has no plan mode, so `--no-task` is needed with a
bare slug unless `--no-launch` is given. `-a` defaults on when
`$TASK_WORK_TRUST_ALL=1` is set.

Under kiro-cli's V3 engine (`chat.agentEngine = v3` today; kiro-cli's help calls v2 "the pre-3.0 default"), every dispatched kiro launch — `task-work`, `task-recreate-worker`, `task-reviewer` — would first stop at a dialog offering to upgrade your agent configs to the V3 format. Nobody answers it in a dispatched tab, so the first turn never runs. The launchers warn when the launch would run on V3 and `chat.enableAutoAgentUpgrade` is unset. Set it once with `kiro-cli settings chat.enableAutoAgentUpgrade true`: that, or accepting the upgrade, rewrites `.kiro/agents/*.json` into kiro-cli's universal format, the radio hooks keep working there, and `task-init` and `task-remove` handle that format since #267. Do not set it to `false` on kiro-cli 3.x: V3 then loads the configs as `task-init` wrote them and fires none of their hooks (probed on 3.1.0), so the role never registers. It worked on 2.32.0 (#257).

Then commit the upgraded configs. A rewrite at launch leaves the committed copy in the old shape, and when a `git stash`, `checkout` or `reset` puts that copy back while the agent runs, V3 reloads it and drops every radio hook for the rest of the session: the heartbeat freezes and radio calls the role dead (#370). Run `kiro-cli agent upgrade .kiro/agents` in the main checkout, commit `.kiro/agents`, and `git merge <base>` in any live worktree. `task-work`, `task-reviewer`, `task-recreate-worker` and `task-pm` warn on V3 while the agent's config is still in the old shape. Until #350 ships the configs in universal shape, a fresh `task-init` writes the old one.

V3 also asks "Trust this workspace?" the first time it opens a folder, and every worktree `task-work` creates is a folder it has never seen (#378). So `task-work`, `task-recreate-worker` and `task-reviewer` pass `--trust-workspace` when the installed kiro-cli lists it in `kiro-cli chat --help`, and an older kiro-cli gets the launch line it always did. The flag skips the prompt for that one launch and saves nothing. task-force created the folder from your own repo, and what the prompt guards is that repo's committed `.kiro/` config with the radio hooks in it. `task-pm` does not pass it: the PM runs in your main checkout, in the tab you type in, and V3 remembers the answer you give there. Set `TASK_WORK_NO_TRUST_WORKSPACE=1` to get the prompt back on dispatched launches.

On `task-config set` and `task-remove`, removal treats agent configs this way:

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

`task-remove` on kiro takes out `.kiro/agents/`, any inert
`.kiro/hooks/radio-*.json` and `.kiro/steering/<tracker>-workflow.md`, keeps an
agent config of yours with only its radio hooks stripped, and its `--purge`
deletes an agent config that differs from the shipped copy once its radio hooks
are stripped.

### local (claude-local, kiro-local)

`task-work tasks/NNN-slug.md [options]`: the task file is the ref.

The slug argument is checked before anything is created (#371): one that holds whitespace or a URL is refused (a task file whose name has a space is fine), and a slug over 50 characters is truncated with a warning. A free-form slug needs no `--no-task` here: on this tracker the slug is the task file, so there is no ref to have forgotten.

```bash
task-work tasks/001-add-login-flow.md
task-work tasks/042-refactor-auth.md --base develop --plan
task-work tasks/050-stacked-feature.md --from task/042-refactor-auth --auto
task-work tasks/007-spike-idea.md --no-launch
```

`task-board` — regenerate `tasks/_board.md` from `tasks/*.md` frontmatter +
`.git/task-force/state.json`. Idempotent; safe to run anytime. Done is capped
at the 10 newest tasks plus a count of the rest; `--done-limit N` (or
`TASK_BOARD_DONE_LIMIT`) changes the cap (#294). Like `task-work`
/ `task-done`, it resolves the loadout per-repo (#215) — on a repo tracked in
GitHub / Jira / Notion it refuses with a message naming that loadout, because
there are no local task files to render a board from. It is a single root copy
(#238), not a per-loadout one. `--repo PATH` picks the repo, and detection
follows that path rather than `$PWD`.

### notion (claude-notion, kiro-notion)

`task-work <slug> [notion-url] [options]`, for example
`task-work add-store-filtering https://www.notion.so/My-Task-abc123def456`.
On **this** loadout the carried settings are the three Notion database IDs:
`task-init` takes them as `--tasks` / `--projects` / `--board` (#225), so a
`claude-notion ↔ kiro-notion` switch passes them forward and you never re-paste
them. `--tasks` / `--projects` accept the `collection://<id>` that
`task-config show` prints, or the bare id.

### jira (claude-jira)

`task-work <JIRA-KEY-or-url-or-slug> [options]`, and
`task-work <slug> <JIRA-KEY-or-url>` names the slug explicitly:

```bash
task-work {KEY}-42
task-work https://{SITE}.atlassian.net/browse/{KEY}-42
task-work add-auth {KEY}-42
task-work {KEY}-99 --from task/{KEY}-46 --base main --auto   # stack on an in-flight branch
```

There is no kiro-jira loadout (#92), so jira cannot be dual-assistant.
Until #401 `task-watch` and `task-merge-gate` were documented in full in the
jira workflow doc. It now keeps one index line for each and their settings
bullets; what follows is the long form.

#### task-watch

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

Settings are bullets in the jira workflow doc (**Watch label**, **Watch JQL**,
**Watch poll seconds** and the rest); the last matching bullet wins. The
default JQL is the project named in the jira workflow doc, the issue type and
the label, minus claimed and failed tickets, oldest first; a custom one is used
as written (claimed and failed tickets are skipped either way).

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

#### task-merge-gate

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
Its settings, **Merge label**, **Merge max changed lines** and **Merge max
files**, are bullets in the jira workflow doc.
