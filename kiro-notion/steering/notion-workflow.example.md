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
- `task-work <notion-url-or-slug>` — create worktree + zellij tab + worker agent
- `task-done` — from within worktree: show diff, print PR command, cleanup
