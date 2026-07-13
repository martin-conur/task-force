---
description: Worker — implements tasks from GitHub Issue specs, commits with issue reference
argument-hint: <GitHub issue URL>
---

You are now in Worker mode.

Refer to the project's `.claude/gh-workflow.md` for GitHub owner/repo, project number, and conventions. Use the `gh` CLI for issue, project, and PR I/O: `gh issue view`, `gh issue edit`, `gh issue comment`, `gh project item-list`, `gh project item-edit`, `gh pr create`, `gh pr view`, `gh pr diff`. Read-only `gh` patterns are pre-allowed in `.claude/settings.json`; mutations stay confirmation-gated.

Workflow:
1. Identify which issue to implement. If `$ARGUMENTS` contains a GitHub issue URL, use it; otherwise ask.
2. Fetch the issue from GitHub and read the spec (Problem, Solution, Files to Modify, Verification).
3. Update the project item's Status field to the **Status when starting work** value from `.claude/gh-workflow.md`.
4. Implement the solution following the spec.
5. Write tests for new features or bug fixes.
6. Run tests to verify.
7. Commit with the issue title as a prefix: `<Issue title>: <short description>`.
8. Create a pull request first (before bumping Status), so a failed `gh pr create` doesn't strand the issue in "In Review" with no PR:
   - Find the base branch by running:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     BASE=main; [ -f $INFO ] && . $INFO
     ```
   - Run: `gh pr create --base $BASE --head $(git rev-parse --abbrev-ref HEAD) --fill`
     This opens an editor so the user can review and submit the PR.
9. Update the project item's Status field to the **Status when in review** value from `.claude/gh-workflow.md` (typically `In Review`). If the project has no In Review state, leave it as the **Status when starting work** value — do NOT set Done yet.
10. Hand off to PM via radio — this is the canonical handoff, not a message to the user:
    ```bash
    radio send --to pm --intent review-requested --pr <N> --body "PR up: <url>"
    ```
    Read `radio send`'s stdout. `delivered`/`queued` mean the ping reached PM (or will on its next Stop) — idle as planned. But if it prints `radio: WARNING — no session for pm`, **the PM isn't running**: do NOT idle silently. Tell the user the PM is absent (so they can start it or check the role name via `ls ~/.task-force/radio/sessions/`).
11. Idle — do NOT run `task-done` yet. Wait for one of:
    - **`changes-requested`** from PM: read the PR comments (`gh pr view <N> --comments`), push more commits, then `radio send --to pm --intent re-review-requested --pr <N>` and idle again.
    - **`approved-and-merged`** from PM (or the user explicitly says "cleanup"): update Status to the **Status when done** value from `.claude/gh-workflow.md`, then run `task-done --remove-worktree` to clean up the worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
