## Jira Workflow

Copy this file to your project's `.claude/jira-workflow.md` and fill in your details. Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/jira-workflow.md
```

### Jira

- **Site**: `{SITE}`
- **Project key(s)**: `{KEY}` (issue keys look like `{KEY}-123`)
- **Board name**: `{BOARD}`

### Issue Lifecycle

To Do → In Progress → In Review → Done

(Replace with your project's actual workflow statuses.)

- **Status when starting work**: `In Progress`
- **Status when done**: `Done`

The worker reads these two values and transitions the issue accordingly: to "starting work" before implementing, and to "done" after committing (before running `task-done`).

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
### PM ↔ worker messaging (radio)

When you finish your task and have nothing pending, the `radio ready` step will
run automatically via your `Stop` hook — you don't need to invoke it manually.
If you ever want to nudge the PM (or a worker) outside the normal flow, run:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N]
```

Intents are free-form labels (`review-requested`, `re-review-requested`,
`approved`, etc.); the body comes from `--body` or stdin. PR review *content*
still lives in `gh pr comment`s — `radio` only carries the routing ping.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `SessionStart` hook, and
starts the PM agent in-place.
