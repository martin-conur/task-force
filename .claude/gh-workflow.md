## GitHub Projects Workflow (Claude Code)

Copy this file to your project's `.claude/gh-workflow.md` and fill in your details.
Or run `task-init claude-gh` in your project root to do this automatically.

Then reference it from `CLAUDE.md` at your project root so every Claude Code session auto-loads it:

```
@.claude/gh-workflow.md
```

### GitHub CLI (`gh`)

This workflow uses the [`gh` CLI](https://cli.github.com) for issue / project / PR I/O. Verify you're authenticated:

```bash
gh auth status
```

If not, run `gh auth login` (needs `repo` + `project` scopes). The PM / planner / worker prompts shell out to `gh` directly; read-only patterns (`gh issue view *`, `gh project view *`, `gh search issues *`, etc.) are pre-allowed in `.claude/settings.json` by `task-init claude-gh`, so reads don't trigger permission prompts. Mutations (`gh issue edit`, `gh pr merge`, …) stay confirmation-gated.

#### Optional: GitHub MCP for richer Projects v2 mutations

`gh project item-edit` covers the common single-select / number / text mutations. If you frequently mutate iteration fields or want a higher-level Projects v2 API, add the GitHub MCP as an opt-in:

```bash
claude mcp add --transport stdio github -- npx -y @github/github-mcp-server
```

(Requires `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment.)

### GitHub Repository

- **Owner**: `martin-conur` (GitHub user or org name)
- **Repo**: `task-force` (repository name)
- **Project number**: `1` (from the project URL: github.com/users/martin-conur/projects/N or github.com/orgs/martin-conur/projects/N)

### Task Lifecycle

Todo → In Progress → In Review → Done

- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review` (leave blank or omit if your project has no In Review column — the worker will keep the issue at `In Progress` through review)
- **Status when done**: `Done`

The worker reads these three values and updates the project item's Status field as it moves through the lifecycle: to "starting work" before implementing, to "in review" after opening the PR, and to "done" only after the PM signals `approved-and-merged` via radio.

### Task Properties

- **Title** (issue title), **Status** (project single-select field), **Priority** (project field)
- **Git commit** (URL — set to PR link after done)

### Commit Convention

Use the issue title as prefix: `<Issue title>: <short description>`

### Shell Commands

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker session

- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `-p, --plan` — launch the worker in Claude plan mode (runs `/planner`); mutually exclusive with `--auto`
- `--auto` — launch the worker in Claude auto permission mode (runs `/worker`); mutually exclusive with `--plan`
- `--no-launch` — open the worktree tab but do NOT start Claude

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/martin-conur/task-force/issues/42"
task-work https://github.com/martin-conur/task-force/issues/42
task-work refactor-auth --plan
task-work issue-99 --from task/issue-46 --base main --auto   # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker prompts shell out to
`radio send` at every documented handoff point:

| From     | When                              | Command                                                                          |
|----------|-----------------------------------|----------------------------------------------------------------------------------|
| Planner  | spec written into the issue       | `radio send --to pm --intent spec-ready --issue <N>`                             |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                          |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`                       |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`              |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`            |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`                     |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`             |

When a worker's turn ends, the `Stop` hook runs `radio stop-hook`
automatically: with an empty inbox it marks the role idle; if messages queued
up while the worker was busy, it blocks the stop (staying busy) so the agent
drains them immediately — you don't need to invoke it manually.

Likewise, every submitted prompt runs `radio prompt-hook` (the
`UserPromptSubmit` hook): if the inbox has unread messages, a line like
`[radio] 2 unread message(s): <id> from=pm intent=changes-requested pr=41 | …`
is injected into the agent's context alongside the prompt. That line is the
canonical radio channel, not user-typed text — trust it and process the
listed messages with `radio check` / `radio read <id>`.

Finally, `SessionStart` fires `radio register`; on a *fresh* start (not the
re-registers that `/compact`, `/clear`, and resume trigger) it also prints a
summary of any inbox that queued while the role was offline — reports whose
send-time wake found no session file and no-op'd. `SessionStart` stdout is
injected into the model's context, so that backlog surfaces on the role's very
first turn, not just after the next human prompt: the offline→online companion
to the stop-hook flush (busy case) and prompt-hook injection (idle case). Empty
inbox prints nothing. (claude loadouts only — Kiro's hook stdout isn't
injected; see #146.)

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping. Worker role names
follow `worker-<reponame>-<slug>`; discover the live one via
`ls ~/.task-force/radio/sessions/`.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `SessionStart` hook, and
starts the PM agent in-place.

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> [<issue-url-or-number>]` from any spare tab.
It spawns a fresh zellij tab + worktree on the PR's head ref, runs the
`/reviewer` agent on Sonnet (cheaper than the PM's Opus default), cross-checks
the PR against the spec issue (passed as the second arg, or auto-detected from
the PR body's first `Closes #N` / `Fixes #N` / `Resolves #N` line, case-insensitive), runs the `code-review` skill on
the diff, posts a single thorough PR comment via `gh pr comment`, and radios
PM back with `review-complete-clean` or `review-complete-with-findings`. PM
still owns the merge decision — the reviewer never approves, merges, or
mutates status. The reviewer tab stays open showing the analysis; clean up
with `task-done --remove-worktree` when done.

If a worker tab dies unexpectedly (or Claude resumes a session without
re-firing `SessionStart`), the session file's `LAST_HEARTBEAT` will go stale.
Run `radio orphans` to list any session whose heartbeat is older than 1 hour —
those entries are safe to delete (`rm ~/.task-force/radio/sessions/<role>.info`)
or leave for the next legitimate `radio register` to overwrite.
