## Notion Workflow

Copy this file to your project's `.kiro/steering/notion-workflow.md` and fill in your Notion database IDs.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

### Notion Database IDs

<!-- Replace each placeholder with the real ID, or pass them to task-init:
       task-init kiro-notion --tasks <id> --projects <id> --board <id>
     Run `task-init kiro-notion --help-ids` for step-by-step discovery instructions.

     What each ID looks like:
       collection://...  — opaque string from the Notion MCP (data-source URL)
       board page ID     — UUID like 8a1b2c3d-e4f5-6789-abcd-ef0123456789

     How to find them (requires Notion MCP active in Kiro):
       1. Run: kiro
       2. Ask: "Help me find my Notion database IDs"
       3. Kiro will list your boards and extract the IDs from the MCP response
-->

- **Tasks**: `collection://<YOUR_TASKS_DATA_SOURCE_ID>`
- **Projects**: `collection://<YOUR_PROJECTS_DATA_SOURCE_ID>`
- **Board page**: `<YOUR_BOARD_PAGE_ID>`

### Task Lifecycle
Not Started → In Progress → In Review → Done (or Archived)

- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review` (leave blank or omit if your Notion database has no In Review option — the worker will keep the task at `In Progress` through review)
- **Status when done**: `Done`

The worker reads these three values and updates the task's Status property as it moves through the lifecycle: to "starting work" before implementing, to "in review" after opening the PR, and to "done" only after the PM signals `approved-and-merged` via radio.

### Task Properties
Customize these to match your Notion database schema:
- **Task name** (title), **Status**, **Priority**
- **Project** (relation), **Tags** (multi-select)
- **Git commit** (URL — set to PR or commit link after done)

### Commit Convention
Use the task name as prefix: `<Task name>: <description>`

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes <Notion page URL>` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work <slug> [notion-url]` — worktree + tab + worker; see `--help`
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
| Planner  | spec written into the task page   | `radio send --to pm --intent spec-ready --issue <task-slug>`             |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                  |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`               |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`      |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`    |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`             |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`     |

`--to pm` reaches this repo's PM, `pm-<reponame>`. Worker role names follow
`worker-<reponame>-<slug>`, and reviewers `reviewer-<reponame>-pr<N>`; discover
the live ones via `ls ~/.task-force/radio/sessions/`.

**Delivery here is pull-first — kiro agents mostly fetch rather than receive.**
Every agent in `.kiro/agents/` runs `radio check` at the start of each turn and
`radio read <id>` whatever it lists. `agentSpawn` registers the role, and its
offline-backlog summary reaches the model; but `userPromptSubmit` adds no inbox
summary and `stop` is a bare `radio ready` with no block-and-drain, so mail that
queues mid-session waits for the recipient's next turn. If a handoff seems not
to have arrived, prompt that tab. There is also no session-end trigger, so a tab
closed without `task-done` leaves its session behind; `radio orphans` lists
those, and the `radio-troubleshooting` skill says what to do with them.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping.

**Agent-authored prose goes in on stdin, never through a double-quoted shell
string** (#234). Inside `"…"` the shell command-substitutes every backticked
token, so a review quoting `pwd -P` posts that command's *output*, and a
backticked identifier naming no command — `$WORKTREE_DIR`, `_helper()` — posts
as **nothing at all**, deleting the finding's subject with no sign a word is
gone. Reviews, specs and commit bodies here are backtick-dense, so the rule is
absolute: feed `gh` its body with `--body-file -`, `radio send` its body on
stdin, and `git commit` its message with `-F -`, all from a **quote-delimited**
heredoc (`<<'BODY'` … `BODY`, never `<<BODY`).
Single-quoting `-b '…'` is not a fix — prose contains apostrophes, and the
first one ends the string. It also means every backticked token in a review is
*executed* in the reviewer's worktree, and review prose routinely quotes `rm`,
`git reset` and `gh pr merge` while discussing a diff. The reviewer's PR comment
is the failure that named this: its tab self-destructs by design, so a mangled
comment is an unrecoverable loss of the analysis.

The PM's side of radio — reviewer dispatch, `task-pm --also`, auto-submit — is
in the PM prompt, and the reviewer's contract in the reviewer prompt. How radio
keeps, recovers and cleans up sessions (resumed sessions, sidecars, `gc`,
`$TASK_FORCE_HOME`) is in the `radio-troubleshooting` skill.

### Radio troubleshooting

Read `radio send`'s stdout every time. `delivered`, or `queued — <role> is
busy` / `is awaiting`, means the message landed or drains on its own. Anything
else — `WARNING — no session for …`, `queued — … wake failed`, `WARNING — …
looks dead`, `task-done`'s `no tab id captured`, a hook that `timed out after
30s` — means load the `radio-troubleshooting` skill before you act on it:
`.kiro/skills/radio-troubleshooting/SKILL.md`, installed by `task-init`. Read
the file directly if your kiro-cli does not list it as a skill.
