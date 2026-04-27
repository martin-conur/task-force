# kiro-agents

Parallel coding agents for [Kiro CLI](https://kiro.dev) using Notion as task tracker and Zellij as terminal multiplexer.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/) — adapted from Claude Code + Jira + tmux to Kiro CLI + Notion + Zellij.

## Prerequisites

- [Kiro CLI](https://kiro.dev) with Notion MCP configured
- [Zellij](https://zellij.dev) terminal multiplexer
- [gh](https://cli.github.com) (GitHub CLI) for PRs
- Git

## Install

```bash
git clone <this-repo> ~/kiro-agents
cd ~/kiro-agents
./install.sh
```

This symlinks agents to `~/.kiro/agents/` and scripts to `~/.local/bin/`.

## Setup per project

Copy the steering file template into your project:

```bash
mkdir -p .kiro/steering
cp ~/kiro-agents/steering/notion-workflow.example.md .kiro/steering/notion-workflow.md
```

Edit it with your Notion database IDs (use `notion-fetch` on your board URL to find them).

## Agents

| Agent | Shortcut | Role |
|-------|----------|------|
| `pm` | `ctrl+shift+p` | Backlog grooming, task creation, prioritization |
| `planner` | `ctrl+shift+l` | Reads code, designs solutions, writes specs to Notion |
| `worker` | `ctrl+shift+w` | Implements from Notion spec, tests, commits |

## Scripts

**`fd-work <notion-url-or-slug>`** — Start working on a task:
- Creates a git worktree + branch (`task/<slug>`)
- Opens a new Zellij tab
- Launches `kiro-cli chat --agent worker` in the worktree

**`fd-done`** — Finish a task (run from within the worktree):
- Shows diff summary
- Prints `gh pr create` command
- Removes worktree and closes Zellij tab

## Workflow

```
Zellij Tab 1 (permanent, main branch):
  kiro-cli chat --agent pm

  "show me the backlog"              → reads Notion
  "create task for X"                → creates in Notion
  /agent swap planner                → switch to planner
  "plan task X"                      → reads code, writes spec to Notion
  "start work on task X"             → runs fd-work, new tab appears
  /agent swap pm                     → back to PM

Zellij Tab 2+ (auto-created by fd-work):
  kiro-cli chat --agent worker       → in worktree, reads spec, implements
  fd-done                            → PR, cleanup, close tab
```
