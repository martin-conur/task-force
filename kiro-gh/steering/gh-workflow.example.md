## GitHub Projects Workflow (Kiro)

Copy this file to your project's `.kiro/steering/gh-workflow.md` and fill in your details.
Or run `task-init kiro-gh` in your project root to do this automatically.

### GitHub CLI (`gh`)

This workflow uses the [`gh` CLI](https://cli.github.com) for issue / project / PR I/O. Verify you're authenticated:

```bash
gh auth status
```

If not, run `gh auth login` (needs `repo` + `project` scopes). The bundled PM / planner / worker agents shell out to `gh` directly via `execute_bash`. Mutations stay confirmation-gated; with `--trust-all` on `task-work`, every `gh` call is auto-approved.

#### Optional: GitHub MCP for richer Projects v2 mutations

`gh project item-edit` covers the common single-select / number / text mutations. If you frequently mutate iteration fields or want a higher-level Projects v2 API, add the GitHub MCP to each agent's `mcpServers` block (the bundled agents ship without it; add it back if you want it):

```json
"mcpServers": {
  "github": { "command": "npx", "args": ["-y", "@github/github-mcp-server"] }
}
```

Only when the MCP add-on is enabled: set `GITHUB_PERSONAL_ACCESS_TOKEN` in your environment before running Kiro, and add `@github` to each agent's `tools` (and `allowedTools` to skip the confirmation). Without the add-on, no PAT is needed — `gh auth` covers it.

### GitHub Repository

- **Owner**: `{OWNER}` (GitHub user or org name)
- **Repo**: `{REPO}` (repository name)
- **Project number**: `{PROJECT}` (from the project URL: github.com/users/{OWNER}/projects/N or github.com/orgs/{OWNER}/projects/N)

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

`task-work <slug> [gh-url] [options]` — create worktree + zellij tab + worker agent

- `-m, --model MODEL` — pick a specific kiro model
- `-a, --trust-all` — pass `--trust-all-tools` so the worker runs without per-tool confirmation
- `-b, --base BRANCH` — branch the PR will target (default: current branch at call time)
- `-f, --from REF` — git ref to fork the new worktree's branch from (default: `HEAD`)
- `--no-launch` — open the worktree tab but do NOT start kiro

If local `<base>` is strictly behind `origin/<base>`, `task-work` auto-refreshes and forks the new worktree from `origin/<base>` instead of the stale local tip. Pass `--from` to override.

Examples:
```bash
task-work add-auth "https://github.com/{OWNER}/{REPO}/issues/42"
task-work https://github.com/{OWNER}/{REPO}/issues/42
task-work refactor-auth -m claude-opus-4.6 --trust-all
task-work issue-99 --from task/issue-46 --base main         # stack on an in-flight branch
task-work spike-idea --no-launch
```

`task-done [options]` — from within a worktree: show diff, print/detect PR, cleanup

- `--force` — skip all confirmation prompts
- `--remove-worktree` — cleanup only (use after worker has already created the PR)
### PM ↔ worker messaging (radio)

Radio is the **canonical** coordination channel between the PM and workers — every
role transition runs through it. The PM / planner / worker agents shell out to
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

When a worker finishes its task and has nothing pending, the `radio ready` step
runs automatically via the `agentStop` hook — you don't need to invoke it
manually.

Full command form:

```bash
radio send --to <role> --intent <kind> [--pr N] [--issue N] [--body TEXT]
```

The body comes from `--body` or stdin. PR review *content* still lives in
`gh pr comment`s — `radio` only carries the routing ping. Worker role names
follow `worker-<reponame>-<slug>`; discover the live one via
`ls ~/.task-force/radio/sessions/`.

To launch the PM agent in this repo, run `task-pm` from any tab — it renames
the current zellij tab to `pm`, registers via the `agentSpawn` hook, and
starts the PM agent in-place.

To dispatch a one-shot reviewer worker for a PR, run
`task-reviewer <pr-url-or-number> [<issue-url-or-number>]` from any spare tab.
It spawns a fresh zellij tab + worktree on the PR's head ref, runs the kiro
`reviewer` agent, cross-checks the PR against the spec issue (passed as the
second arg, or auto-detected from the PR body's first `Closes #N` /
`Fixes #N` / `Resolves #N` line, case-insensitive), reviews the diff, posts a single thorough PR comment via
`gh pr comment`, and radios PM back with `review-complete-clean` or
`review-complete-with-findings`. PM still owns the merge decision — the
reviewer never approves, merges, or mutates status. The reviewer tab stays
open showing the analysis; clean up with `task-done --remove-worktree` when
done.

If a worker tab dies unexpectedly (or kiro resumes a session without
re-firing the `agentSpawn` hook), the session file's `LAST_HEARTBEAT` will go
stale. Run `radio orphans` to list any session whose heartbeat is older than
1 hour — those entries are safe to delete
(`rm ~/.task-force/radio/sessions/<role>.info`) or leave for the next
legitimate `radio register` to overwrite.
