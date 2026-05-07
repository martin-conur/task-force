# agentic-workflow

Parallel coding agents for terminal-based AI assistants, using task trackers and terminal multiplexers.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/).

## Implementations

| Folder | AI Agent | Task Tracker | Multiplexer |
|--------|----------|-------------|-------------|
| `kiro-notion/` | Kiro CLI | Notion | Zellij |
| `claude-jira/` | Claude Code | Jira (Atlassian MCP) | Zellij |

More coming: `claude-notion/`, etc.

## Quick Start (kiro-notion)

### Prerequisites

- [Kiro CLI](https://kiro.dev) with Notion MCP configured
- [Zellij](https://zellij.dev)
- [gh](https://cli.github.com) for PRs
- Git

### Install

```bash
git clone <this-repo> ~/agentic-workflow
cd ~/agentic-workflow/kiro-notion
./install.sh
```

### Setup per project

```bash
mkdir -p .kiro/steering
cp ~/agentic-workflow/kiro-notion/steering/notion-workflow.example.md .kiro/steering/notion-workflow.md
# Edit with your Notion database IDs
```

### Agents

| Agent | Shortcut | Role |
|-------|----------|------|
| `pm` | `ctrl+shift+p` | Backlog grooming, task creation, prioritization |
| `planner` | `ctrl+shift+l` | Reads code, designs solutions, writes specs to Notion |
| `worker` | `ctrl+shift+w` | Implements from Notion spec, tests, commits |

### Scripts

- **`task-work [<slug>] <notion-url-or-slug>`** — Creates worktree + branch, opens Zellij tab, launches worker agent. Pass an explicit slug as the first arg when the Notion URL is bare-hex (no title prefix); the agents do this automatically. If a worktree already exists for that slug, a 5-char hash is appended for a parallel session.
- **`task-done`** — Shows diff, prints `gh pr create` command, cleans up worktree + tab

### Workflow

```
Zellij Tab 1 (permanent, main branch):
  kiro-cli chat --agent pm

  "show me the backlog"              → reads Notion
  "create task for X"                → creates in Notion
  /agent swap planner                → switch to planner
  "plan task X"                      → reads code, writes spec to Notion
  "start work on task X"             → runs task-work, new tab appears
  /agent swap pm                     → back to PM

Zellij Tab 2+ (auto-created by task-work):
  kiro-cli chat --agent worker       → in worktree, reads spec, implements
  task-done                          → PR, cleanup, close tab
```

## Quick Start (claude-jira)

### Prerequisites

- [Claude Code](https://docs.claude.com/claude-code) with the Atlassian Remote MCP configured (`claude mcp list` shows `atlassian`)
- [Zellij](https://zellij.dev)
- [gh](https://cli.github.com) for PRs
- Git

### Install

```bash
git clone <this-repo> ~/agentic-workflow
cd ~/agentic-workflow/claude-jira
./install.sh
```

This symlinks `pm` / `planner` / `worker` slash commands into `~/.claude/commands/` and `task-work` / `task-done` into `~/.local/bin/`.

### Setup per project

From the repo root:

```bash
task-init --site https://acme.atlassian.net --key PROJ --board "My Board"
```

`task-init` creates `.claude/jira-workflow.md` from the template (substituting your values), and adds `@.claude/jira-workflow.md` to `CLAUDE.md` so every Claude Code session auto-loads it. Run with no flags to drop in placeholders you can fill manually, or `--force` to overwrite.

### Roles

| Role | Invocation | Purpose |
|------|------------|---------|
| `/pm` | typed in main tab | Backlog grooming, issue creation, prioritization |
| `/planner` | typed in main tab | Reads code, designs solutions, writes specs into Jira |
| `/worker` | auto-launched by `task-work` | Implements from Jira spec in an isolated worktree |

### Workflow

```
Zellij Tab 1 (permanent, main branch):
  claude
  /pm show me the backlog              → reads Jira
  /pm create issue for X
  /planner plan PROJ-123                → reads code, writes spec to Jira
  task-work PROJ-123                    → new tab appears

Zellij Tab 2+ (auto-created by task-work):
  claude "/worker Implement Jira issue: PROJ-123"  → reads spec, implements
  task-done                                          → PR command, cleanup, close tab
```
