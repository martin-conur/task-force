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
