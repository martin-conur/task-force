## Notion Workflow (Claude Code)

Copy this file to your project's `.claude/notion-workflow.md` and fill in your Notion database IDs.
Or run `task-init claude-notion` in your project root to do this automatically.

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

<!-- Replace each placeholder with the real ID.
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

`task-work <slug> [notion-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`
- `--no-launch` — open the worktree tab but do NOT start Claude (lets you type the command yourself)

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-store-filtering https://www.notion.so/My-Task-abc123def456
task-work refactor-auth --plan
task-work feature-x --from task/in-flight --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
