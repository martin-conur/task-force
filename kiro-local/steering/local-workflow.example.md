## Local Task Tracking Workflow (Kiro)

This project uses **local markdown task tracking** — tasks live as files in
`tasks/`, committed alongside the code. No external tracker, no MCP. The board
view is auto-generated and Obsidian-friendly.

Copy this file to your project's `.kiro/steering/local-workflow.md`.
Or run `task-init kiro-local` in your project root to do this automatically.

Kiro auto-loads anything under `.kiro/steering/`, so every Kiro session in this
repo will pick this file up.

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

- `-m, --model MODEL` — model to pass to `kiro-cli`
- `-a, --trust-all` — pass `--trust-all-tools` to `kiro-cli`
- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `--no-launch` — open the worktree tab but do NOT start `kiro-cli`

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work tasks/001-add-login-flow.md
task-work tasks/042-refactor-auth.md --base develop
task-work tasks/050-stacked-feature.md --from task/042-refactor-auth
task-work tasks/007-spike-idea.md --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)

`task-board` — regenerate `tasks/_board.md` from `tasks/*.md` frontmatter +
`.git/task-force/state.json`. Idempotent; safe to run anytime.
