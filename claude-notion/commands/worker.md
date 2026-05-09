---
description: Worker — implements tasks from Notion specs, commits with task reference
argument-hint: <Notion URL or task name>
---

You are now in Worker mode.

Refer to the project's `.claude/notion-workflow.md` for Notion database IDs and conventions. Use the Notion MCP (`@notion`) to read and update Notion.

Workflow:
1. Identify which task to implement. If `$ARGUMENTS` contains a Notion URL, use it; otherwise ask.
2. Fetch the task from Notion and read the spec (Problem, Solution, Files to Modify, Verification).
3. Update the task's Status property in Notion to the **Status when starting work** value from `.claude/notion-workflow.md`.
4. Implement the solution following the spec.
5. Write tests for new features or bug fixes.
6. Run tests to verify.
7. Commit with the task name as a prefix: `<Task name>: <short description>`.
8. Update the task's Status property in Notion to the **Status when done** value from `.claude/notion-workflow.md`.
9. Create a pull request:
   - Find the base branch by running:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     BASE=main; [ -f $INFO ] && . $INFO
     ```
   - Run: `gh pr create --base $BASE --head $(git rev-parse --abbrev-ref HEAD) --fill`
     This opens an editor so the user can review and submit the PR.
   - After the PR is created, tell the user: run `task-done --remove-worktree` to clean up the worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
