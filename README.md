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

The installer drops slash commands / agents into your AI tool's config and links `task-work`, `task-done`, `task-init`, `task-board`, `task-pm`, `radio`, and `ci-guard` into `~/.local/bin`.

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

**The workflow doc is a managed region.** It is the one installed file you are actively encouraged to edit — repo-specific guidance belongs in it — and also the one a documented upgrade re-renders. So `task-init` writes it with a boundary inside:

```markdown
<!-- task-init:managed:start -->
…the rendered template — task-init owns this and rebuilds it on every re-run…
<!-- task-init:managed:end -->

## Repo-specific notes      ← yours, forever
```

A re-run rebuilds only what is between the markers and copies everything outside them through verbatim. Anything you add below the end marker — what "Green" means in this repo, a pre-PR checklist, local conventions — survives `--force`. Because that refresh cannot touch your content, it no longer prompts about the workflow doc at all; `--restore` and the non-TTY default still leave the file completely alone.

A doc written before this existed has no markers. The first re-run adopts it: if it is byte-identical to the template it is simply re-wrapped, and if you have edited it the old file is copied to `<doc>.bak` first, with a note telling you to move what you want to keep below the end marker. Nothing is deleted either way.

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

`task-work`, `task-done`, `task-init`, and `task-board` are **project-aware dispatchers** that live at the repo root. After install, they're symlinked into `~/.local/bin` and work the same regardless of which combo was installed last.

When you run one of them inside a project, the dispatcher detects the impl by looking at which workflow doc is present:

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

`task-done` is worktree-aware: when run from a task worktree (which has no workflow doc), it falls back to inspecting the main worktree so detection still works. `task-board` detects from `--repo PATH` when that flag is given, since `task-work` and `task-done` call it that way from a worktree.

**`task-board` is the one dispatcher that can refuse.** It renders `tasks/_board.md` out of local task-file frontmatter, which only the two local-tracking loadouts have — so on a `gh` / `jira` / `notion` repo it exits non-zero naming the detected loadout and where that repo's board actually lives:

```
$ task-board                       # in a claude-gh repo
Error: task-board is only available on the local-tracking loadouts
       (claude-local, kiro-local); this repo uses 'claude-gh'.
       It renders tasks/_board.md from local task-file frontmatter,
       which a 'claude-gh' repo has none of — its board lives in GitHub Projects.
```

Every loadout links it anyway, on purpose: a command that explains itself beats one that is silently missing. Before #215 only the two `*-local` installers linked `task-board`, each straight at its own copy — so it was absent everywhere else, and installing both local loadouts left whichever ran last owning the symlink.

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

`task-init` writes `.claude/local-workflow.md` and references it from `CLAUDE.md`, plus drops a `tasks/` directory. `task-board` is one of the shared root dispatchers installed by every loadout — on this one it resolves to `claude-local/bin/task-board`.

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

Once you've installed a Claude loadout, `task-init` auto-installs **radio** — a low-latency mailbox CLI under `~/.task-force/radio/` that lets the PM agent and worker agents ping each other directly. No human courier, seconds-level wake-up when the recipient tab is idle, queue-and-defer when busy. The `kiro-*` loadouts merge the corresponding hooks into each `.kiro/agents/*.json` instead — with weaker delivery guarantees; see [kiro delivery](#kiro-delivery-pull-first-with-one-backstop).

Radio is the **canonical** coordination channel between the planner, PM, and workers — every role transition in the workflow runs through it. The PM / planner / worker prompts shell out to `radio send` at every documented handoff point.

### The handoff cycle

These are the five transitions that make up a full PR cycle. Each one is a single `radio send` call, baked into the corresponding agent's prompt:

| From    | When                            | Command                                                                |
|---------|---------------------------------|------------------------------------------------------------------------|
| Planner | spec written into the issue     | `radio send --to pm --intent spec-ready --issue <N>`                   |
| Worker  | PR opened                       | `radio send --to pm --intent review-requested --pr <N>`                |
| Worker  | new commits pushed after review | `radio send --to pm --intent re-review-requested --pr <N>`             |
| PM      | review requested changes        | `radio send --to <worker-role> --intent changes-requested --pr <N>`    |
| PM      | PR merged                       | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`  |

PR review *content* still lives in `gh pr comment` / `gh pr review` (or the equivalent on Jira / Notion / local); radio only carries the routing ping.

Role names are addressable strings, not free-form: the PM is `pm-<reponame>` (per-repo since #165, so two repos' PMs never collide), and each worker is `worker-<reponame>-<slug>` (e.g. `worker-task-force-issue-42`). List live ones with `ls ~/.task-force/radio/sessions/`. Workers always send `--to pm`; radio resolves it to the right `pm-<reponame>` using the injected `$TASK_FORCE_PM_ROLE` (or the sender's own identity). One PM can oversee several repos with `task-pm --also <repo>`, which aliases `pm-<other>` into its single inbox.

### Command surface

| Command | What it does |
|---------|--------------|
| `radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]` | Send a message (e.g. `--to pm --intent review-requested --pr 42`); body can come from stdin |
| `radio check`                       | List unread messages addressed to this role |
| `radio read <id>`                   | Print one message AND mark it acknowledged (moves `inbox/` → `processed/`) |
| `radio read --peek <id>`            | Print without acknowledging — for inspection / debugging |
| `radio ack <id>`                    | Mark it acknowledged (idempotent — no-op if already processed by a prior `read`) |
| `radio register` / `radio unregister [--manual]` | Add/remove this tab's session file (`~/.task-force/radio/sessions/<role>.info`). `unregister` defaults to **not** removing anything, whatever its stdin looks like: it wipes only when a piped `SessionEnd` payload names a real-exit `reason` (`logout` / `prompt_input_exit` / `other`), and logs a skip for `clear` / `resume`, an unparseable payload, an empty one, or any payload at all on a host without `jq` (where no `reason` can be read, so none can be trusted). A terminal on stdin does **not** authorize a wipe (it did until #198) — so bare `radio unregister` typed by hand is a no-op that prints `refusing to wipe <role> … re-run with --manual` on stderr and explains itself, rather than silently tearing down the session. `--manual` (alias `--force`) is the explicit opt-in for deliberate cleanup — it bypasses the stdin inspection entirely, works from any stdin shape, and is what `task-done` passes. A wipe removes the `.info` (and any `--also` aliases pointing at it); the `.loadout` / `.agent` sidecars beside it deliberately survive — see [Session state and self-heal](#session-state-and-self-heal) |
| `radio ready` / `radio busy`        | Toggle this session's `STATE` field — drives the wake-up vs. queue decision on the sender side |
| `radio stop-hook`                   | Stop-hook entrypoint: empty inbox → mark idle; unread messages → mark busy and emit Stop-hook block JSON so the agent continues and drains them. On the forced continuation it re-blocks only for ids that weren't in the block it caused |
| `radio prompt-hook`                 | UserPromptSubmit-hook entrypoint: mark busy; if the inbox has unread messages, print a one-line summary that Claude Code injects into the model's context |
| `radio orphans`                     | List session files whose heartbeat is >1h stale |
| `radio gc [--dry-run] [--max-age-days N]` | Prune the radio home: archive a dead role's still-unread mail to `dead-letter/<role>/`, drop that role's mailbox (no session file or a >1h-stale heartbeat, + newest entry older than N days, default 14) along with its `.loadout` / `.agent` sidecars, expire old `processed/` messages, and rotate an oversized `log`. Runs automatically (quietly) on a fresh `register`, so it usually needs no manual invocation; `--dry-run` reports without touching anything |

### How wake-up works

`radio send` reads the recipient's session file. If `STATE=idle`, it resolves the recipient's tab/pane id via `zellij action list-tabs --json` / `list-panes --json --tab` and writes `radio check\n` straight into that pane with `zellij action write-chars --pane-id` — no focus switch, so the sender's tab stays put. A persisted `TAB_ID` is only meaningful within one zellij server lifetime, so before driving a wake by id, `send` **verifies the tab still at that id still bears the recipient's own tab name** (one `list-tabs` call, emoji prefix stripped from both sides). A `.info` that outlived a zellij restart carries a `TAB_ID` that now addresses an unrelated tab — the name won't match, so `send` re-resolves by tab name and repairs the file on a hit, or queues on a miss, never blindly writing into whatever tab inherited the id. `ZELLIJ_SESSION=` (the server name at register time) is a diagnostic and drives one extra guard: if it names a *different but still-live* server (`zellij list-sessions`), the real owner is unreachable from here, so `send` queues rather than misdeliver into this server's same-named look-alike tab. If `STATE=busy`, the message is queued with no wake attempt — no interrupting the recipient mid-turn. Delivery then happens at the end of the recipient's current turn: its `Stop` hook (`radio stop-hook`) sees the non-empty inbox and emits Stop-hook block JSON, which makes Claude Code continue the agent so it drains the queue immediately (`radio check`, then `radio read` each message). A `stop_hook_active` payload — this `Stop` was itself caused by the previous block — only re-blocks when the inbox has grown since: the hook records the ids each block was about in `BLOCKED_IDS=` and compares the unread set against them, so a message that lands mid-drain earns its own continuation while the same ids ignored twice still stop (#197).

**The wake-up's last byte decides whether the agent acts on it.** `write-chars` types into the recipient's TUI input buffer, so terminating with LF leaves `radio check` sitting in the prompt box until a human presses Enter, while CR is the Enter. The recipient picks: a session file carrying `AUTO_SUBMIT=1` gets CR, everything else gets LF. `task-work --auto`, `task-reviewer`, and `task-pm` (on by default since #189 — a PM tab sits idle between handoffs, and it's the most-addressed role in the system, so an unsubmitted wake there was the most-felt delivery defect) export `TASK_FORCE_AUTO_SUBMIT=1` for their `radio register` to persist. Default workers keep LF, and `task-pm --no-auto-submit` opts back into it — the human gate is what stops an incoming wake from submitting a half-typed prompt. The choice is read off the *recipient's* session file, after the `--also` alias hop, so aliases inherit their primary PM's setting.

**`radio send` tells you which of those happened, on stdout** (always exit 0 — queuing is legitimate; only usage errors exit 2). The sending agent reads the line and acts on it instead of assuming delivery:

| Outcome line | Meaning |
|--------------|---------|
| `delivered — woke <role> (tab_id=N)` | The recipient was idle and reachable; `radio check` was written to its pane. |
| `queued — <role> is busy; it will drain on its next Stop` | Recipient mid-turn; the stop-hook flush picks it up. (`awaiting` recipients get their own line — drain is via prompt-hook on the next prompt.) |
| `queued — <role> is idle but wake failed (<reason>); …surface on its next prompt/register` | Idle but unreachable (no zellij / no tab / not zellij-registered / stale or unreachable tab / no pane / write failed); no auto-redelivery until the recipient is next prompted or re-registers. |
| `queued — <role> …; it polls its own inbox — the message surfaces when it next runs radio check` | The recipient is a **kiro** agent. It has no Stop drain and no prompt-hook inbox summary (see [kiro delivery](#kiro-delivery-pull-first-with-one-backstop)), so every queued outcome — busy, awaiting, wake-failed — ends in this clause instead of naming a hook it doesn't have. |
| `WARNING — no session for <role>; …nobody is listening` | No session file — the role isn't running. Also `WARNING — <role> looks dead …` when a non-idle session's heartbeat is >1h stale (see `radio orphans`). |

Because `radio send` now writes to stdout, anything **capturing** its output must discard it (`radio send … >/dev/null`).

### The hooks that make it work

`task-init claude-*` writes these into your project's `.claude/settings.json` automatically:

| Hook              | Command                       | Why                                            |
|-------------------|-------------------------------|------------------------------------------------|
| `SessionStart`    | `radio register`              | Claims the role's session file — and on a *fresh* start injects a summary of any inbox that queued while the role was offline (its stdout is injected into context, like `UserPromptSubmit`; claude loadouts only). A fresh `pm-<repo>` register also adopts any orphaned literal-`pm` backlog (write-only post-#165) into its own inbox, provenance-stamped, and surfaces it in that summary — only the messages whose `from:` names **this** repo, so another repo's backlog is left for its own PM (#210) |
| `UserPromptSubmit`| `radio prompt-hook`           | Marks the session busy — and surfaces any unread inbox into the model's context (its stdout is injected, unlike Stop's) |
| `Stop`            | `radio stop-hook`             | Marks idle — or blocks the stop so the agent drains queued messages first |
| `PostToolUse`     | `radio busy`                  | State flip only — deliberately NOT `prompt-hook`; it fires after every tool call, and the inbox summary belongs at prompt time, not sprayed mid-turn |

For the kiro loadouts the equivalent wiring is merged into the `hooks` field of each `.kiro/agents/*.json` and runs off kiro-cli's triggers — but it is **not** equivalent in effect. See below.

### kiro delivery: pull-first, with one backstop

Until #218 this section described something stricter, and for the wrong reason. The
three kiro hooks were written to `<repo>/.kiro/hooks/*.json` — the **Kiro IDE**'s
agent-hooks directory, not a path `kiro-cli` reads — so *none of them had ever run*.
No kiro role registered, no state ever flipped, and every `radio send` to one
degraded to `no session … message queued`. What looked like a weak delivery
guarantee was no wiring at all.

They now live in the `hooks` field of each `.kiro/agents/*.json`, which is where
kiro-cli actually looks:

| kiro hook | Command | What happens |
|-----------|---------|--------------|
| `agentSpawn` | `radio register …` | Claims the session file — and its #168 offline-backlog summary **does** reach the model: kiro injects hook stdout. |
| `userPromptSubmit` | `radio busy` | State flip only. Not `prompt-hook` — that is a deliberate hold, not a limitation (#221). |
| `stop` | `radio ready` | State flip back to idle, once per turn. No block-and-drain: whether kiro honours Stop-hook block JSON is a separate contract from stdout injection and is untested (#221). |
| — | *(no session-end trigger)* | Unchanged: nothing unregisters on tab close except `task-done`. `radio orphans` is the cleanup (#98). |

**kiro does inject hook stdout into the model's context.** This README asserted the
opposite for months, citing an issue that was about something else entirely. The
claim came from never observing injection — which had the same single cause as
everything above. Verified on kiro-cli 2.24.0 with a nonce control: a
`userPromptSubmit` hook echoed a random value never present in the prompt, and the
model reproduced it exactly.

So kiro has **one** of claude's three context-injecting backstops today — the
register report — and the other two are open questions rather than dead ends:

- **Kiro agents still pull.** Every prompt in `kiro-*/agents/*.json` carries a
  standing instruction to run `radio check` at the top of each turn. With no
  prompt-hook summary and no Stop drain, that poll is still what closes the gap for
  an idle role, and it is still the honest primary mechanism.
- **The zellij wake works.** It always did — the logs show `send: woke … via tab_id=N`
  for kiro roles on the rare occasions a session file existed. Registration, not the
  wake, was the defect.
- **Dispatch kiro workers with `--auto` so the push path can finish.** `task-work --auto`
  opts the worker into the CR (auto-submit) wake-up, so a wake that lands is acted on
  instead of sitting in the prompt box for a human Enter (#206). It does **not** touch
  kiro's permission model — that is still `-a/--trust-all`.

Re-deriving what kiro can now support — prompt-hook, the Stop drain, and whether
#190's "declare kiro best-effort" decision still holds — is tracked in **#221**.
A heartbeat-driven unregister for the missing session-end trigger is #127.

> **Upgrading:** this wiring is installer-written. An existing kiro project must
> re-run `task-init kiro-<tracker>` to get it; nothing self-applies. The re-run also
> removes the inert `.kiro/hooks/radio-*.json` files, leaving any hook of your own
> in that directory alone.

### Idle workers don't auto-act

A queued message arriving at an idle worker won't kick it into motion on its own — the worker only sees the message on its **next turn** (a human keystroke or its own next prompt). When that turn comes, the `UserPromptSubmit` hook (`radio prompt-hook`) injects a summary of the pending inbox into the model's context, so the backlog surfaces even if every send-time wake attempt failed. This is deliberate for workers: radio is **notification + queue**, not auto-action. If you want fully autonomous handoffs, dispatch the worker with `task-work --auto` and bake all the instructions into the issue body — that also opts the worker into the CR (auto-submit) wake-up, so a live ping drains without a keystroke. A PM launched with `task-pm` has that opt-in on by default (#189).

On kiro the `userPromptSubmit` hook is a plain `radio busy` with no inbox summary, so the worker's *own* `radio check` at the top of its next turn is what surfaces the backlog — same "next turn" latency, one less safety net. Its `agentSpawn` register report *does* land (kiro injects hook stdout), so a backlog that accumulated while the role was offline surfaces on the next fresh start. `task-work --auto` works there too (#206), buying the auto-submit.

### Session state and self-heal

`~/.task-force/radio/sessions/<role>.info` is a **soft cache, not a lock**. Hooks wipe it more often than anyone intends — that is the whole reason `busy` / `ready` re-seed a missing one instead of failing — so the durable identity lives in two ~10-byte sidecars next to it:

| File | Holds | Why it can't live in `.info` |
|------|-------|------------------------------|
| `<role>.loadout` | `claude-gh`, `kiro-local`, … | A re-seed rebuilds the `.info` it is replacing, so it can't read the old `LOADOUT=` line — and `$TASK_FORCE_LOADOUT` isn't in a hook subshell's environment |
| `<role>.agent`   | `claude` / `kiro`            | Same story for `$TASK_FORCE_AGENT`: without the sidecar every re-seed writes `AGENT=claude`, silently mislabelling kiro workers |

**The sidecars survive `unregister`** — hook-invoked or `--manual`. They exist precisely to outlive the session file, and deleting them alongside it defeated the point: 78 of 79 observed re-seeds wrote `LOADOUT=unknown` because the sidecar was already gone by the time they ran (#188). A genuine `register` overwrites them, and `radio gc` reclaims them once the role has no session file at all, so nothing accumulates.

The Stop hook's `BLOCKED_IDS=` field is the mirror image, and lives in the `.info` **because** that file is disposable. It records the message ids a Stop-hook block was about so the next `Stop` can tell a new arrival from the same unread message (#197) — state whose only correct lifetime is this session's. A sidecar would outlive `unregister` like the two above and could suppress a legitimate block for a later, unrelated session of the same role; wiped with the `.info`, it degrades to "no recorded set", which simply falls back to the old flag-only behavior.

`TAB_ID` gets the same treatment from the other direction. A re-seed resolves it by asking zellij for the tab id behind `$ZELLIJ_TAB`; when that lookup misses (no zellij, no `jq`, a repainted tab), it falls back to the `TAB_ID=` line `task-work` / `task-reviewer` wrote into their own `<worktree-base>/.<slug>.info` at tab creation — a file radio never writes, so it stays authoritative however many times the session file is wiped. This matters because an empty `TAB_ID` is not a small degradation: `radio send` reports the recipient as "not zellij-registered" and queues **with no wake attempt**, for the rest of that role's life. A re-seed now writes an empty `TAB_ID` only when there is genuinely no binding anywhere (non-zellij / CI paths), and logs that case on its own line:

```
ensure_session: re-seeded worker-foo … tab_id=41 tab_id_src=info-file loadout=claude-gh agent=claude
ensure_session: no tab binding for worker-foo (zellij lookup miss, no TAB_ID in $INFO_FILE) — TAB_ID left empty; sends to it will queue with no wake
```

### Cleanup

If a tab dies unexpectedly (or Claude resumes without re-firing `SessionStart`), the session file's `LAST_HEARTBEAT` will go stale. Run `radio orphans` to list any session older than an hour. Safe to `rm ~/.task-force/radio/sessions/<role>.info` or just leave it — the next legitimate `radio register` overwrites it.

On kiro this is the *routine* cleanup step, not just the crash path: `agentStop` fires per turn, not on session close, so there is no kiro analogue of claude's `SessionEnd` → `radio unregister`. `task-done` covers the worker happy path (it unregisters before removing the worktree), but any kiro tab closed without it leaves a session file still advertising `STATE=idle` — which makes `radio send` try to wake a tab that's gone. Run `radio orphans` periodically and delete what it lists. Heartbeat-driven auto-unregister is #127.

### When radio misbehaves

Every radio defect found so far has been a **notification** failure, not a delivery
failure: a session file wiped out from under a live role, a wake-up that typed text
nobody submitted, a stop-hook that let an unread message sit. In none of them was the
message lost — the inbox had it the whole time; what broke was the signal that something
needed attention. So when radio looks broken, start at the **log**
(`~/.task-force/radio/log`), not at the mailbox.

#### Symptom → cause → check

| Symptom | Likely cause | What to check |
|---------|--------------|---------------|
| **"I pinged the worker and nothing happened."** | The send never had a live, wakeable recipient — no session file, a stale one, or an empty/unresolvable `TAB_ID`. | 1. Re-read the sender's own outcome line (see [the outcome table](#how-wake-up-works)) — only `delivered` means a keystroke landed; every other line names its own reason. 2. `ls ~/.task-force/radio/sessions/` — is the role there at all, spelled exactly? 3. `radio orphans` — a >1h-stale heartbeat means the tab is gone. 4. `grep 'to=<role>' ~/.task-force/radio/log \| tail` and read the `send:` line right after each `send id=`. 5. In the recipient's own tab, `radio check`: if the message is listed, delivery worked and the agent simply didn't act on it. |
| **"The agent has `radio check` sitting unsubmitted in its prompt box."** | The wake was delivered but not submitted: the recipient's session file has no `AUTO_SUBMIT=1`, so the wake ended with LF instead of CR (#189). | `grep AUTO_SUBMIT ~/.task-force/radio/sessions/<role>.info` — no line means LF. Pressing Enter completes that delivery by hand. For good: relaunch the PM with plain `task-pm` (auto-submit is the default since #189; `--no-auto-submit` is the opt-out), or the worker with `task-work --auto`. The flag is read off the **recipient's** file, after any `--also` alias hop. |
| **"A role keeps disappearing from `sessions/`."** | Session flapping — something fires `SessionEnd` → `radio unregister` on intra-session events (`/clear`, `/compact`, resume, or an unexplained cascade) and the wipe takes `TAB_ID` with it. #187 / #198 made `unregister` refuse unless a wipe is explicitly authorized. | Compare the three counters below. Post-#187, `skipping` should carry the bulk of the traffic and `unregister role=` should be close to `proceeding` plus however many `--manual` calls were made. A gap has two causes, and `--manual` is the likelier: it short-circuits the block that emits *both* other lines, so it writes only `role=` — anything calling it in a loop inflates that counter alone, notably a test suite that hasn't isolated `$TASK_FORCE_HOME` and is unregistering your live role (#205). Otherwise an **old `radio` binary** is running, since every non-`--manual` call now logs one or the other; `radio` on `PATH` is a symlink into a checkout, so run `ls -l "$(command -v radio)"` and confirm that tree is current. |
| **"I ran `radio unregister` and nothing happened."** | Expected behaviour since #198, not a bug. A bare `unregister` has no `SessionEnd` payload naming a real exit, so it refuses. | It printed `refusing to wipe <role> … re-run with --manual` on stderr, and logged a `skipping` line. Pass `--manual` if you actually meant to tear the session down. |
| **"The PM merged, but the worker never cleaned up its worktree."** | The `approved-and-merged` ping arrived after that worker had exited, so it was never delivered — and the worker never heard to run `task-done`. Since #201 gc archives such mail rather than keeping a mailbox nobody will open alive forever. | `ls ~/.task-force/radio/dead-letter/<role>/` — the message is there, id and frontmatter intact. `grep 'gc: dead-lettered' ~/.task-force/radio/log` lists every message gc has archived and when. Remove the stranded worktree by hand (`task-done --remove-worktree` from inside it). See [Undelivered mail is never deleted](#undelivered-mail-is-never-deleted). |
| **"The worker says it's idling for a message that's in its own inbox."** | Fixed in #197. Pre-#197 the stop-hook gave up on the `stop_hook_active` flag alone, so a message that landed *during* a forced drain turn got no continuation of its own — terminal for an idle `--auto` worker nobody was going to prompt again. | `grep BLOCKED_IDS ~/.task-force/radio/sessions/<role>.info` — the ids the last block was about. In the log, `arrived during the drain turn` is a correct re-block; `no new message since the block` is the loop-breaker firing because the agent ignored the same ids twice. |

#### Reading the log

`~/.task-force/radio/log` is the single best diagnostic and the only place several of
these states are distinguishable at all. It is append-only, one UTC-stamped line per
event, **shared by every repo and role on the machine**, and rotated by `radio gc` once
it passes ~1MB. Read timestamps, not just counts: a log spans radio versions, so a field
missing from an old line means "written by an older binary", not "unset".

```bash
L=~/.task-force/radio/log

# Delivery rate — how many sends actually woke someone vs. queued
grep -c 'send id='   "$L"      # messages sent
grep -c 'send: woke' "$L"      # …that landed as a keystroke in a live pane

# Wake failures bucketed by reason (role names stripped)
grep -oE 'is busy|is awaiting|looks dead|no session for|has no TAB_ID|tab id unresolved|no writable pane|write-chars failed' "$L" \
  | sort | uniq -c | sort -rn

# Wipes vs. refusals (#187 / #198). `role=` counts every actual wipe and is
# the ONLY line a --manual wipe writes, so role= minus proceeding is the
# --manual traffic — deliberate (task-done) or not (#205).
grep -c 'unregister role='       "$L"
grep -c 'unregister: proceeding' "$L"
grep -c 'unregister: skipping'   "$L"

# A refusal records the stdin shape it came from (#198) — `tty` was a human typing it
grep -oE 'skipping \(empty payload on [a-z-]+ stdin' "$L" | sort | uniq -c

# Re-seed losses (#188): where a rebuilt session got its tab binding.
# `none` is the bad one — that role is unwakeable until a real `register`.
grep -oE 'tab_id_src=[a-z-]+' "$L" | sort | uniq -c
grep -c 'no tab binding for' "$L"
grep -c 'loadout=unknown'    "$L"   # sidecar was missing at re-seed time

# Stop-hook (#197): a re-block is now distinct from a give-up
grep 'arrived during the drain turn'  "$L"   # re-blocked — correct, new mail mid-drain
grep 'no new message since the block' "$L"   # gave up — same ids ignored twice
```

#### What `radio unregister` does, and doesn't

`unregister` is **not** a cleanup command you reach for by hand. It wipes only when a
piped `SessionEnd` payload names a real-exit `reason` (`logout` / `prompt_input_exit` /
`other`), and logs a `skipping` line for everything else: `clear` / `resume`, a payload
with no parseable `reason`, an empty payload, and any payload at all on a host without
`jq` (where no reason can be read, so none can be trusted). A terminal on stdin does not
authorize a wipe either — it only adds the stderr hint (#198).

`--manual` (alias `--force`) is the explicit opt-in. It bypasses the stdin inspection
entirely, works from any stdin shape, and is what `task-done` passes. A wipe removes the
`.info` and any `--also` aliases pointing at it; the `.loadout` / `.agent` sidecars
beside it deliberately survive, so the next `busy` / `ready` re-seed rebuilds a session
that still knows what it is (see [Session state and self-heal](#session-state-and-self-heal)).

#### Undelivered mail is never deleted

Nothing in radio deletes a message you haven't read. A message is written to
`~/.task-force/radio/mailbox/<role>/inbox/` **before** any wake is attempted, so every
outcome other than `delivered` means "on disk, waiting" — not "gone". `radio read <id>`
(or `radio ack <id>`) is the only thing that moves it to `processed/`.

`radio gc` respects that. It expires `processed/` messages past the cutoff, and it
**never touches a live role's `inbox/`** at any age — nor a dead role's, while that mail
is still inside the cutoff (the role may yet come back).

What it no longer does is protect a mailbox forever. Mail addressed to a role that has
**exited** is never delivered and never read, and before #201 the empty-inbox reclaim
gate made every such mailbox immortal — the sweep meant to clean them up was the one
thing keeping them alive (342 messages across 171 dead roles, on the machine that filed
the ticket). Once a role is dead (no session file, or a >1h-stale heartbeat) **and** its
mail has aged past the cutoff, gc moves that mail to
`~/.task-force/radio/dead-letter/<role>/` — original filename, id and frontmatter
untouched — and then reclaims the emptied mailbox.

**That is an archive, not a delete.** Nothing unread is ever `rm`'d, the dead-letter
directory has no TTL of its own, and the files stay readable as plain markdown. It is
where a merge ping that outlived its worker ends up, and it is usually the explanation
for a leaked worktree: the worker exited before `approved-and-merged` arrived, so it
never heard to run `task-done`. A fresh PM `register` reports what it finds, once:

```
[radio] 7 message(s) addressed to 3 role(s) that had already exited were never
delivered, and have been archived to /Users/you/.task-force/radio/dead-letter/
(worker-repo-a, worker-repo-b, worker-repo-c). Nothing was deleted — read them as
plain files, and re-send anything whose handoff still matters.
```

That report is routed, not global — `~/.task-force/radio` is shared by every repo on
the machine, so a single report would be consumed by whichever PM happened to boot
first. Each archived message is attributed to the PM that owns it: its `repo:` field if
it has one, otherwise the `pm-…` that sent it (the stranded mail is overwhelmingly
PM→worker, so this is the signal that usually fires), otherwise the dead role itself
when *that* was a PM. A message matching none of those lands in an unscoped report any
PM may claim — and since the role names are always listed, a PM reading someone else's
entry can tell. A PM also claims the reports of any `--also` aliases it answers for,
which never fresh-register on their own.

So there are two places to look, and which one holds the message tells you which
problem you have:

```bash
ls ~/.task-force/radio/mailbox/<role>/inbox/  # waiting — the role may still read it
ls ~/.task-force/radio/dead-letter/           # never delivered — the role is gone
grep -c 'gc: dead-lettered' ~/.task-force/radio/log
radio gc --dry-run   # what a sweep would archive and reclaim, without doing either
```

If the role comes back before the cutoff, its `SessionStart` register surfaces the whole
backlog in the summary it injects.

#### Delivery is not symmetric between claude and kiro

Every backstop in the list above — the Stop-hook drain, the prompt-hook injection, the
register backlog report — works by putting hook stdout into the model's context, which
kiro does not do. For a kiro recipient the zellij keystroke is the **only** push path,
and a missed wake to an *idle* role has only the agent's own `radio check` poll behind
it. Diagnose a kiro role by its `AGENT=` line
(`grep AGENT ~/.task-force/radio/sessions/<role>.info`) and read
[kiro delivery](#kiro-delivery-pull-first-with-one-backstop) before concluding anything
is broken — a queued message with no drain is the documented behaviour there, not a
failure. Note that a kiro role with **no session file at all** is a different thing and
*is* a bug post-#218: its `agentSpawn` hook should have registered it.

---

## The normal workflow

Here's what an end-to-end PR cycle looks like once everything is wired up. Eight beats, each handed off via radio:

**1. Spin up the PM.** In any zellij tab:

```bash
task-pm
```

Renames the current tab to `pm-<reponame>`, registers via the `SessionStart` hook, and starts the PM agent in-place. Radio wakes addressed to it auto-submit, so workers' reports are drained without a keypress in this tab; `task-pm --no-auto-submit` keeps the manual Enter.

**2. PM grooms the backlog and dispatches a worker.** From the PM tab:

```text
/pm show me the backlog          # or: gh issue list --state open
/pm let's do issue 42
```

PM picks one and spawns a worker:

```bash
task-work issue-42 https://github.com/<owner>/<repo>/issues/42 --auto
```

This creates a worktree, opens a new zellij tab, and launches the worker agent. `--auto` is the recommended default — it runs the worker under auto-approve since PM-filed specs should be self-contained.

**3. Planner (optional).** If the issue needs a design pass first, the PM dispatches a planner instead (`task-work … --plan`). The planner reads the code, writes the spec into the issue body, and ends with:

```bash
radio send --to pm --intent spec-ready --issue 42
```

PM's tab gets focused; on the next turn the PM picks it up and dispatches a worker for the same issue.

**4. Worker implements.** In the worker tab the agent reads the spec, edits files, runs tests, and commits with the issue title as a prefix. The `commit-msg` hook `task-work` installed checks that message for a literal CI-skip marker first — see [CI-skip markers and the `ci-guard` hook](#ci-skip-markers-and-the-ci-guard-hook).

**5. Worker opens the PR, bumps Status, pings PM.** Once the implementation is in, the worker opens the PR:

```bash
gh pr create --base main --head task/issue-42 --fill
```

Then bumps the project Status field to `In Review` (or keeps it at `In Progress` if the project has no In Review column — the worker reads the mapping from `.claude/gh-workflow.md`), and pings the PM:

```bash
radio send --to pm --intent review-requested --pr 42
```

If PM is idle, its pane is woken with a `radio check`; if PM is mid-turn, the message queues and PM's `Stop` hook (`radio stop-hook`) forces it to drain the ping at the end of that turn.

**6. Worker idles.** The worker stops here. It does **not** run `task-done` yet — cleanup waits for PM's explicit go-ahead in step 8.

**7. PM reviews. Round-trip if needed.** From the PM tab:

```bash
gh pr view 42
gh pr diff 42
gh pr review 42 --comment --body "…"   # or: gh pr comment 42 --body "…"
```

If requesting changes (worker roles are `worker-<reponame>-<slug>`; see `ls ~/.task-force/radio/sessions/`):

```bash
radio send --to worker-task-force-issue-42 --intent changes-requested --pr 42
```

The worker tab is focused, picks up the comments, pushes fixes, and pings back:

```bash
radio send --to pm --intent re-review-requested --pr 42
```

Loop until the PR is clean.

**8. PM merges and signals cleanup.** PM squash-merges, then radios the worker:

```bash
gh pr merge 42 --squash --delete-branch
radio send --to worker-task-force-issue-42 --intent approved-and-merged --pr 42
```

On its next turn the worker sees the ping, sets the project Status field to `Done`, and runs `task-done --remove-worktree` itself — removing the worktree and closing its own zellij tab. Done.

### CI-skip markers and the `ci-guard` hook

GitHub scans the **entire** head-commit message for its CI-skip markers, not
just the subject line. An agent that merely *quotes* one while describing
another commit suppresses its own workflow run — and the failure is the worst
kind of quiet:

```
$ gh run list --branch task/kiro-radio-best-effort --json headSha,conclusion
  00b91232  success     <- final head, merged
  48b88ee9  success     <- amended, marker removed
  76861921  failure     <- pre-amend head
```

`06afcf15`, the commit carrying three literal markers, **does not appear at
all.** Not queued, not skipped-with-a-record, not cancelled. It was the PR head
for nine minutes and GitHub never created a run for it. There is no artifact in
the CI record, and absence is indistinguishable from "not looked at yet" when
you're scanning a PR. Both workers this happened to reported "CI green" in good
faith, off an empty check list.

Awareness is not the fix — the second occurrence was written by an agent that
was correctly *explaining* the first, in the commit message that suppressed its
own run. So the guard is mechanical. Every `task-work` run installs a
`commit-msg` git hook that refuses the commit:

```
$ git commit -m 'describe the [skip ci] commit'

✗ ci-guard: CI-skip marker found in the commit message (.git/COMMIT_EDITMSG)
    line 1: [skip ci]

  GitHub reads the WHOLE commit message, not just the subject line, so
  this commit would get ZERO workflow runs — no failing checks, no checks
  at all. That is invisible in 'gh pr view'.

  Writing *about* a marker? Break it, e.g.  skip-ci  (or drop the brackets).
  Genuinely want to skip CI?                git commit --no-verify
  Disable this guard entirely?              TASK_FORCE_NO_CI_GUARD=1
```

Git shares one hooks directory across a repo's worktrees, so the hook covers
every commit in the repo, not only the worktree it was installed from — which
matters, because the sync commit that triggered both occurrences was made on
`main`. A pre-existing `commit-msg` hook is never clobbered: it's preserved as
`commit-msg.local` and chained from the stub. Installation is idempotent, and
the hook no-ops if `ci-guard` isn't on `PATH`, so uninstalling task-force never
locks you out of committing.

The guard is also a command in its own right:

```bash
ci-guard check [<rev|range>]   # scan committed messages (default: HEAD)
ci-guard scan <file>|-         # scan a message file or stdin
ci-guard install-hook [<dir>]  # (re)install the hook by hand
```

**The companion habit** — the worker and reviewer prompts now both carry it —
is that verifying CI means confirming a run **exists and passed** for the exact
SHA. "Did CI pass" cannot catch a suppressed run, because there is nothing to
check:

```bash
gh run list -c "$(git rev-parse HEAD)" --limit 1 --json databaseId --jq 'length'
# 0 => no run for this commit; "green" is not a claim you can make
```

An empty check list is a red flag, not a pass.

### Optional: dispatch a reviewer worker

To shift PR review off the PM's (Opus) tab and onto a cheaper Sonnet model, dispatch a one-shot reviewer worker per PR:

```bash
task-reviewer <pr-url-or-number> [<spec-identifier>]
```

`task-reviewer` spawns a fresh zellij tab + git worktree on the PR's head ref, then runs the `/reviewer` slash command (or the kiro `reviewer` agent) inside it on Sonnet (`ANTHROPIC_MODEL=claude-sonnet-4-6` by default — pre-set the env var to override). The PM's tab stays focused. Add `Bash(task-reviewer *)` to the project's `.claude/settings.json` `permissions.allow` so the PM can dispatch a reviewer without a permission prompt.

The reviewer:
1. Reads the spec (passed as the second arg — issue number / URL for `claude-gh` / `kiro-gh`; Jira key for `claude-jira`; Notion page URL for `claude-notion`; local task slug or path for `claude-local`). On `claude-gh` / `kiro-gh` only, the wrapper also auto-detects from the PR body's first `Closes #N` / `Fixes #N` / `Resolves #N` line (case-insensitive); non-gh loadouts require the spec identifier explicitly because PR bodies don't carry their tracker's linking convention.
2. Reads the PR diff + comments.
3. Cross-checks the diff against the spec, then runs the `code-review` skill on top (claude variants — kiro stays prompt-driven).
4. Posts **one** thorough PR comment with spec-compliance findings, code-review findings, and a verdict (`clean`, `clean-with-nits`, or `changes-requested`).
5. Radios PM back with `review-complete-clean` or `review-complete-with-findings`.
6. **Auto-destructs** — on the claude loadouts the reviewer's final action is `task-done --remove-worktree`, which removes the review worktree and closes its own tab. It is single-shot and self-cleaning: the analysis is durable in the PR comment, so nothing is lost when the tab goes. The kiro `reviewer` agents still idle with the tab open — clean those up by hand.

PM still decides whether to merge or request changes — the reviewer never approves, merges, closes, or mutates Status. Re-read a review with `gh pr view <N> --comments` rather than hunting for a tab that cleaned itself up. The one case a claude reviewer keeps its tab is a failed radio delivery: the verdict never reached PM, and that outcome is the one thing its PR comment does not record, so it holds open to say so.

**Tight-PR norm.** The reviewer frames every finding as fix-in-this-PR rather than "defer to a follow-up", and the PM forwards all in-scope findings — blockers *and* nits — in a single `changes-requested` round. Only work genuinely out of the PR's scope gets deferred, and the PM grooms that into a ticket during the session instead of leaving it as a loose "later."

```bash
task-reviewer 42                                              # claude-gh / kiro-gh: PR by number, auto-detect issue
task-reviewer https://github.com/owner/repo/pull/42           # PR by URL
task-reviewer 42 38                                           # claude-gh / kiro-gh: PR + GitHub issue explicit
task-reviewer 42 PROJ-123                                     # claude-jira: PR + Jira key explicit (no auto-detect)
task-reviewer 42 https://notion.so/page-id                    # claude-notion: PR + Notion page URL explicit
task-reviewer 42 042-add-login                                # claude-local: PR + local task slug explicit
task-reviewer 42 --no-auto                                    # opt out of auto-permission (interactive review)
```

`--auto` is the default — the reviewer's authority list rules out merge / push / approve / close / Status, so auto-permission is safe for the review flow, and matches the "dispatch and walk away" intent of the command. Pass `--no-auto` to drop into the interactive permission-prompt mode. Kiro reviewers default to `--trust-all-tools` for the same reason; opt out with `--no-trust-all`.

---

## `task-work` flags

Common to every combo:

- `-b, --base BRANCH` — branch the PR will target (default: branch you're on when `task-work` runs)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: current HEAD). Accepts any ref `git` accepts (branches, tags, SHAs, `origin/foo`). Use this to stack a PR on an in-flight branch (`--from task/issue-46 --base main`) or to spike off `origin/main` without checking it out first.
- `--no-launch` — create the worktree and open the tab at that directory, but don't auto-start the agent (you pick the model/command yourself)
- `--impl <name>` — force a specific combo, bypassing auto-detection

`claude-*` combos also accept `-p/--plan` and `--auto` (agent permission mode — and, on both, the radio auto-submit opt-in below).

`kiro-*` combos also accept `-m/--model MODEL`, `-a/--trust-all`, and `--auto`. On kiro, `--auto` governs **radio auto-submit only** — the permission model is `-a/--trust-all` and stays separate (#206). Before #206 kiro had no `--auto` case at all, so the flag aborted the launch and a kiro worker could never be woken without a keypress.

---

## Testing

Tests live in `tests/` and use [bats-core](https://github.com/bats-core/bats-core).

```bash
git submodule update --init --recursive   # first time only
./run_tests.sh                            # run everything
./run_tests.sh task_done                  # run a single suite
```

**Radio-home isolation.** The suite drives destructive radio commands —
`task-done` calls `radio unregister --manual`, which wipes a session file
unconditionally. `tests/setup_suite.bash` therefore points every run at a
throwaway `$TASK_FORCE_HOME`, so no test can reach the `~/.task-force` of
whoever ran it (#203; before the fix a full run wiped the runner's own live
session 57 times, which made an agent worker unaddressable mid-run). You get
that for free from `./run_tests.sh` *and* from a bare `bats tests/foo.bats`.
If `$TASK_FORCE_HOME` is missing or aimed back at the real home, loading
`tests/helpers/common.bash` aborts the run with an explanation rather than
writing to the live mailbox.

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
| `task_board_dispatcher.bats`      | Root `bin/task-board` — local-loadout dispatch, `--repo`-driven detection, refusal on gh/jira/notion |
| `task_done.bats`                  | `task-done` across combos — cleanup, PR, guards |
| `radio_home_isolation.bats`       | The suite's own radio-home isolation — nothing lands under `$HOME/.task-force` |

</details>

Infrastructure:

- `tests/helpers/common.bash` — `setup_repo`, `setup_stubs`, `setup_worktree`, `teardown_all`, `assert_stub_called`
- `tests/setup_suite.bash` — runs once per bats invocation; exports the run-scoped `$TASK_FORCE_HOME`
- `tests/helpers/radio_home.bash` — `task_force_home_is_isolated`, `require_isolated_task_force_home`
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

# Anything that shells out to radio or task-done also wants a per-test mailbox:
#   setup() { setup_repo; setup_stubs; setup_task_force_home; cd "$MAIN_REPO"; }

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
