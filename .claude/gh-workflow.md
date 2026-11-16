<!-- task-init:managed:start -->
<!-- Managed by `task-init`: everything between these markers is replaced on
     every re-run. Put repo-specific notes below the end marker. -->

## GitHub Projects Workflow (Claude Code)

Copy this file to your project's `.claude/gh-workflow.md` and fill in your details.
Or run `task-init claude-gh` in your project root to do this automatically.

When `task-init` writes this file it wraps the template in
`<!-- task-init:managed:start -->` / `<!-- task-init:managed:end -->` markers. Re-running
`task-init` replaces only what is between them, so anything you add **below the end
marker** — repo-specific conventions, what "Green" means in this repo — survives every
upgrade.

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

### PR Body

The worker opens every PR body with `## Summary`: two or three plain sentences, written for you rather than for a reviewer, saying what changed and why. `Closes #N` and the rest of the description follow it. The reviewer flags a PR without one as a nit. The summary is what to read when a ticket number no longer tells you what the work was.

### Shell Commands

One line per command. Each command's `--help` is its reference, and
`docs/shell-commands.md` in the task-force repo keeps the background and history.

- `task-work <slug> [gh-url]` — worktree + tab + worker; see `--help`
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

| From     | When                              | Command                                                                          |
|----------|-----------------------------------|----------------------------------------------------------------------------------|
| Planner  | spec written into the issue       | `radio send --to pm --intent spec-ready --issue <N>`                             |
| Worker   | PR opened                         | `radio send --to pm --intent review-requested --pr <N>`                          |
| Worker   | new commits pushed after review   | `radio send --to pm --intent re-review-requested --pr <N>`                       |
| PM       | review requested changes          | `radio send --to <worker-role> --intent changes-requested --pr <N>`              |
| PM       | PR merged                         | `radio send --to <worker-role> --intent approved-and-merged --pr <N>`            |
| Reviewer | review done, no findings          | `radio send --to pm --intent review-complete-clean --pr <N>`                     |
| Reviewer | review done, blockers/nits posted | `radio send --to pm --intent review-complete-with-findings --pr <N>`             |
| Watcher  | Jira bug claimed (claude-jira)    | `radio send --to pm --intent ticket-filed --issue <KEY-N>`                       |
| Watcher  | `acli` failed; watcher stopped    | `radio send --to pm --intent watch-stopped`                                      |
| Watcher  | PM rotation due (claude-jira)     | `radio send --to pm --intent handoff-requested`                                  |
| PM       | handoff note written              | `radio send --to watch-<reponame> --intent handoff-done`                         |

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

<!-- task-init:managed:end -->

## Repo-specific notes

<!-- Everything below the end marker above is yours — `task-init` never
     rewrites it. Repo-specific guidance belongs here: what "Green" means in
     this repo, the pre-PR checklist it resolves to, local conventions. -->

### Pre-PR checklist (this repo)

The `/worker` pre-PR checklist is deliberately repo-generic (it ships downstream
verbatim via `task-init`). In **this** repo it resolves to:

- **Changelog** — add an entry under `## [Unreleased]` in `CHANGELOG.md`
  ([Keep a Changelog](https://keepachangelog.com) format). Include the
  **"Upgrading: re-run `task-init <loadout>`"** note whenever installer-written
  artifacts change (radio hooks, the copied `commands/*.md`, `settings.json`);
  say so explicitly when no re-run is needed.
- **Docs** — a model-facing or user-visible change also updates the README
  section, the four `steering/*.example.md` templates, and the loadout workflow
  docs (`.claude/*-workflow.md`). See PRs #172–#175 for the findings this
  checklist encodes; #163 / #164 / #168 for the doc-beat precedent.
- **Reuse / drift** — logic shared across loadouts lives behind `# region:`
  sentinels guarded by `tools/check-drift.sh`; extract rather than copy a second
  time, and add a sentinel + manifest entry when you do.
- **CI markers** — the `commit-msg` guard `task-work` installs refuses a literal
  CI-skip marker in a commit message, and this repo is the one most likely to
  need one: half the open radio tickets are *about* the commit that carried one.
  Write it broken (`skip-ci`). If you hit the refusal, reword — don't reach for
  `--no-verify`.
- **Green** — run `./run_tests.sh`, `tools/check-drift.sh`, and `shellcheck -x`
  on changed shell files. After pushing, confirm CI **ran and passed**: an
  empty `gh pr checks` list is not a pass, it's the signature of a suppressed
  run. Prove one exists for the exact SHA —
  `gh run list -c "$(git rev-parse HEAD)" --limit 1 --json databaseId --jq 'length'`
  must be non-zero. See #194 for the two occurrences that made this a gate.
