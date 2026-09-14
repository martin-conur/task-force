## Notion Workflow

Copy this file to your project's `.kiro/steering/notion-workflow.md` and fill in your Notion database IDs.

### Notion Database IDs

<!-- Replace each placeholder with the real ID.
     Run `task-init kiro-notion --help-ids` for step-by-step discovery instructions.

     What each ID looks like:
       collection://...  — opaque string from the Notion MCP (data-source URL)
       board page ID     — UUID like 8a1b2c3d-e4f5-6789-abcd-ef0123456789

     How to find them (requires Notion MCP active in Kiro):
       1. Run: kiro
       2. Ask: "Help me find my Notion database IDs"
       3. Kiro will list your boards and extract the IDs from the MCP response
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

### Shell Commands

`task-work <slug> [notion-url] [options]` — create worktree + zellij tab + worker agent

- `-m, --model MODEL` — pick a specific kiro model (e.g. `claude-opus-4.6`, `claude-sonnet-4.6`). Falls back to `$TASK_WORK_MODEL`, else kiro's default (`auto`).
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs commands without per-tool confirmation. Defaults to `$TASK_WORK_TRUST_ALL=1` if set.
- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `--no-launch` — open the worktree's tab but do NOT start kiro (lets you type the command yourself).

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-store-filtering https://www.notion.so/My-Task-abc123def456
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work feature-x --from task/in-flight --base main       # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker agents shell out to
`radio send` at every documented handoff point:

| From    | When                            | Command                                                                |
|---------|---------------------------------|------------------------------------------------------------------------|
| Planner | spec written into the task page | `radio send --to pm --intent spec-ready --issue <task-slug>`           |
| Worker  | PR opened                       | `radio send --to pm --intent review-requested --pr <N>`                |
| Worker  | new commits pushed after review | `radio send --to pm --intent re-review-requested --pr <N>`             |
| PM      | review requested changes        | `radio send --to <worker-role> --intent changes-requested --pr <N>`    |
| PM      | PR merged                       | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`  |

When a worker finishes its task and has nothing pending, the `radio ready` step
runs automatically via the `agentStop` hook — you don't need to invoke it
manually.

**Delivery here is best-effort — kiro agents pull, they don't receive.** The
hooks under `.kiro/hooks/` keep each role's session file accurate, but kiro
does not inject hook output into the agent's context, so nothing a hook prints
ever reaches the model: `agentSpawn`'s offline-backlog summary is discarded,
`userPromptSubmit` is a plain `radio busy` with no inbox summary, and
`agentStop`'s `radio check` writes to the hook subshell rather than the agent.
There is also no kiro equivalent of the Stop-hook block that makes a busy agent
drain its queue before going idle. That leaves the zellij keystroke wake — one
best-effort push with no fallback behind it.

So the agents poll instead: every agent in `.kiro/agents/` carries a standing
instruction to run `radio check` at the start of each turn and `radio read <id>`
whatever it lists. If you are waiting on a handoff that seems not to have
arrived, prompt the recipient tab — its next turn starts with a check.

There is likewise no session-end trigger (`agentStop` fires per turn, not on
session close), so closing a tab leaves its session file behind still
advertising `STATE=idle`, and senders will keep trying to wake a tab that is
gone. `task-done` unregisters on the worker happy path; for everything else,
`radio orphans` is the cleanup step — see below.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping. Worker role names
follow `worker-<reponame>-<slug>`; discover the live one via
`ls ~/.task-force/radio/sessions/`.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `agentSpawn` hook, and
starts the PM agent in-place.

If a worker tab dies unexpectedly, is closed without `task-done`, or kiro
resumes a session without re-firing the `agentSpawn` hook, the session file's
`LAST_HEARTBEAT` will go stale. Run `radio orphans` to list any session whose
heartbeat is older than 1 hour — those entries are safe to delete
(`rm ~/.task-force/radio/sessions/<role>.info`) or leave for the next
legitimate `radio register` to overwrite. Because there is no session-end hook
here, treat this as routine housekeeping rather than a crash-only step: a stale
session still reads as `STATE=idle` to senders, so radio will keep aiming wakes
at a tab that no longer exists.

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
