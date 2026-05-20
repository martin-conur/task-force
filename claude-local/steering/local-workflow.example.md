## Local Task Tracking Workflow (Claude Code)

This project uses **local markdown task tracking** — tasks live as files in
`tasks/`, committed alongside the code. No external tracker, no MCP. The board
view is auto-generated and Obsidian-friendly.

Copy this file to your project's `.claude/local-workflow.md`.
Or run `task-init claude-local` in your project root to do this automatically.

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

`todo` → `in-progress` → `done`

- **Status when starting work**: `in-progress` (worker bumps on first commit)
- **Status when done**: `done` (worker bumps on final commit before PR)

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
`.git/task-force/state.json`. Idempotent; safe to run anytime.
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

If a worker tab dies unexpectedly (or Claude resumes a session without
re-firing `SessionStart`), the session file's `LAST_HEARTBEAT` will go stale.
Run `radio orphans` to list any session whose heartbeat is older than 1 hour —
those entries are safe to delete (`rm ~/.task-force/radio/sessions/<role>.info`)
or leave for the next legitimate `radio register` to overwrite.
