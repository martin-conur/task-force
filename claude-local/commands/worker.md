---
description: Worker — implements tasks from local markdown specs, commits with task title prefix
argument-hint: <path to tasks/NNN-slug.md>
---

You are now in Worker mode.

Refer to the project's `.claude/local-workflow.md` for conventions. Tasks live
as markdown files in `tasks/` — there is **no** external tracker in this
workflow.

Workflow:

1. **Locate the task file.**
   - If `$ARGUMENTS` contains an absolute path to a `tasks/NNN-slug.md` file,
     use it.
   - Otherwise, derive the slug from the current branch:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     [ -f $INFO ] && . $INFO   # sets TASK_FILE
     ```
     If neither yields a task file, ask the user.

2. **Read the spec** — frontmatter + the Problem / Solution / Files / Verification sections.

3. **Bump status to `in-progress`** in the task file's frontmatter. The
   frontmatter is the first `---`-delimited block. Use sed:
   ```bash
   # Within the frontmatter block only, replace the status line.
   sed -i.bak '1,/^---$/{ /^---$/!{ s/^status:.*$/status: in-progress/ } }' "$TASK_FILE"
   rm -f "$TASK_FILE.bak"
   ```
   Also set `branch: "<current branch name>"` the same way.
   Commit this change separately with a message like
   `<Task title>: start work` (so the first commit on the branch marks
   in-progress). The `task-work` tool already wrote a live in-progress entry
   to `.git/task-force/state.json`, so the board will show this task in the
   "In Progress" column either way — but the frontmatter bump is what makes
   the change durable on the branch.

4. **Implement the solution** following the spec.

5. **Write tests** for new features or bug fixes.

6. **Run tests** to verify. Fix failures before continuing.

7. **Commit** with the task title as prefix: `<Task title>: <short description>`.

8. **Bump status to `done`** in the task file's frontmatter (same sed
   pattern). Regenerate the board (`task-board`) and commit with a message
   like `<Task title>: mark done`.

9. **Open a pull request.**
   - Find the base branch:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     BASE=main; [ -f $INFO ] && . $INFO
     ```
   - Run: `gh pr create --base $BASE --head $(git rev-parse --abbrev-ref HEAD) --fill`
     This opens an editor so the user can review and submit the PR.
   - After the PR is created, capture its URL and write it into the task
     file's frontmatter `pr:` field (same sed pattern, key `pr`). Commit and
     push with a message like `<Task title>: link PR`.
   - Then tell the user: run `task-done --remove-worktree` to clean up the
     worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
