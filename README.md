<p align="center">
  <img src="docs/task-force.png" alt="Task-Force — Tasked to Ship" width="640">
</p>

<h1 align="center">task-force</h1>

<p align="center"><em>Run a squadron of AI coding agents in parallel — each one isolated, briefed, and tasked to ship.</em></p>

<p align="center">
  <a href="https://github.com/martin-conur/agentic-workflow/actions"><img alt="CI" src="https://img.shields.io/badge/tests-bats-blue"></a>
  <a href="#pick-your-loadout"><img alt="impls" src="https://img.shields.io/badge/loadouts-7-red"></a>
  <a href="https://zellij.dev"><img alt="zellij" src="https://img.shields.io/badge/multiplexer-zellij-black"></a>
</p>

---

## What is this?

A small toolkit that lets you run **multiple AI coding agents at the same time** — each one in its own Git worktree and Zellij tab, all coordinating through a shared task tracker (Jira, Notion, or GitHub Projects).

You stay in the cockpit. The agents fly the missions:

- **PM** grooms the backlog and creates tasks
- **Planner** reads the code and writes the spec into the tracker
- **Worker** picks up the spec, implements it on its own branch, runs tests, opens a PR

Pick which AI tool you fly with (**Claude Code** or **Kiro**) and which tracker you brief them through (**Jira**, **Notion**, or **GitHub Projects**). One combo, or all of them.

Inspired by [How I run 4–8 parallel coding agents](https://schipper.ai/posts/parallel-coding-agents/).

---

## Pick your loadout

| Combo | AI Agent | Task Tracker | Folder |
|-------|----------|--------------|--------|
| **claude-jira**   | Claude Code | Jira (Atlassian MCP)                  | [`claude-jira/`](claude-jira/)     |
| **claude-notion** | Claude Code | Notion (Notion MCP)                   | [`claude-notion/`](claude-notion/) |
| **claude-gh**     | Claude Code | GitHub Projects (gh CLI)              | [`claude-gh/`](claude-gh/)         |
| **claude-local**  | Claude Code | Local markdown files (Obsidian-style) | [`claude-local/`](claude-local/)   |
| **kiro-notion**   | Kiro CLI    | Notion (Notion MCP)                   | [`kiro-notion/`](kiro-notion/)     |
| **kiro-gh**       | Kiro CLI    | GitHub Projects (gh CLI)              | [`kiro-gh/`](kiro-gh/)             |
| **kiro-local**    | Kiro CLI    | Local markdown files (Obsidian-style) | [`kiro-local/`](kiro-local/)       |

All seven share the same shape — same roles, same `task-work` / `task-done` commands, same Zellij workflow. The only thing that changes is which AI flies the missions and where the briefings (or markdown task files) live.

---

## Quick start

### 1. Check you have the basics

You always need:

- [Zellij](https://zellij.dev) (≥ 0.44) — the multiplexer that hosts each agent in its own tab
- [gh CLI](https://cli.github.com) — opens pull requests
- Git
- Either [Claude Code](https://docs.claude.com/claude-code) or [Kiro CLI](https://kiro.dev)
- For Jira / Notion trackers, the matching MCP server; for GitHub Projects, just the `gh` CLI authenticated (`gh auth status`) — see [Per-combo setup](#per-combo-setup)

### 2. Clone and install

```bash
git clone https://github.com/martin-conur/agentic-workflow ~/agentic-workflow
cd ~/agentic-workflow
./install.sh
```

`./install.sh` shows an interactive picker (uses fzf or gum if installed, falls back to a numbered menu). Or be explicit:

```bash
./install.sh claude-gh        # install one combo
./install.sh all              # install all seven
```

The installer drops slash commands / agents into your AI tool's config and links `task-work`, `task-done`, and `task-init` into `~/.local/bin`.

### 3. Set up a project

In any Git repo you want to use this with:

```bash
cd ~/my-project
task-init                     # interactive picker
# or skip the picker:
task-init claude-gh
```

This writes a workflow config (e.g. `.claude/gh-workflow.md` or `.kiro/steering/notion-workflow.md`) so your agents know which board to read from. After that, `task-work` and `task-done` **auto-detect** the right combo from that file — see [How the dispatchers work](#how-the-dispatchers-work).

#### Re-running `task-init`

`task-init` is safe to re-run any time you want to pull in new template scaffolding or restore deleted files. Two orthogonal axes of control:

**Scope** — which categories of files to touch:

| Flag         | Files touched                                           |
|--------------|---------------------------------------------------------|
| _(none)_     | workflow doc + slash commands / agents + tasks/ for local |
| `--workflow` | workflow doc only (+ CLAUDE.md import for Claude loadouts) |
| `--commands` | slash commands / agents only                            |

**Overwrite policy** — what to do when a target file already exists:

| Flag        | Existing file behavior                                                                  |
|-------------|-----------------------------------------------------------------------------------------|
| _(TTY)_     | per-file prompt: `[k]eep / [o]verwrite / [d]iff` (default = keep)                       |
| _(non-TTY)_ | silently keep (exit 0) — script-safe                                                    |
| `--force`   | overwrite everything in scope, no prompt                                                |
| `--restore` | fill missing files only; never touch anything that exists                               |

`--force` and `--restore` are mutually exclusive.

When the workflow doc is re-rendered, previously-filled `{OWNER}` / `{REPO}` / `{PROJECT}` / `{SITE}` / `{KEY}` / `{BOARD}` values are **carried forward automatically**. Precedence: this-run flag → existing-file value → `{PLACEHOLDER}`. So `task-init claude-gh --force` after you've already filled in your IDs does the right thing (refreshes the template, keeps your values).

Common use cases:

```bash
task-init claude-gh --restore                # restore a deleted slash command, leave everything else alone
task-init claude-gh --commands --force       # refresh slash commands to current templates
task-init claude-gh --workflow               # pull in template updates, keep current scope's other files
```

### 4. Fly

Open Zellij, start your AI tool, and brief the PM:

```text
/pm show me the backlog
/pm create task for "add login button"
/planner plan the new task
task-work <task-url>          # spawns a fresh tab with a worker on its own branch
```

When the worker is done it opens a PR. Run `task-done` in the worker's tab to clean up the worktree and close the tab.

---

## How the workflow flies

```text
┌─ Zellij Tab 1 (main branch, always open) ──────────────────────┐
│                                                                │
│  /pm       → grooms backlog, creates tasks in the tracker      │
│  /planner  → reads code, writes spec into the task             │
│  task-work → spawns a new tab with a worker on a fresh branch  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
        │
        │ task-work creates a Git worktree + new Zellij tab
        ▼
┌─ Zellij Tabs 2…N (one per task, isolated worktrees) ───────────┐
│                                                                │
│  /worker   → reads spec, implements, tests, commits            │
│  task-done → opens PR, removes worktree, closes the tab        │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Each worker has its own checkout of the repo, so 4–8 of them can fly in parallel without colliding.

---

## How the dispatchers work

`task-work`, `task-done`, and `task-init` are **project-aware dispatchers** that live at the repo root. After install, they're symlinked into `~/.local/bin` and work the same regardless of which combo was installed last.

When you run `task-work` or `task-done` inside a project, the dispatcher detects the impl by looking at which workflow doc is present:

| File present | Combo |
|---|---|
| `.claude/jira-workflow.md`          | `claude-jira`   |
| `.claude/notion-workflow.md`        | `claude-notion` |
| `.claude/gh-workflow.md`            | `claude-gh`     |
| `.claude/local-workflow.md`         | `claude-local`  |
| `.kiro/steering/notion-workflow.md` | `kiro-notion`   |
| `.kiro/steering/gh-workflow.md`     | `kiro-gh`       |
| `.kiro/steering/local-workflow.md`  | `kiro-local`    |

So you can have different combos in different projects and never have to think about it.

**Overrides** (in priority order):

- `--impl <name>` flag
- `AW_IMPL=<name>` environment variable
- Auto-detection from the workflow file

`task-done` is worktree-aware: when run from a task worktree (which has no workflow doc), it falls back to inspecting the main worktree so detection still works.

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

This writes `.claude/jira-workflow.md` and references it from `CLAUDE.md` so every session loads it. See [Re-running `task-init`](#re-running-task-init) for the `--force` / `--restore` / `--workflow` / `--commands` flags.

| Role | How to invoke |
|------|---------------|
| `/pm`      | typed in Claude Code |
| `/planner` | typed in Claude Code |
| `/worker`  | auto-launched by `task-work PROJ-123` |

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

Spawn workers with `task-work <notion-url>`. Same `/pm`, `/planner`, `/worker` roles as `claude-jira`.

### claude-gh — Claude Code + GitHub Projects

**Need:** the [`gh` CLI](https://cli.github.com) authenticated (`gh auth status`; `gh auth login` if not — needs `repo` + `project` scopes).

```bash
./install.sh claude-gh
cd ~/my-project
task-init claude-gh           # auto-detects owner/repo from your git remote
```

`task-init claude-gh` seeds a read-only `gh` allow-list into `.claude/settings.json` so the PM / planner / worker can read freely:

- `gh issue view *` / `gh issue list *` / `gh issue comment *`
- `gh project view *` / `gh project item-list *` / `gh project field-list *` / `gh project list *`
- `gh search issues *`
- `gh pr view *` / `gh pr diff *` / `gh pr list *`
- `gh label list *` / `gh repo view *` / `gh auth status`

Mutations (`gh issue edit`, `gh pr merge`, `gh project item-edit`, …) are deliberately excluded and stay confirmation-gated.

Spawn workers with `task-work <github-issue-url>`. The issue number becomes the worktree slug (`issue-42`).

**Optional add-on:** if you frequently mutate Projects v2 iteration / number fields, add the GitHub MCP:

```bash
claude mcp add --transport stdio github -- npx -y @github/github-mcp-server
```

(requires `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment)

### claude-local — Claude Code + local markdown task tracking

**Need:** nothing extra — no MCP, no remote tracker. Tasks live as files committed inside the repo.

```bash
./install.sh claude-local
cd ~/my-project
task-init claude-local         # creates tasks/, .claude/local-workflow.md, and slash commands
```

`task-init` writes `.claude/local-workflow.md` and references it from `CLAUDE.md`, plus drops a `tasks/` directory and `task-board` into your `~/.local/bin` (alongside the shared dispatchers).

**What "local tracking" means** — there is no Jira, Notion, or GitHub board. The markdown files in `tasks/` *are* the database, and `tasks/_board.md` is an auto-generated kanban view. Everything renders cleanly in Obsidian, so you can plan and read tasks from your editor of choice.

**Layout** under `<repo>/tasks/`:

- One `NNN-slug.md` per task (e.g. `001-add-login-flow.md`). `NNN` is the zero-padded id the PM allocates; `slug` is a kebab-case short title.
- Each file opens with YAML frontmatter (`id`, `title`, `status`, `priority`, `tags`, `created`, `branch`, `pr`) followed by `## Problem`, `## Solution`, `## Files to Create/Modify`, `## Verification`.
- `tasks/_board.md` is the **auto-generated** board — never hand-edit. It has three columns: Todo / In Progress / Done.

**Lifecycle** — `todo` → `in-progress` → `done`. The worker bumps `status` in the task file's frontmatter on its first commit (`in-progress`) and again before opening the PR (`done`). The PM is the only role that creates new task files and allocates ids.

**`task-board`** — regenerates `tasks/_board.md` from `tasks/*.md` frontmatter, overlaying live worktree state. It runs automatically after `task-work` and `task-done` (and whenever the PM mutates a task), but you can also run it manually to refresh the view:

```bash
task-board                    # uses $(git rev-parse --show-toplevel)
task-board --repo ~/other     # explicit repo
```

**Live state** — `.git/task-force/state.json` is a gitignored, per-clone sidecar that tracks which worktrees are currently active. `task-work` writes a row; `task-done` removes it. Frontmatter is the durable, committed state; the sidecar is the live overlay. If a task appears in the sidecar, the board forces it into the In Progress column regardless of frontmatter.

Spawn workers with `task-work tasks/NNN-slug.md`. The slug (filename minus the `NNN-` prefix and `.md` suffix) becomes the worktree name — `001-add-login-flow.md` → worktree `add-login-flow` on branch `task/add-login-flow`.

| Role | How to invoke |
|------|---------------|
| `/pm`      | typed in Claude Code |
| `/planner` | typed in Claude Code |
| `/worker`  | auto-launched by `task-work tasks/NNN-slug.md` |

### kiro-notion — Kiro CLI + Notion

**Need:** Kiro CLI with Notion MCP configured.

```bash
./install.sh kiro-notion
cd ~/my-project
task-init kiro-notion
# Edit .kiro/steering/notion-workflow.md with your Notion database IDs
```

Agents are bound to Kiro shortcuts:

| Agent     | Shortcut         |
|-----------|------------------|
| `pm`      | `ctrl+shift+p`   |
| `planner` | `ctrl+shift+l`   |
| `worker`  | `ctrl+shift+w`   |

### kiro-gh — Kiro CLI + GitHub Projects

**Need:** the [`gh` CLI](https://cli.github.com) authenticated (`gh auth status`; `gh auth login` if not — needs `repo` + `project` scopes). The bundled Kiro agents shell out to `gh` via `execute_bash`.

```bash
./install.sh kiro-gh
cd ~/my-project
task-init kiro-gh
```

Same Kiro shortcuts as `kiro-notion`.

**Optional add-on:** if you frequently mutate Projects v2 iteration / number fields, add the GitHub MCP to each agent's `mcpServers` block in `.kiro/agents/*.json` and set `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment.

### kiro-local — Kiro CLI + local markdown task tracking

**Need:** nothing extra — no MCP, no remote tracker. Same model as `claude-local`, just driven by Kiro instead of Claude Code.

```bash
./install.sh kiro-local
cd ~/my-project
task-init kiro-local           # creates tasks/, .kiro/steering/local-workflow.md, and agents
```

Tasks live in `<repo>/tasks/*.md` with the same NNN-slug filenames, frontmatter schema (`id`, `title`, `status`, `priority`, `tags`, `created`, `branch`, `pr`), and four-section body (`## Problem`, `## Solution`, `## Files to Create/Modify`, `## Verification`) as `claude-local`. `tasks/_board.md` is auto-generated by `task-board`.

**Lifecycle** — `todo` → `in-progress` → `done`, with the worker mutating frontmatter on first commit and again before the PR. The PM allocates ids and creates new task files. The board script triggers automatically from `task-work` / `task-done` / PM mutations, and can be run by hand:

```bash
task-board
```

**Live state** — `.git/task-force/state.json` is the gitignored, per-clone sidecar that overlays live worktree state on top of the committed frontmatter. Same model as `claude-local`.

Spawn workers with `task-work tasks/NNN-slug.md`. Same Kiro shortcuts as `kiro-notion`.

---

## PM ↔ worker messaging (radio)

Once you've installed a Claude loadout, `task-init` auto-installs **radio** — a low-latency mailbox CLI under `~/.task-force/radio/` that lets the PM agent and worker agents ping each other directly. No human courier, seconds-level wake-up when the recipient tab is idle, queue-and-defer when busy. The `kiro-*` loadouts install the equivalent hooks under `.kiro/hooks/` instead.

### Command surface

| Command | What it does |
|---------|--------------|
| `radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]` | Send a message (e.g. `--to pm --intent review-requested --pr 42`); body can come from stdin |
| `radio check`                       | List unread messages addressed to this role |
| `radio read <id>`                   | Print one message |
| `radio ack <id>`                    | Mark it acknowledged so it stops showing up in `check` |
| `radio register` / `radio unregister` | Add/remove this tab's session file (`~/.task-force/radio/sessions/<role>.info`) |
| `radio ready` / `radio busy`        | Toggle this session's `STATE` field — drives the wake-up vs. queue decision on the sender side |
| `radio orphans`                     | List session files whose heartbeat is >1h stale |

Intents are free-form labels — `review-requested`, `re-review-requested`, `changes-requested`, `approved`, etc. PR review *content* still lives in `gh pr comment` / `gh pr review`; radio only carries the routing ping.

### How wake-up works

`radio send` reads the recipient's session file. If `STATE=idle`, it focuses the recipient's zellij tab via `zellij action go-to-tab-name` and on the recipient's next turn end, the `Stop` hook (`radio ready && radio check`) surfaces the new message. If `STATE=busy`, the message is queued silently — no failed wake attempt, no interrupting the recipient mid-turn.

Role names are addressable strings, not free-form: the PM is `pm`, and each worker is `worker-<reponame>-<slug>` (e.g. `worker-task-force-issue-42`). List live ones with `ls ~/.task-force/radio/sessions/`.

### The hooks that make it work

`task-init claude-*` writes these into your project's `.claude/settings.json` automatically:

| Hook              | Command                       | Why                                            |
|-------------------|-------------------------------|------------------------------------------------|
| `SessionStart`    | `radio register`              | Claims the role's session file for this tab    |
| `UserPromptSubmit`| `radio busy`                  | Marks the session busy while a turn is running |
| `Stop`            | `radio ready && radio check`  | Marks idle and surfaces any queued messages    |

For the kiro loadouts the same logic lives in `.kiro/hooks/` and runs off Kiro's equivalent triggers.

### Idle workers don't auto-act

A queued message arriving at an idle worker won't kick it into motion on its own — the worker only sees the message on its **next turn** (a human keystroke or its own next prompt). This is deliberate: radio is **notification + queue**, not auto-action. If you want fully autonomous handoffs, dispatch the worker with `task-work --auto` and bake all the instructions into the issue body.

### Cleanup

If a tab dies unexpectedly (or Claude resumes without re-firing `SessionStart`), the session file's `LAST_HEARTBEAT` will go stale. Run `radio orphans` to list any session older than an hour. Safe to `rm ~/.task-force/radio/sessions/<role>.info` or just leave it — the next legitimate `radio register` overwrites it.

---

## The normal workflow

Here's what an end-to-end PR cycle looks like once everything is wired up:

**1. Spin up the PM.** In any zellij tab:

```bash
task-pm
```

Renames the current tab to `pm`, registers via the `SessionStart` hook, and starts the PM agent in-place.

**2. PM grooms the backlog and picks an issue.** From the PM tab:

```text
/pm show me the backlog          # or: gh issue list --state open
/pm let's do issue 42
```

PM picks one and spawns a worker:

```bash
task-work issue-42 https://github.com/<owner>/<repo>/issues/42 --auto
```

This creates a worktree, opens a new zellij tab, and launches the worker agent (`--auto` runs it under auto-approve since the issue body is self-contained).

**3. Worker implements.** In the worker tab the agent reads the spec, edits files, runs tests, commits with the issue title as a prefix, and opens the PR:

```bash
gh pr create --base main --head task/issue-42 --fill
```

**4. Worker pings PM.** Once the worker is done it's idle, so the `Stop` hook fires `radio ready`. The worker can nudge the PM directly:

```bash
radio send --to pm --intent review-requested --pr 42
```

PM's zellij tab gets focused; on its next turn end the `Stop` hook's `radio check` surfaces the ping.

**5. PM reviews the PR.** From the PM tab:

```bash
gh pr view 42
gh pr diff 42
gh pr review 42 --comment --body "…"   # or: gh pr comment 42 --body "…"
```

**6. Round-trip until merge.** PM requests changes (worker roles are `worker-<reponame>-<slug>`; see `ls ~/.task-force/radio/sessions/`):

```bash
radio send --to worker-task-force-issue-42 --intent changes-requested --pr 42
```

The worker tab is focused, picks up the comments, pushes fixes, and pings back:

```bash
radio send --to pm --intent re-review-requested --pr 42
```

**7. Merge + cleanup.** PM merges:

```bash
gh pr merge 42 --squash --delete-branch
```

In the worker tab:

```bash
task-done --remove-worktree
```

That removes the worktree and closes the zellij tab. Done.

---

## `task-work` flags

Common to every combo:

- `-b, --base BRANCH` — branch the PR will target (default: branch you're on when `task-work` runs)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: current HEAD). Accepts any ref `git` accepts (branches, tags, SHAs, `origin/foo`). Use this to stack a PR on an in-flight branch (`--from task/issue-46 --base main`) or to spike off `origin/main` without checking it out first.
- `--no-launch` — create the worktree and open the tab at that directory, but don't auto-start the agent (you pick the model/command yourself)
- `--impl <name>` — force a specific combo, bypassing auto-detection

`kiro-*` combos also accept `-m/--model MODEL` and `-a/--trust-all`.

---

## Testing

Tests live in `tests/` and use [bats-core](https://github.com/bats-core/bats-core).

```bash
git submodule update --init --recursive   # first time only
./run_tests.sh                            # run everything
./run_tests.sh task_done                  # run a single suite
```

<details>
<summary><b>Test suites</b> (click to expand)</summary>

| Suite | Covers |
|-------|--------|
| `install.bats`                    | Root `install.sh` — direct args, fzf/gum TUI, numbered-menu fallback |
| `task_init_dispatcher.bats`       | Root `task-init` — impl dispatch, passthrough flags, TUI selector |
| `task_work_dispatcher.bats`       | Root `bin/task-work` — auto-detect impl, `--impl`/`AW_IMPL` overrides, passthrough |
| `task_done_dispatcher.bats`       | Root `bin/task-done` — same detection + worktree-aware fallback |
| `jira_task_work.bats`             | `claude-jira/bin/task-work` — input parsing, worktree, zellij launch |
| `jira_task_init.bats`             | `claude-jira/bin/task-init` — placeholder substitution, CLAUDE.md, `--force` |
| `claude_notion_task_work.bats`    | `claude-notion/bin/task-work` — URL/slug detection, worktree, zellij launch |
| `claude_notion_task_init.bats`    | `claude-notion/bin/task-init` — template copy, CLAUDE.md, `--force` |
| `claude_gh_task_work.bats`        | `claude-gh/bin/task-work` — GitHub URL → `issue-N` slug, launch |
| `claude_gh_task_init.bats`        | `claude-gh/bin/task-init` — owner/repo/project substitution, remote auto-detect |
| `claude_local_task_work.bats`     | `claude-local/bin/task-work` — `tasks/NNN-slug.md` → kebab `slug` (NNN- stripped), frontmatter bump, board regen |
| `claude_local_task_init.bats`     | `claude-local/bin/task-init` — `tasks/` scaffolding, `.claude/local-workflow.md`, slash commands |
| `kiro_task_work.bats`             | `kiro-notion/bin/task-work` — URL/slug detection, model/trust-all flags |
| `kiro_notion_task_init.bats`      | `kiro-notion/bin/task-init` — template copy, `--force` |
| `kiro_gh_task_work.bats`          | `kiro-gh/bin/task-work` — same as `claude-gh` but launching `kiro-cli` |
| `kiro_gh_task_init.bats`          | `kiro-gh/bin/task-init` — owner/repo/project substitution |
| `kiro_local_task_work.bats`       | `kiro-local/bin/task-work` — same as `claude-local` but launching `kiro-cli` |
| `kiro_local_task_init.bats`       | `kiro-local/bin/task-init` — `tasks/` scaffolding, `.kiro/steering/local-workflow.md`, agents |
| `task_board.bats`                 | Shared `task-board` script — frontmatter parsing, sidecar overlay, `_board.md` regen |
| `task_done.bats`                  | `task-done` across combos — cleanup, PR, guards |

</details>

Infrastructure:

- `tests/helpers/common.bash` — `setup_repo`, `setup_stubs`, `setup_worktree`, `teardown_all`, `assert_stub_called`
- `tests/helpers/stubs/` — fakes for `zellij`, `gh`, `kiro-cli`, `claude`; every call lands in `$STUB_CALLS_DIR/*.calls`
- `tests/libs/` — bats-core, bats-support, bats-assert as git submodules

---

## Contributing

### Add a new combo

1. Create `<impl-name>/` with `install.sh`, `bin/task-work`, `bin/task-done`, `bin/task-init`, and a `steering/*.example.md`.
2. Add `<impl-name>` to the picker and `case` statement in the root `install.sh`.
3. Add `<impl-name>` to the picker and `case` statement in the root `task-init`.
4. Add the new workflow doc filename to `lib/detect-impl.sh` so dispatchers can route to it.
5. Add a row to the loadout table and a per-combo section in this README.
6. Write tests — one `.bats` file per script.

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

---

## Maintaining task-force

`main` is protected via the GitHub API (not a YAML file), so the config lives off-repo. The current rules:

- Required status checks (all four must be green before merge): `ShellCheck`, `Bats tests (ubuntu-latest)`, `Bats tests (macos-latest)`, `Loadout drift check`
- `strict=true` — PR branch must be up-to-date with `main`
- `enforce_admins=true` — the maintainer can't bypass either
- Force-pushes and branch deletion blocked

Re-apply (or restore after an accidental clear):

```bash
gh api -X PUT repos/martin-conur/task-force/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "ShellCheck",
      "Bats tests (ubuntu-latest)",
      "Bats tests (macos-latest)",
      "Loadout drift check"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

Inspect: `gh api repos/martin-conur/task-force/branches/main/protection | jq`.

---

## License

[MIT](LICENSE) © Martin Conur
