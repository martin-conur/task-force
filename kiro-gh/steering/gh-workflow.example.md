## GitHub Projects Workflow (Kiro)

Copy this file to your project's `.kiro/steering/gh-workflow.md` and fill in your details.
Or run `task-init kiro-gh` in your project root to do this automatically.

### GitHub MCP (Kiro)

This workflow requires the GitHub MCP server configured in Kiro. Add it to your agent definitions'
`mcpServers` block (already done in the bundled agents):

```json
"github": { "command": "npx", "args": ["-y", "@github/github-mcp-server"] }
```

Set `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment before running Kiro.

### GitHub Repository

- **Owner**: `YOUR_OWNER` (GitHub user or org name)
- **Repo**: `YOUR_REPO` (repository name)
- **Project number**: `YOUR_PROJECT_NUMBER` (from the project URL: github.com/users/YOUR_OWNER/projects/N or github.com/orgs/YOUR_OWNER/projects/N)

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

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker agent

- `-m, --model MODEL` — pick a specific kiro model
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs without per-tool confirmation
- `-b, --base BRANCH` — base branch for the PR (default: current branch)
- `--no-launch` — open the worktree tab but do NOT start kiro

Examples:
```bash
task-work add-auth "https://github.com/{OWNER}/{REPO}/issues/42"
task-work https://github.com/{OWNER}/{REPO}/issues/42
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work spike-idea --no-launch
```

`task-done` — from within worktree: show diff, print/detect PR, cleanup
`task-done --remove-worktree` — cleanup only (use after worker has already created the PR)
