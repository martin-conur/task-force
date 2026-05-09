# agentic-workflow

Parallel AI coding agents for the terminal: multiple workers, each in an isolated Git worktree and Zellij tab, coordinating through a task tracker.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/).

## Contents

- [Implementations](#implementations)
- [Requirements](#requirements)
- [Install](#install)
- [claude-jira](#claude-jira)
- [kiro-notion](#kiro-notion)
- [claude-notion](#claude-notion)
- [Testing](#testing)
- [Contributing](#contributing)

---

## Implementations

| Folder | AI Agent | Task Tracker | Multiplexer |
|--------|----------|-------------|-------------|
| `claude-jira/` | Claude Code | Jira (Atlassian MCP) | Zellij |
| `kiro-notion/` | Kiro CLI | Notion | Zellij |
| `claude-notion/` | Claude Code | Notion | Zellij |

---

## Requirements

| Tool | claude-jira | kiro-notion | claude-notion |
|------|:-----------:|:-----------:|:-------------:|
| [Claude Code](https://docs.claude.com/claude-code) | ✓ | — | ✓ |
| [Kiro CLI](https://kiro.dev) | — | ✓ | — |
| [Atlassian Remote MCP](https://developer.atlassian.com/cloud/jira/platform/remote-mcp-server/) | ✓ | — | — |
| [Notion MCP](https://mcp.notion.com) | — | ✓ | ✓ |
| [Zellij](https://zellij.dev) | ✓ | ✓ | ✓ |
| [gh CLI](https://cli.github.com) | ✓ | ✓ | ✓ |
| Git | ✓ | ✓ | ✓ |

---

## Install

Clone the repo once, then install one or all implementations:

```bash
git clone <this-repo> ~/agentic-workflow
cd ~/agentic-workflow
./install.sh             # interactive menu
# or:
./install.sh claude-notion   # specific implementation
./install.sh all             # all three
```

Each implementation can also be installed independently (backward-compatible):

```bash
cd claude-jira && ./install.sh
cd kiro-notion && ./install.sh
cd claude-notion && ./install.sh
```

### Per-project setup

After installing, run `task-init` in any project root to configure it for a specific workflow. A single `task-init` binary handles all implementations — useful when you use different workflows across projects:

```bash
cd ~/my-project
task-init                        # interactive menu
task-init claude-notion          # set up for claude-notion
task-init kiro-notion            # set up for kiro-notion
task-init claude-jira --site https://acme.atlassian.net --key PROJ
```

---

## claude-jira

Claude Code CLI + Jira via Atlassian Remote MCP.

### Prerequisites

- [Claude Code](https://docs.claude.com/claude-code) with the Atlassian Remote MCP configured
  - Verify: `claude mcp list` (should show an `atlassian` entry)
- [Zellij](https://zellij.dev)
- [gh](https://cli.github.com)

### Install

```bash
./install.sh claude-jira
```

### Setup per project

```bash
cd ~/my-project
task-init claude-jira --site https://acme.atlassian.net --key PROJ --board "My Board"
```

This creates `.claude/jira-workflow.md` from the template and adds `@.claude/jira-workflow.md` to `CLAUDE.md`. Run without flags to leave `{placeholders}` you can fill manually. Use `--force` to overwrite.

### Roles

| Role | Invocation | Purpose |
|------|------------|---------|
| `/pm` | typed in Claude Code | Backlog grooming, issue creation, prioritization |
| `/planner` | typed in Claude Code | Reads code, designs solutions, writes specs into Jira |
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

---

## kiro-notion

Kiro CLI + Notion MCP.

### Prerequisites

- [Kiro CLI](https://kiro.dev) with Notion MCP configured
- [Zellij](https://zellij.dev)
- [gh](https://cli.github.com)

### Install

```bash
./install.sh kiro-notion
```

### Setup per project

```bash
cd ~/my-project
task-init kiro-notion
# Edit .kiro/steering/notion-workflow.md with your Notion database IDs
```

### Agents

| Agent | Shortcut | Role |
|-------|----------|------|
| `pm` | `ctrl+shift+p` | Backlog grooming, task creation, prioritization |
| `planner` | `ctrl+shift+l` | Reads code, designs solutions, writes specs to Notion |
| `worker` | `ctrl+shift+w` | Implements from Notion spec, tests, commits |

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

`task-work` options: `-m/--model MODEL`, `-a/--trust-all`, `-b/--base BRANCH`, `--no-launch`.

---

## claude-notion

Claude Code CLI + Notion MCP.

### Prerequisites

- [Claude Code](https://docs.claude.com/claude-code) with the Notion MCP configured
  - Add: `claude mcp add --transport http notion https://mcp.notion.com/mcp`
  - Verify: `claude mcp list` (should show a `notion` entry)
- [Zellij](https://zellij.dev)
- [gh](https://cli.github.com)

### Install

```bash
./install.sh claude-notion
```

### Setup per project

```bash
cd ~/my-project
task-init claude-notion
# Edit .claude/notion-workflow.md with your Notion database IDs
```

This creates `.claude/notion-workflow.md` from the template and adds `@.claude/notion-workflow.md` to `CLAUDE.md` so every Claude Code session loads it automatically.

### Roles

| Role | Invocation | Purpose |
|------|------------|---------|
| `/pm` | typed in Claude Code | Backlog grooming, task creation, prioritization |
| `/planner` | typed in Claude Code | Reads code, designs solutions, writes specs to Notion |
| `/worker` | auto-launched by `task-work` | Implements from Notion spec in an isolated worktree |

### Workflow

```
Zellij Tab 1 (permanent, main branch):
  claude
  /pm show me the backlog              → reads Notion
  /pm create task for X
  /planner plan the task               → reads code, writes spec to Notion
  task-work https://notion.so/...      → new tab appears

Zellij Tab 2+ (auto-created by task-work):
  claude "/worker Implement task: <url>"   → reads spec, implements
  task-done                                 → PR command, cleanup, close tab
```

`task-work` options: `-b/--base BRANCH`, `--no-launch`.

---

## Testing

Tests are written with [bats-core](https://github.com/bats-core/bats-core) and live in `tests/`.

### Run all tests

```bash
git submodule update --init --recursive  # first time only
./run_tests.sh
```

### Run a single suite

```bash
./run_tests.sh task_done
./run_tests.sh claude_notion_task_work
```

### Test suites

| Suite | What it covers |
|-------|----------------|
| `jira_task_work.bats` | `claude-jira/bin/task-work` — input parsing, worktree creation, zellij launch |
| `jira_task_init.bats` | `claude-jira/bin/task-init` — placeholder substitution, CLAUDE.md, --force |
| `kiro_task_work.bats` | `kiro-notion/bin/task-work` — URL/slug detection, worktree, model/trust-all flags |
| `claude_notion_task_work.bats` | `claude-notion/bin/task-work` — URL/slug detection, worktree, zellij launch |
| `claude_notion_task_init.bats` | `claude-notion/bin/task-init` — template copy, CLAUDE.md, --force |
| `task_done.bats` | `task-done` for kiro-notion, claude-jira, and claude-notion — cleanup, PR, guards |

### Test infrastructure

- `tests/helpers/common.bash` — `setup_repo`, `setup_stubs`, `setup_worktree`, `teardown_all`, `assert_stub_called`
- `tests/helpers/stubs/` — fake `zellij`, `gh`, `kiro-cli`, `claude` that record all invocations to `$STUB_CALLS_DIR/*.calls`
- `tests/libs/` — bats-core, bats-support, bats-assert as git submodules

---

## Contributing

### Adding a new implementation

1. Create `<impl-name>/` with `install.sh`, `bin/task-work`, `bin/task-done`, `bin/task-init`, and a `steering/*.example.md`.
2. Add `<impl-name>` to the menu in the root `install.sh` case statement.
3. Add `<impl-name>` to the menu in the root `task-init` (for per-project setup).
4. Add the new implementation to the Requirements and Implementations tables in this README.
5. Write tests (see below).

### Writing tests

One `.bats` file per script. Follow the existing pattern:

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

Add script path variables to `tests/helpers/common.bash`. The test runner (`run_tests.sh`) picks up all `tests/*.bats` files automatically.

### Shell style

- `set -euo pipefail` in every script
- Quote all variables
- No package managers, no compiled code — pure shell only
- 2-space indentation
