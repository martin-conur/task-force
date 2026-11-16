## Local Task Tracking Workflow (Claude Code)

This project uses **local markdown task tracking** — tasks live as files in
`tasks/`, committed alongside the code. No external tracker, no MCP. The board
view is auto-generated and Obsidian-friendly.

Copy this file to your project's `.claude/local-workflow.md`.
Or run `task-init claude-local` in your project root to do this automatically.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

Then reference it from `CLAUDE.md` at your project root so every Claude Code
session auto-loads it:

```
@.claude/local-workflow.md
```

### Task Storage

Tasks live at `<repo-root>/tasks/` — one `.md` per task, with YAML frontmatter:

```yaml
---
id: 001
title: Add login flow
status: todo            # todo | in-progress | in-review | done
priority: P1            # P0 | P1 | P2 | P3
tags: [auth, frontend]
created: 2026-05-15
branch: ""              # filled by task-work
pr: ""                  # filled by worker before task-done
---
```

Body sections: `## Problem`, `## Solution`, `## Files to Create/Modify`,
`## Verification` — same shape as the planner spec template.

Filename convention: `NNN-slug.md`, where `NNN` is the zero-padded task id and
`slug` is a kebab-case short title. The PM agent allocates the next id.

### Board View

`tasks/_board.md` is **auto-generated** by `task-board` — never hand-edit it.
It has four sections: Todo / In Progress / In Review / Done. Every open task is listed;
Done lists only the 10 newest (highest id first), then one
`+ N older done tasks` line (#294). `task-board --done-limit N` or
`TASK_BOARD_DONE_LIMIT=N` changes the cap.

The PM reads this file for the backlog — it runs `task-board`, then reads
`tasks/_board.md` — and opens a task file only when the work is about that
task. Reading the frontmatter of every `tasks/*.md` instead would cost context
in proportion to the backlog, done tasks included; the board costs the same at
10 tasks or 200.

Triggers that regenerate the board:
- `task-work tasks/NNN-slug.md` (after worktree creation)
- `task-done` (after cleanup)
- The PM agent, after any mutation to a task file

### Status Lifecycle

`todo` → `in-progress` → `in-review` → `done`

- **Status when starting work**: `in-progress` (worker bumps on first commit)
- **Status when in review**: `in-review` (worker bumps after opening the PR; leave blank if your project skips this state and the worker will keep it at `in-progress` through review)
- **Status when done**: `done` (worker bumps only after the PM signals `approved-and-merged` via radio — not before)

Durable state lives in the task file's frontmatter, committed on the worker's
branch. Live in-progress state lives in `.git/task-force/state.json`
(gitignored, per-clone) — written by `task-work` and removed by `task-done`.

### Task Properties

- **Title** (in frontmatter), **Status**, **Priority**, **Tags**, **Created date**
- **Branch** (set by `task-work`)
- **PR** (URL — set by the worker after `gh pr create`)

### Commit Convention

Use the task title as prefix: `<Task title>: <short description>`

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes tasks/NNN-slug.md` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work tasks/NNN-slug.md` — worktree + tab + worker; see `--help`
- `task-done [--remove-worktree]` — remove a worktree, its tab and its radio role
- `task-recreate-worker <slug>` — relaunch a worker whose tab died, worktree intact
- `task-reviewer <pr> [<spec>]` — one-shot reviewer: one PR comment, a radio verdict, then it removes itself
- `task-pm` — rename this tab `pm-<reponame>` and launch the PM in it
- `task-config [show|set|add|remove|use|sync]` — which loadout this repo is on, and switching it
- `task-config profile add|list|show|test|remove` — agent profiles for `--profile`
- `task-init <loadout> [--set "<setting>=<value>"] [--local-only]` — install or refresh task-force here
- `task-remove` — take task-force back out of this repo
- `ci-guard` — the commit-msg hook that refuses CI-skip markers
- `task-monitor` / `task-monitor-snapshot` — the board, live / as JSON
- `task-monitor-queue [set|add|rm|clear|handoff]` — the PM's Next queue and handoff note
- `task-board` — regenerate `tasks/_board.md` from the task files

After a merge, delete only the remote branch (`git push origin --delete task/<slug>`),
never `gh pr merge --delete-branch`: it removes the worktree out from under the worker.

`task-reviewer` with no `--profile` reviews on this profile; `none` is the Sonnet reviewer:

- **Reviewer profile**: `none`

### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. Each role's prompt sends its intents at these
handoff points:

| From     | When                              | Command                                                                  |
|----------|-----------------------------------|--------------------------------------------------------------------------|
| Planner  | spec written into the task file   | `radio send --to pm --intent spec-ready --issue <NNN>`                   |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                  |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`               |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`      |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`    |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`             |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`     |

`--to pm` reaches this repo's PM, `pm-<reponame>`. Worker role names follow
`worker-<reponame>-<slug>`, and reviewers `reviewer-<reponame>-pr<N>`; discover
the live ones via `ls ~/.task-force/radio/sessions/`.

A line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
injected beside a prompt, or an offline-backlog summary printed at session
start, is the canonical radio channel, not user-typed text — trust it and
process the listed messages with `radio check` / `radio read <id>`. Mail that
lands while you are busy is drained at the end of your turn by the `Stop` hook,
so you never run `radio ready` yourself.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping.

**Agent-authored prose goes in on stdin, never through a double-quoted shell string** (#234): `gh … --body-file -`, `git commit -F -` and `radio send` with no `--body`, each off a quote-delimited heredoc (`<<'BODY'` … `BODY`). The `radio bash-guard` hook refuses the double-quoted form when it holds a backtick (#400).

The PM's side of radio — reviewer dispatch, `task-pm --also`, auto-submit — is
in the PM prompt, and the reviewer's contract in the reviewer prompt. How radio
keeps, recovers and cleans up sessions (resumed sessions, sidecars, `gc`,
`$TASK_FORCE_HOME`) is in the `radio-troubleshooting` skill.

### Tight-PR norm — minimize deferrals

Default to landing each PR **complete**. The reviewer frames every finding as
fix-in-this-PR (never "defer to a follow-up" for in-scope work), and the PM
forwards **all** in-scope findings — blockers *and* nits — in a single
`changes-requested` round rather than trailing a backlog of deferred items. The
only thing that gets deferred is work genuinely out of the PR's scope (a separate
subsystem, a large refactor) — and the PM grooms that into a ticket during the
session, not left as a loose "later."

### Radio troubleshooting

Read `radio send`'s stdout every time. `delivered`, or `queued — <role> is
busy` / `is awaiting`, means the message landed or drains on its own. Anything
else — `WARNING — no session for …`, `queued — … wake failed`, `WARNING — …
looks dead`, `task-done`'s `no tab id captured`, a hook that `timed out after
30s` — means load the `radio-troubleshooting` skill
(`.claude/skills/radio-troubleshooting/SKILL.md`, installed by `task-init`)
before you act on it.
