<p align="center">
  <img src="docs/task-force.png" alt="Task-Force — Tasked to Ship" width="520">
</p>

<h1 align="center">task-force</h1>

<p align="center"><em>Run a squadron of AI coding agents in parallel — each one isolated, briefed, and tasked to ship.</em></p>

---

## What is this?

A small toolkit that lets you run **multiple AI coding agents at the same time**, each in its own Git worktree and Zellij tab, all coordinating through a shared task tracker (Jira, Notion, or GitHub Projects).

You stay in the cockpit. The agents fly the missions:

- **PM** grooms the backlog and creates tasks
- **Planner** reads the code and writes the spec into the tracker
- **Worker** picks up the spec, implements it on its own branch, and opens a PR

You pick which AI tool (**Claude Code** or **Kiro**) and which tracker (**Jira**, **Notion**, or **GitHub Projects**). Pick one combo, or install all of them.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/).

---

## Pick your loadout

| Combo | AI Agent | Task Tracker | Folder |
|-------|----------|--------------|--------|
| **claude-jira** | Claude Code | Jira (Atlassian MCP) | [`claude-jira/`](claude-jira/) |
| **claude-notion** | Claude Code | Notion (Notion MCP) | [`claude-notion/`](claude-notion/) |
| **claude-gh** | Claude Code | GitHub Projects (GitHub MCP) | [`claude-gh/`](claude-gh/) |
| **kiro-notion** | Kiro CLI | Notion (Notion MCP) | [`kiro-notion/`](kiro-notion/) |
| **kiro-gh** | Kiro CLI | GitHub Projects (GitHub MCP) | [`kiro-gh/`](kiro-gh/) |

All five share the same shape — same roles, same `task-work` / `task-done` commands, same Zellij workflow. The only thing that changes is which AI runs the agents and where tasks live.

---

## Quick start

### 1. Check you have the basics

You always need:

- [Zellij](https://zellij.dev) — the terminal multiplexer that hosts each agent in its own tab
- [gh CLI](https://cli.github.com) — opens pull requests
- Git
- Either [Claude Code](https://docs.claude.com/claude-code) or [Kiro CLI](https://kiro.dev) (depending on your combo)
- The MCP server for your tracker (Atlassian, Notion, or GitHub — see the combo-specific section below)

### 2. Clone and install

```bash
git clone <this-repo> ~/agentic-workflow
cd ~/agentic-workflow
./install.sh
```

`./install.sh` shows an interactive picker (fzf or gum if available, falls back to a numbered menu). Or be explicit:

```bash
./install.sh claude-gh        # install one
./install.sh all              # install everything
```

The installer drops slash commands / agents into your AI tool's config directory and links `task-work`, `task-done`, and `task-init` into `~/.local/bin`.

### 3. Set up a project

In any Git repo you want to use this with:

```bash
cd ~/my-project
task-init           # interactive picker, or pass the combo name
```

This writes a workflow config to `.claude/` or `.kiro/steering/` so your agents know which board to read from.

### 4. Fly

Open Zellij, start your AI tool, and ask the PM:

```
/pm show me the backlog
/pm create task for "add login button"
/planner plan the new task
task-work <task-url>         # spawns a new tab with a worker agent
```

When the worker is done it opens a PR. Run `task-done` in its tab to clean up the worktree and close the tab.

---

## How the workflow flies

```
┌─ Zellij Tab 1 (main branch, always open) ──────────────────────┐
│                                                                │
│  /pm       → grooms backlog, creates tasks in your tracker     │
│  /planner  → reads code, writes spec into the tracker          │
│  task-work → spawns a new tab with a worker on a fresh branch  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
         │
         │ task-work creates a Git worktree + new Zellij tab
         ▼
┌─ Zellij Tab 2, 3, 4… (one per task, isolated worktree) ────────┐
│                                                                │
│  /worker   → reads spec, implements, tests, commits            │
│  task-done → opens PR, removes worktree, closes the tab        │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Each worker has its own checkout of the repo, so you can have 4–8 of them coding in parallel without stepping on each other.

---

## Per-combo setup

Pick the section that matches what you installed.

### claude-jira — Claude Code + Jira

**Need:** Claude Code with the [Atlassian Remote MCP](https://developer.atlassian.com/cloud/jira/platform/remote-mcp-server/) added (verify with `claude mcp list`).

```bash
./install.sh claude-jira
cd ~/my-project
task-init claude-jira --site https://acme.atlassian.net --key PROJ --board "My Board"
```

This writes `.claude/jira-workflow.md` and references it from `CLAUDE.md` so every session loads it.

| Role | Invocation |
|------|------------|
| `/pm` | typed in Claude Code |
| `/planner` | typed in Claude Code |
| `/worker` | auto-launched by `task-work PROJ-123` |

### claude-notion — Claude Code + Notion

**Need:** Claude Code with the Notion MCP added:

```bash
claude mcp add --transport http notion https://mcp.notion.com/mcp
```

```bash
./install.sh claude-notion
cd ~/my-project
task-init claude-notion
# Edit .claude/notion-workflow.md and drop in your Notion database IDs
```

Use `task-work <notion-url>` to spawn workers.

### claude-gh — Claude Code + GitHub Projects

**Need:** Claude Code with the GitHub MCP added, plus a `GITHUB_PERSONAL_ACCESS_TOKEN` (repo + project scopes) in your environment.

```bash
claude mcp add --transport stdio github -- npx -y @github/github-mcp-server
./install.sh claude-gh
cd ~/my-project
task-init claude-gh    # auto-detects owner/repo from git remote
```

Use `task-work <github-issue-url>` to spawn workers. The issue number becomes the worktree slug (`issue-42`).

### kiro-notion — Kiro CLI + Notion

**Need:** Kiro CLI with Notion MCP configured.

```bash
./install.sh kiro-notion
cd ~/my-project
task-init kiro-notion
# Edit .kiro/steering/notion-workflow.md with your Notion database IDs
```

Agents are bound to Kiro shortcuts:

| Agent | Shortcut |
|-------|----------|
| `pm` | `ctrl+shift+p` |
| `planner` | `ctrl+shift+l` |
| `worker` | `ctrl+shift+w` |

### kiro-gh — Kiro CLI + GitHub Projects

**Need:** Kiro CLI plus `GITHUB_PERSONAL_ACCESS_TOKEN` (repo + project scopes).

```bash
./install.sh kiro-gh
cd ~/my-project
task-init kiro-gh
```

Same role shortcuts as `kiro-notion`.

---

## `task-work` options

Common across every combo:

- `-b, --base BRANCH` — base branch for the eventual PR (default: current branch when `task-work` runs)
- `--no-launch` — create the worktree and open the tab at that directory, but don't auto-start the agent (you pick the model/command yourself)

`kiro-*` combos also accept `-m/--model MODEL` and `-a/--trust-all`.

---

## Testing

Tests are written with [bats-core](https://github.com/bats-core/bats-core) and live in `tests/`.

```bash
git submodule update --init --recursive   # first time only
./run_tests.sh                            # run everything
./run_tests.sh task_done                  # run one suite
```

| Suite | Covers |
|-------|--------|
| `install.bats` | Root `install.sh` dispatcher |
| `task_init_dispatcher.bats` | Root `task-init` dispatcher |
| `jira_task_work.bats` / `jira_task_init.bats` | `claude-jira/bin/` |
| `claude_notion_task_work.bats` / `claude_notion_task_init.bats` | `claude-notion/bin/` |
| `claude_gh_task_work.bats` / `claude_gh_task_init.bats` | `claude-gh/bin/` |
| `kiro_task_work.bats` / `kiro_notion_task_init.bats` | `kiro-notion/bin/` |
| `kiro_gh_task_work.bats` / `kiro_gh_task_init.bats` | `kiro-gh/bin/` |
| `task_done.bats` | `task-done` across all combos |

Test infrastructure:

- `tests/helpers/common.bash` — `setup_repo`, `setup_stubs`, `setup_worktree`, `teardown_all`, `assert_stub_called`
- `tests/helpers/stubs/` — fakes for `zellij`, `gh`, `kiro-cli`, `claude` that record every invocation
- `tests/libs/` — bats-core, bats-support, bats-assert as git submodules

---

## Contributing

### Adding a new implementation

1. Create `<impl-name>/` with `install.sh`, `bin/task-work`, `bin/task-done`, `bin/task-init`, and a `steering/*.example.md`.
2. Add `<impl-name>` to the picker and `case` statement in the root `install.sh`.
3. Add `<impl-name>` to the picker and `case` statement in the root `task-init`.
4. Add a row to the implementations table at the top of this README and a per-combo section below.
5. Write tests — one `.bats` file per script.

### Test pattern

```bash
#!/usr/bin/env bats
bats_load_library bats-support
bats_load_library bats-assert
load helpers/common

setup() { setup_repo; setup_stubs; cd "$MAIN_REPO"; }
teardown() { teardown_all; }

@test "description" {
  run "$MY_SCRIPT" arg
  assert_success
  assert_output --partial "expected text"
  assert_stub_called zellij "some-command"
}
```

Add script path variables to `tests/helpers/common.bash`. The runner picks up every `tests/*.bats` file automatically.

### Shell style

- `set -euo pipefail` in every script
- Quote every variable
- No package managers, no compiled code — pure shell
- 2-space indentation
