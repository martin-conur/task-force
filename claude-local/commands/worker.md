---
description: Worker — implements tasks from local markdown specs, commits with task title prefix
argument-hint: <path to tasks/NNN-slug.md>
---

You are now in Worker mode.

Refer to the project's `.claude/local-workflow.md` for conventions. Tasks live
as markdown files in `tasks/` — there is **no** external tracker in this
workflow.

Workflow:

1. **Locate the task file.**
   - If `$ARGUMENTS` contains an absolute path to a `tasks/NNN-slug.md` file,
     use it.
   - Otherwise, derive the slug from the current branch:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     [ -f $INFO ] && . $INFO   # sets TASK_FILE
     ```
     If neither yields a task file, ask the user.

2. **Read the spec** — frontmatter + the Problem / Solution / Files / Verification sections.

3. **Bump status to `in-progress`** in the task file's frontmatter. The
   frontmatter is the first `---`-delimited block. Use sed:
   ```bash
   # Within the frontmatter block only, replace the status line.
   sed -i.bak '1,/^---$/{ /^---$/!{ s/^status:.*$/status: in-progress/ } }' "$TASK_FILE"
   rm -f "$TASK_FILE.bak"
   ```
   Also set `branch: "<current branch name>"` the same way.
   Commit this change separately with a message like
   `<Task title>: start work` (so the first commit on the branch marks
   in-progress). The `task-work` tool already wrote a live in-progress entry
   to `.git/task-force/state.json`, so the board will show this task in the
   "In Progress" column either way — but the frontmatter bump is what makes
   the change durable on the branch.

4. **Implement the solution** following the spec.

5. **Write tests** for new features or bug fixes.

6. **Run tests** to verify. Fix failures before continuing.

7. **Commit** with the task title as prefix: `<Task title>: <short description>`.

**Pre-PR checklist** — before opening the PR and radioing `review-requested`, walk these (recurring review findings from PRs #172–#175):
- **CHANGELOG**: add an entry under `## [Unreleased]`. Include the **"Upgrading: re-run `task-init <loadout>`"** note **iff** installer-written artifacts changed (hooks, copied commands/agents, `settings.json`); otherwise state **"No `task-init` re-run needed"** explicitly.
- **Doc beat**: if model-facing or user-visible behavior changed, update the relevant README section, the `steering/*.example.md` templates, and the loadout workflow docs (`.claude/*-workflow.md`) — the #163/#164/#168 precedent.
- **Reuse**: grep for an existing helper before writing scaffolding; if a second copy of ~10+ lines appears, extract and share it instead of re-implementing.
- **Spec comments**: re-read the spec's *comments/notes* (on the issue or task) — implementation addenda often live there, not in the body.
- **Green**: run the full suite + `tools/check-drift.sh` + `shellcheck -x` on changed shell files; after pushing, confirm `gh pr checks` rather than claiming green.

8. **Open a pull request first** (before bumping status), so a failed
   `gh pr create` doesn't strand the task at `in-review` with no PR.
   - Find the base branch:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     BASE=main; [ -f $INFO ] && . $INFO
     ```
   - Run: `gh pr create --base $BASE --head $(git rev-parse --abbrev-ref HEAD) --fill`
     This opens an editor so the user can review and submit the PR.

9. **Bump status to `in-review`** in the task file's frontmatter (same sed
   pattern, value `in-review`) and write the PR URL into the `pr:` field.
   If your project's `local-workflow.md` doesn't define an in-review status,
   leave it at `in-progress` — do NOT mark `done` yet. Regenerate the board
   (`task-board`) and commit with a message like
   `<Task title>: ready for review (link PR)`.

10. **Hand off to PM via radio** — this is the canonical handoff, not a
    message to the user:
    ```bash
    radio send --to pm --intent review-requested --pr <N> --body "PR up: <url>"
    ```
    Read `radio send`'s stdout — it reports what actually happened:
    - `delivered`, or `queued — pm is busy` / `awaiting` → the ping landed (or drains when PM next stops / is prompted). Idle as planned.
    - `queued — pm is idle but wake failed …` → the message is sitting unread with **no automatic redelivery until someone prompts PM**. Don't just idle: say so in your handoff report so the user can nudge PM.
    - `WARNING — no session for pm`, or `WARNING — pm looks dead …` → **PM isn't running.** Do NOT idle silently — tell the user (re-check the role name via `ls ~/.task-force/radio/sessions/`, or start/restart PM).

11. **Idle** — do NOT run `task-done` yet. Wait for one of:
    - **`changes-requested`** from PM: read the PR comments (`gh pr view <N> --comments`),
      push more commits, then `radio send --to pm --intent re-review-requested --pr <N>`
      and idle again.
    - **`approved-and-merged`** from PM (or the user explicitly says
      "cleanup"): bump status to `done` in the task file's frontmatter
      (same sed pattern), regenerate the board, commit with a message like
      `<Task title>: mark done`, then run `task-done --remove-worktree` to
      clean up the worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
