# agentic-workflow

Parallel coding agents for terminal-based AI assistants, using task trackers and terminal multiplexers.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/).

## Implementations

| Folder | AI Agent | Task Tracker | Multiplexer |
|--------|----------|-------------|-------------|
| `kiro-notion/` | Kiro CLI | Notion | Zellij |

More coming: `claude-notion/`, `claude-jira/`, etc.

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

- **`task-work <notion-url-or-slug>`** — Creates worktree + branch, opens Zellij tab, launches worker agent
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
