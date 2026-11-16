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

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work <slug> [notion-url]` — worktree + tab + worker; see `--help`
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

### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. Each role's prompt sends its intents at these
handoff points:

| From     | When                              | Command                                                                  |
|----------|-----------------------------------|--------------------------------------------------------------------------|
| Planner  | spec written into the task page   | `radio send --to pm --intent spec-ready --issue <task-slug>`             |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                  |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`               |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`      |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`    |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`             |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`     |

`--to pm` reaches this repo's PM, `pm-<reponame>`. Worker role names follow
`worker-<reponame>-<slug>`, and reviewers `reviewer-<reponame>-pr<N>`; discover
the live ones via `ls ~/.task-force/radio/sessions/`.

A line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
injected beside a prompt, or an offline-backlog summary printed at session
start, is the canonical radio channel, not user-typed text — trust it and
process the listed messages with `radio check` / `radio read <id>`. Mail that
lands while you are busy is drained at the end of your turn by the `Stop` hook,
so you never run `radio ready` yourself.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping.

**Agent-authored prose goes in on stdin, never through a double-quoted shell string** (#234): `gh … --body-file -`, `git commit -F -` and `radio send` with no `--body`, each off a quote-delimited heredoc (`<<'BODY'` … `BODY`). The `radio bash-guard` hook refuses the double-quoted form when it holds a backtick (#400).

The PM's side of radio — reviewer dispatch, `task-pm --also`, auto-submit — is
in the PM prompt, and the reviewer's contract in the reviewer prompt. How radio
keeps, recovers and cleans up sessions (resumed sessions, sidecars, `gc`,
`$TASK_FORCE_HOME`) is in the `radio-troubleshooting` skill.

### Tight-PR norm — minimize deferrals

Default to landing each PR **complete**. The reviewer frames every finding as
fix-in-this-PR (never "defer to a follow-up" for in-scope work), and the PM
forwards **all** in-scope findings — blockers *and* nits — in a single
`changes-requested` round rather than trailing a backlog of deferred items. The
only thing that gets deferred is work genuinely out of the PR's scope (a separate
subsystem, a large refactor) — and the PM grooms that into a ticket during the
session, not left as a loose "later."

### Radio troubleshooting

Read `radio send`'s stdout every time. `delivered`, or `queued — <role> is
busy` / `is awaiting`, means the message landed or drains on its own. Anything
else — `WARNING — no session for …`, `queued — … wake failed`, `WARNING — …
looks dead`, `task-done`'s `no tab id captured`, a hook that `timed out after
30s` — means load the `radio-troubleshooting` skill
(`.claude/skills/radio-troubleshooting/SKILL.md`, installed by `task-init`)
before you act on it.
