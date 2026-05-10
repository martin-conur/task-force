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

- **Owner**: `{OWNER}` (GitHub user or org name)
- **Repo**: `{REPO}` (repository name)
- **Project number**: `{PROJECT}` (from the project URL: github.com/users/{OWNER}/projects/N or github.com/orgs/{OWNER}/projects/N)

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

- `-b, --base BRANCH` — base branch for the PR (default: current branch)
- `--no-launch` — open the worktree tab but do NOT start Claude

Examples:
```bash
task-work add-auth "https://github.com/{OWNER}/{REPO}/issues/42"
task-work https://github.com/{OWNER}/{REPO}/issues/42
task-work refactor-auth
task-work spike-idea --no-launch
```

`task-done` — from within worktree: show diff, print/detect PR, cleanup
`task-done --remove-worktree` — cleanup only (use after worker has already created the PR)
