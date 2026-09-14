## GitHub Projects Workflow (Claude Code)

Copy this file to your project's `.claude/gh-workflow.md` and fill in your details.
Or run `task-init claude-gh` in your project root to do this automatically.

Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/gh-workflow.md
```

### GitHub CLI (`gh`)

This workflow uses the [`gh` CLI](https://cli.github.com) for issue / project / PR I/O. Verify you're authenticated:

```bash
gh auth status
```

If not, run `gh auth login` (needs `repo` + `project` scopes). The PM / planner / worker prompts shell out to `gh` directly; read-only patterns (`gh issue view *`, `gh project view *`, `gh search issues *`, etc.) are pre-allowed in `.claude/settings.json` by `task-init claude-gh`, so reads don't trigger permission prompts. Mutations (`gh issue edit`, `gh pr merge`, …) stay confirmation-gated.

#### Optional: GitHub MCP for richer Projects v2 mutations

`gh project item-edit` covers the common single-select / number / text mutations. If you frequently mutate iteration fields or want a higher-level Projects v2 API, add the GitHub MCP as an opt-in:

```bash
claude mcp add --transport stdio github -- npx -y @github/github-mcp-server
```

(Requires `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment.)

### GitHub Repository

- **Owner**: `martin-conur` (GitHub user or org name)
- **Repo**: `task-force` (repository name)
- **Project number**: `1` (from the project URL: github.com/users/martin-conur/projects/N or github.com/orgs/martin-conur/projects/N)

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

### Pre-PR checklist (this repo)

The `/worker` pre-PR checklist is deliberately repo-generic (it ships downstream
verbatim via `task-init`). In **this** repo it resolves to:

- **Changelog** — add an entry under `## [Unreleased]` in `CHANGELOG.md`
  ([Keep a Changelog](https://keepachangelog.com) format). Include the
  **"Upgrading: re-run `task-init <loadout>`"** note whenever installer-written
  artifacts change (radio hooks, the copied `commands/*.md`, `settings.json`);
  say so explicitly when no re-run is needed.
- **Docs** — a model-facing or user-visible change also updates the README
  section, the four `steering/*.example.md` templates, and the loadout workflow
  docs (`.claude/*-workflow.md`). See PRs #172–#175 for the findings this
  checklist encodes; #163 / #164 / #168 for the doc-beat precedent.
- **Reuse / drift** — logic shared across loadouts lives behind `# region:`
  sentinels guarded by `tools/check-drift.sh`; extract rather than copy a second
  time, and add a sentinel + manifest entry when you do.
- **Green** — run `./run_tests.sh`, `tools/check-drift.sh`, and `shellcheck -x`
  on changed shell files; confirm `gh pr checks` after pushing.

### Shell Commands

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`
- `--no-launch` — open the worktree tab but do NOT start Claude

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/martin-conur/task-force/issues/42"
task-work https://github.com/martin-conur/task-force/issues/42
task-work refactor-auth --plan
task-work issue-99 --from task/issue-46 --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker prompts shell out to
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
backfill (#182). Empty
inbox prints nothing. (claude loadouts only — Kiro's hook stdout isn't
injected; see #146.)

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

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> [<issue-url-or-number>]` from any spare tab.
It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet (cheaper than the PM's Opus default), cross-checks
the PR against the spec issue (passed as the second arg, or auto-detected from
the PR body's first `Closes #N` / `Fixes #N` / `Resolves #N` line, case-insensitive), runs the `code-review` skill on
the diff, posts a single thorough PR comment via `gh pr comment`, and radios
PM back with `review-complete-clean` or `review-complete-with-findings`. PM
still owns the merge decision — the reviewer never approves, merges, or
mutates status. The reviewer tab stays open showing the analysis; clean up
with `task-done --remove-worktree` when done.

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

Undelivered mail is never dropped. The message is written to the inbox
**before** any wake is attempted, so every outcome other than `delivered`
means "on disk, waiting" rather than "gone". `radio gc` never touches
`inbox/` (only `processed/`), and it refuses to reclaim a role's mailbox at
all while that inbox still holds unread mail. There is no dead-letter queue —
an undeliverable message just waits, and `radio gc --dry-run` shows what a
sweep would remove without removing it.

When the wake itself fails, the backstops still apply: the `Stop` hook makes
the agent drain a queued message at the end of its current turn, the
`UserPromptSubmit` hook puts the unread summary in front of it at the next
prompt, and a fresh `SessionStart` register reports whatever queued while the
role was offline. A failed wake is a latency problem here, not a lost message.
