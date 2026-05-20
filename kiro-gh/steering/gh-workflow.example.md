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

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker agent

- `-m, --model MODEL` — pick a specific kiro model
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs without per-tool confirmation
- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `--no-launch` — open the worktree tab but do NOT start kiro

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/{OWNER}/{REPO}/issues/42"
task-work https://github.com/{OWNER}/{REPO}/issues/42
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work issue-99 --from task/issue-46 --base main         # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
### PM ↔ worker messaging (radio)

When you finish your task and have nothing pending, the `radio ready` step will
run automatically via your `agentStop` hook — you don't need to invoke it
manually. If you ever want to nudge the PM (or a worker) outside the normal
flow, run:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N]
```

Intents are free-form labels (`review-requested`, `re-review-requested`,
`approved`, etc.); the body comes from `--body` or stdin. PR review *content*
still lives in `gh pr comment`s — `radio` only carries the routing ping.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `agentSpawn` hook, and
starts the PM agent in-place.
