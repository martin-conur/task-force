## Notion Workflow

Copy this file to your project's `.kiro/steering/notion-workflow.md` and fill in your Notion database IDs.

### Notion Database IDs
- **Tasks**: `collection://<YOUR_TASKS_DATA_SOURCE_ID>`
- **Projects**: `collection://<YOUR_PROJECTS_DATA_SOURCE_ID>`
- **Board page**: `<YOUR_BOARD_PAGE_ID>`

To find these IDs:
1. Open your Notion board in Kiro with the Notion MCP
2. Use `notion-fetch` on your database URL
3. Look for `<data-source url="collection://...">` tags in the response

### Task Lifecycle
Not Started → In Progress → Done (or Archived)

- **Status when starting work**: `In Progress`
- **Status when done**: `Done`

The worker reads these two values and updates the task's Status property accordingly: to "starting work" before implementing, and to "done" after committing (before running `task-done`).

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
- `--no-launch` — open the worktree's tab but do NOT start kiro (lets you type the command yourself).

Examples:
```bash
task-work add-store-filtering https://www.notion.so/My-Task-abc123def456
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work spike-idea --no-launch
```

`task-done` — from within worktree: show diff, print/detect PR, cleanup
`task-done --remove-worktree` — cleanup only (use after worker has already created the PR)
