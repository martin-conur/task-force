## GitHub Projects Workflow (Claude Code)

Copy this file to your project's `.claude/gh-workflow.md` and fill in your details.
Or run `task-init claude-gh` in your project root to do this automatically.

Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/gh-workflow.md
```

### GitHub MCP (Claude Code)

This workflow requires the GitHub MCP server configured in Claude Code. Verify with:

```bash
claude mcp list
```

You should see a `github` entry. If not, add it (requires `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment):

```bash
claude mcp add --transport stdio github -- npx -y @github/github-mcp-server
```

### GitHub Repository

- **Owner**: `martin-conur` (GitHub user or org name)
- **Repo**: `task-force` (repository name)
- **Project number**: `1` (from the project URL: github.com/users/martin-conur/projects/N or github.com/orgs/martin-conur/projects/N)

### Task Lifecycle

Todo → In Progress → Done

- **Status when starting work**: `In Progress`
- **Status when done**: `Done`

The worker reads these two values and updates the project item's Status field accordingly: to "starting work" before implementing, and to "done" after committing (before running `task-done`).

### Task Properties

- **Title** (issue title), **Status** (project single-select field), **Priority** (project field)
- **Git commit** (URL — set to PR link after done)

### Commit Convention

Use the issue title as prefix: `<Issue title>: <short description>`

### Shell Commands

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`
- `--no-launch` — open the worktree tab but do NOT start Claude

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/martin-conur/task-force/issues/42"
task-work https://github.com/martin-conur/task-force/issues/42
task-work refactor-auth --plan
task-work issue-99 --from task/issue-46 --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
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
